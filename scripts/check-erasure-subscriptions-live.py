#!/usr/bin/env python3
"""Every erasure subscription reaches a route that exists (micro-org#474).

WHAT WENT WRONG
===============

`erasure/register.psv` said `http://worlds:4000/v1/events`. Every word of that
resolved. `worlds` is an ExternalName Service — a DNS CNAME onto `agora`, kept
so that in-estate callers did not have to change on cutover day — so the relay
connected, sent the event, and got a well-formed HTTP response.

**410 Gone.** The merged process gives every mounted module its own suffixed
path and answers the bare `/v1/events` with a deliberate tombstone, so worlds'
half of every erasure went to a route that exists only to say "not here". The
subscription was configured, the delivery succeeded, and nothing was erased.

Two more of the same shape were found in the same query: `agora` and `analytics`
had NO subscription row at all, and `devplatform` and `policy` were subscribed
through their alias names rather than the absorber's — which works today and
stops working, silently, the day somebody tidies a CNAME away.

WHY THIS CANNOT BE A REPOSITORY CHECK
=====================================

`check-erasure-register.py` already reads the register and the services'
migrations, and it passed throughout: the row was present, the service was
registered, the columns were declared. What it cannot know is whether the URL in
that row is answered by a route or by a tombstone, because that is a property of
the RUNNING process and of a DNS alias, neither of which is in a checkout.

WHAT IT DOES
============

Reads `identity.event_subscriptions` for `identity.user.deleted`, POSTs an empty
body to each URL from inside the cluster, and judges by status:

  * 400 / 401 / 403  — the route EXISTS and refused the unsigned body. Correct.
  * 404 / 405 / 410  — there is no handler there. REFUSED.
  * 2xx              — a route that accepts an unsigned, empty erasure envelope
                       is a worse finding than a missing one. REFUSED.

An unsigned empty body is deliberately the probe: it can never erase anything,
and every one of these handlers verifies the MAC over the raw bytes before it
parses. Nothing here is a write.

It also compares the live URL set against the register, in both directions, so a
row that was never seeded and a row that was seeded and then superseded are both
visible rather than only the first.

USAGE
=====

    ./scripts/check-erasure-subscriptions-live.py [--namespace cloudsforge-estate]

Needs `kubectl` against the estate's cluster. Live check — belongs in
`k8s-estate-verify.sh`, not in CI.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOPIC = "identity.user.deleted"

# A route that exists and refuses an unsigned body. Every one of these is a PASS:
# the handler was reached and did the right thing with a body it must not act on.
EXISTS = {"400", "401", "403", "422"}
# A route that is not there. `410` is the merged process's own tombstone for a
# path a module used to serve, which is the exact failure this check was written
# for — it is the most convincing possible "resolves and does nothing".
ABSENT = {"404", "405", "410"}


def fail(message):
    print(f"check-erasure-subscriptions-live: {message}", file=sys.stderr)
    sys.exit(1)


def kubectl(*args, check=True, want_stderr=False):
    """`want_stderr` because wget writes `--server-response` to STDERR and exits non-zero on a 4xx.

    Reading only stdout made every probe look like "no response" — a check that is red about
    everything says nothing, which is the failure mode this file exists to catch in someone else.
    """
    proc = subprocess.run(["kubectl", *args], capture_output=True, text=True, timeout=120)
    if check and proc.returncode != 0:
        fail(f"`kubectl {' '.join(args[:4])} …` failed:\n       {proc.stderr.strip()}")
    return proc.stdout + proc.stderr if want_stderr else proc.stdout


def register_urls():
    path = ROOT / "erasure" / "register.psv"
    urls = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split("|")
        if len(fields) >= 3 and fields[2].strip():
            urls.add(fields[2].strip())
    if not urls:
        fail(f"{path} names no subscriber URLs, so this check would pass over nothing.")
    return urls


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--namespace", default="cloudsforge-estate")
    ap.add_argument(
        "--prober",
        default="deploy/prometheus",
        help="a workload with wget, used to reach the URLs from INSIDE the cluster",
    )
    ap.add_argument("--prober-namespace", default="cf-telemetry")
    args = ap.parse_args()

    postgres = None
    for name in kubectl("-n", args.namespace, "get", "pod", "-o", "name").split():
        if "postgres" in name:
            postgres = name.split("/", 1)[1]
            break
    if not postgres:
        fail(f"no postgres pod in {args.namespace}, so the subscription table cannot be read.")

    rows = kubectl(
        "-n", args.namespace, "exec", postgres, "-c", "postgres", "--",
        "psql", "-U", "postgres", "-d", "identity", "-tAc",
        f"select url from event_subscriptions where topic = $${TOPIC}$$ order by 1",
    )
    live = {line.strip() for line in rows.splitlines() if line.strip()}
    if not live:
        fail(
            f"`{TOPIC}` has NO subscribers at all.\n"
            "       That is not a configuration difference, it is every service in the estate\n"
            "       keeping a person's rows after they ask to be forgotten."
        )

    declared = register_urls()
    missing = sorted(declared - live)
    extra = sorted(live - declared)

    def qualified(url):
        """A bare `http://agora:4000/…` means "inside the estate's namespace".

        The relay runs in `--namespace` and resolves a bare service name there. The prober runs in
        the telemetry namespace and does not, so the bare form would report every subscriber as
        unreachable — a check that is red about everything says nothing. Qualifying it with
        `.<namespace>.svc.cluster.local` is the same address the relay's own resolver produces, and
        it is written out rather than assumed so that a URL naming a DIFFERENT namespace is left
        exactly as it is.
        """
        return re.sub(
            r"^(https?://)([a-z0-9-]+)(:\d+)",
            lambda m: f"{m.group(1)}{m.group(2)}.{args.namespace}.svc.cluster.local{m.group(3)}",
            url,
        )

    unreachable = []
    reachable = []
    for url in sorted(live):
        # An empty, unsigned body. It cannot erase anything: every handler verifies the MAC over
        # the raw bytes before it parses. The STATUS is the whole measurement.
        out = kubectl(
            "-n", args.prober_namespace, "exec", args.prober, "--",
            "wget", "-qO-", "--server-response", "--post-data={}",
            "--header=content-type: application/json", qualified(url),
            check=False,
            want_stderr=True,
        )
        match = re.search(r"HTTP/\S+\s+(\d{3})", out)
        status = match.group(1) if match else None
        if status in EXISTS:
            reachable.append((url, status))
        else:
            unreachable.append((url, status or "no response"))

    problems = []
    if unreachable:
        problems.append(
            "erasure subscription(s) whose URL is not answered by a handler:\n       "
            + "\n       ".join(f"{status:>12}  {url}" for url, status in unreachable)
            + "\n\n       410 is the merged process's tombstone for a path a module used to serve,\n"
            "       and it is the worst of these: the name resolves through the absorbed\n"
            "       service's CNAME, the delivery succeeds, and nothing is erased. Name the\n"
            "       ABSORBER and its mounted path — `http://agora:4000/v1/events/<module>`."
        )
    if missing:
        problems.append(
            "in erasure/register.psv and NOT subscribed:\n       "
            + "\n       ".join(missing)
            + "\n\n       `estate-bootstrap.sh` seeds a row per register line; these were never\n"
            "       seeded, or were seeded and then superseded by an edit to the register."
        )
    if extra:
        problems.append(
            "subscribed and NOT in erasure/register.psv:\n       "
            + "\n       ".join(extra)
            + "\n\n       Usually an alias left over from before a merge. It works until the\n"
            "       ExternalName is tidied away, and then it fails silently."
        )

    if problems:
        fail("\n\n       ".join(problems))

    print(
        f"check-erasure-subscriptions-live: ok — {len(reachable)} subscriber(s) to {TOPIC}, "
        "every one answered by a live handler, and the set matches erasure/register.psv."
    )


if __name__ == "__main__":
    main()
