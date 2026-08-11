#!/usr/bin/env python3
"""Every `job=` in an alert rule names a job Prometheus actually scrapes.

THE DEFECT
----------
`NotifyReservedDomainGuardLost` shipped on 2026-08-11 with this expression:

    notify_reserved_domain_guard == 0
    or (up{job="notify"} == 1 unless notify_reserved_domain_guard)

There is no job called `notify`. Every application service in this estate is
scraped by ONE file_sd job — `cf-services` — whose relabel rules turn
`__meta_cf_service` into a `service` label. The real target is

    up{job="cf-services", service="notify", instance="notify:4000"}

so `up{job="notify"}` selects nothing, ever. Measured on mainnet the same day:
NO SERIES, while notify was up and serving.

WHY THAT MATTERED MORE THAN A TYPO USUALLY DOES
-----------------------------------------------
The dead selector was the half of the alert written for the case the ticket was
about — a deployed build so old it exports no reserved-domain metric at all.
`== 0` matches nothing when there is no series, so absence had to be caught by
the `unless` half, and the `unless` half was itself absent. The alert covering
"the guard is missing" could not fire when the guard was missing. micro-org#390
is a ticket about an alert that could not fire; its fix contained another one.

WHY THE UNIT TESTS DID NOT CATCH IT
-----------------------------------
They asserted the rule against `input_series` that INVENTED the label set:

    - series: 'up{instance="notify:4090",job="notify",service="notify",...}'

promtool answers what the rules do to the series you hand it. Hand it a series
carrying a label no scrape config produces and it will confirm, correctly and
uselessly, that the rule works on a world that does not exist. A fixture is the
one place in this repository where a label set is whatever the author expected
rather than whatever the estate emits — so it is the one place where drift is
invisible by construction, and it is scanned here for exactly that reason.

WHAT THIS CHECKS
----------------
Every `job=`/`job!=`/`job=~`/`job!~` matcher, and every `job:` label line, in
`prometheus/rules/*.yaml` resolves against the `job_name`s declared in
`prometheus/prometheus.yml`. Exact matchers must name a job; regex matchers must
match at least one.

WHAT IT DOES NOT CHECK, AND WHY
-------------------------------
`service=` and `instance=`. Those labels come from
`prometheus/targets/services.yaml`, which is GENERATED per release by
`scripts/render-prometheus-targets.py` and gitignored — there is nothing in a
checkout to compare against, so a check here would either read a file that is
absent in CI or invent an answer. That gap is real: a rule saying
`service="notifiy"` would pass this. It is named here rather than left for
somebody to assume was covered.

USAGE
-----
    python3 scripts/check-alert-job-labels.py

Exit 0 when every job matcher resolves; exit 1 naming the file, the line and the
jobs that do exist.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CONFIG = REPO / "prometheus" / "prometheus.yml"
RULES_DIR = REPO / "prometheus" / "rules"

JOB_NAME = re.compile(r"^\s*-\s*job_name:\s*['\"]?([A-Za-z0-9_.:-]+)['\"]?\s*$")
# `job` in a PromQL matcher or in a fixture's series label set.
MATCHER = re.compile(r"\bjob\s*(=~|!~|!=|=)\s*\"([^\"]*)\"")
# `job: cf-services` — an exp_labels block or a static_configs label map.
LABEL_LINE = re.compile(r"^\s*job:\s*['\"]?([A-Za-z0-9_.:|-]+)['\"]?\s*$")
COMMENT = re.compile(r"^\s*#")


def jobs_declared():
    if not CONFIG.exists():
        return None
    return {m.group(1) for m in (JOB_NAME.match(l) for l in CONFIG.read_text().splitlines()) if m}


def check_file(path, jobs):
    """Return [(lineno, matcher-text, value)] for every job reference that resolves to nothing."""
    bad = []
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        # Prose is not a selector. Every comment in these files starts its own
        # line, and several of them quote the broken matcher deliberately, to
        # record what went wrong — scanning them would make the explanation of
        # the defect fail the check written for the defect.
        if COMMENT.match(line):
            continue
        for op, value in MATCHER.findall(line):
            if op in ("=~", "!~"):
                try:
                    rx = re.compile(r"\A(?:%s)\Z" % value)
                except re.error as exc:
                    bad.append((lineno, f'job{op}"{value}"', f"is not a valid regex: {exc}"))
                    continue
                if not any(rx.match(j) for j in jobs):
                    bad.append((lineno, f'job{op}"{value}"', "matches none of the declared jobs"))
            elif value not in jobs:
                bad.append((lineno, f'job{op}"{value}"', "is not a declared job"))
        m = LABEL_LINE.match(line)
        if m and m.group(1) not in jobs:
            bad.append((lineno, f"job: {m.group(1)}", "is not a declared job"))
    return bad


def main():
    jobs = jobs_declared()
    if not jobs:
        print(f"check-alert-job-labels: no job_name found in {CONFIG.relative_to(REPO)}.")
        print("  Either the scrape config moved or its format changed. Silence here is not a pass:")
        print("  with an empty job set this check would either flag everything or, read the other")
        print("  way, measure nothing.")
        return 1

    files = sorted(RULES_DIR.glob("*.yaml"))
    if not files:
        print(f"check-alert-job-labels: no rule files under {RULES_DIR.relative_to(REPO)}.")
        return 1

    findings = [(p, bad) for p in files for bad in [check_file(p, jobs)] if bad]
    if findings:
        print("check-alert-job-labels: FAIL\n")
        for path, bad in findings:
            for lineno, text, why in bad:
                print(f"  {path.relative_to(REPO)}:{lineno}: `{text}` {why}.")
        print(f"\n  Jobs Prometheus actually scrapes: {', '.join(sorted(jobs))}")
        print()
        print("  Application services are NOT their own job. They are scraped by `cf-services`,")
        print("  which relabels `__meta_cf_service` into a `service` label, so a single service is")
        print('  selected as `up{job="cf-services", service="notify"}`.')
        print()
        print("  A matcher that resolves to nothing does not error and does not warn. It makes the")
        print("  expression it appears in evaluate to the empty vector, which for an alert is")
        print("  indistinguishable from healthy — and in a fixture it silently manufactures the")
        print("  series it names, so the unit test passes on a world the estate does not have.")
        return 1

    scanned = ", ".join(p.name for p in files)
    print(f"check-alert-job-labels: ok — every job matcher in {scanned} resolves")
    print(f"  against the {len(jobs)} job(s) declared in prometheus.yml.")
    print("  NOT covered: `service=` and `instance=`. Those come from")
    print("  prometheus/targets/services.yaml, which is generated per release and gitignored,")
    print("  so there is nothing in a checkout to check them against.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
