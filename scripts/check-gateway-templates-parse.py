#!/usr/bin/env python3
"""The gateway files are Go templates that are also YAML, and only one of them has comments.

THE OUTAGE THIS EXISTS TO PREVENT, WHICH HAPPENED
--------------------------------------------------
On 2026-08-19 the whole of `cloudsforge.online` answered 404 for about six
minutes — not the moved surfaces, not one router, nothing. Traefik's log:

    ERR Error while building configuration (for the first time)
    error="unable to load content configuration from subdirectory …:
           policy.yml: template: :226: unexpected \\"#\\" in operand"
    providerName=file

The cause was three lines of PROSE:

    # All of that is still true and it is now covered by `https://{{ env
    # "CF_SITE_HOST" }}`, the FIRST entry in this list.

`policy.yml`'s own header states the rule that broke:

    For the same reason NOTHING in this file may write a template action inside
    a comment: the renderer does not know what a comment is, and an unclosed one
    takes …

The file provider renders the Go template BEFORE anything parses YAML. To the
renderer there is no such thing as a comment — it sees `{{ env`, then a newline,
then `#`, and `#` is not a legal thing to find inside an action. One malformed
action anywhere in the file means Traefik builds NO configuration from that
provider at all. Not a bad route: no routes.

WHY EVERY EXISTING CHECK MISSED IT
-----------------------------------
`surface-routes.py`, `check-base-paths-agree.py`,
`check-router-prefix-ordering.py`, `check-api-remount.py` and
`check-k8s-gateway-matches-compose.py` all read these files as TEXT and all of
them skip comments — correctly, for what they each ask. None of them renders.
The rule was written down, in the file it governs, and nothing enforced it.

It also survived a long time: the comment was written during wave 1 and lived
through the whole of wave 1 and wave 2, because the gateway configmap is applied
by `k8s-gateway.sh` and nothing had re-applied it. **The blast radius of a
gateway template error is decoupled in time from the commit that introduces it**,
which is the strongest argument for checking it at commit time.

WHAT THIS CHECKS
----------------
Two properties, and neither needs a Go runtime:

  1. NO TEMPLATE ACTION INSIDE A COMMENT. The file's own rule, stated as code.
     This is the one that took the estate down, and it is the one a reviewer is
     least likely to see — the line reads as documentation.

  2. EVERY LINE'S ACTIONS ARE BALANCED. `{{` and `}}` counts agree per line, so
     an action cannot span a newline. Traefik's own templates never need one,
     and an action that spans a line is how a `#` gets inside it.

Deliberately not a full Go template parse: that would need Go, and these two
properties cover the failure that has actually occurred. A real render happens at
apply time in `k8s-gateway.sh`, which is the right place for it and the wrong
place to find out.

Exit 0 when every gateway file's template can be read. Exit 1 otherwise.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DYNAMIC = ROOT / "gateway" / "dynamic"

COMMENT_RE = re.compile(r"^\s*#")

fails = []


def main():
    if not DYNAMIC.is_dir():
        print(f"FAIL: {DYNAMIC} does not exist.")
        return 1

    files = sorted(DYNAMIC.glob("*.yml"))
    if not files:
        print(f"FAIL: no *.yml under {DYNAMIC} — this check would pass by finding nothing, "
              f"which is the failure mode it is most important not to have.")
        return 1

    for f in files:
        for lineno, line in enumerate(f.read_text().splitlines(), 1):
            if COMMENT_RE.match(line) and "{{" in line:
                fails.append(
                    f"{f.name}:{lineno} writes a template action inside a COMMENT. The file "
                    f"provider renders the template before anything parses YAML, so there is no "
                    f"such thing as a comment to it. If the action is malformed — or merely "
                    f"spans a line, which is how a `#` gets inside one — Traefik builds NO "
                    f"configuration from this provider and the whole estate serves 404.\n"
                    f"        {line.strip()[:100]}\n"
                    f"        Write the variable NAME instead: `the CF_SITE_HOST entry`."
                )
            opens, closes = line.count("{{"), line.count("}}")
            if opens != closes:
                fails.append(
                    f"{f.name}:{lineno} has {opens} `{{{{` and {closes} `}}}}`, so a template "
                    f"action spans a newline. Traefik needs none that do, and one that does is "
                    f"how the 2026-08-19 outage happened — the continuation line began with `#`.\n"
                    f"        {line.strip()[:100]}"
                )

    for x in fails:
        print(f"FAIL {x}")
    if fails:
        print(f"\n{len(fails)} gateway template problem(s). Traefik would build no configuration.")
        return 1
    print(f"ok — {len(files)} gateway file(s), every template action balanced and outside a comment.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
