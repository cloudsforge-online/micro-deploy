#!/usr/bin/env python3
"""Generate the CloudsForge Grafana dashboards.

Why generated rather than hand-written JSON:

  1. Grafana cannot be told about a custom palette. There is no theme file, no
     plugin-free registration point — a colour is either one of Grafana's own
     names or a hex literal written into every panel. Writing 40 panels of hex
     literals by hand guarantees drift, and the palette in
     assets/chart-palette.md is validated, not decorative: ember↔gold at ΔE 2.8
     under deuteranopia is the difference between two series and one.

  2. The palette carries RULES as well as values — assigned in order, never
     cycled; status colours never a series colour; quantiles are ordinal so
     they take the sequential ramp rather than three categorical hues. A rule
     applied by a function is applied everywhere. A rule in a document is
     applied where somebody remembered.

  3. "No dual-axis panels" is checkable here. `timeseries()` takes one unit,
     and there is deliberately no way to give it a second — two measures of
     different scale become two panels sharing a time range, which is the
     estate's hashrate/difficulty rule generalised.

    python3 grafana/build-dashboards.py

Writes grafana/dashboards/*.json. Both this file and its output are committed:
the output is what Grafana provisions, and this is what makes the output
reviewable as a set of decisions rather than as 4,000 lines of JSON.
"""

import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
PALETTE = json.loads((HERE / "theme" / "palette.json").read_text())

CAT = list(PALETTE["categorical"].values())        # eight slots, in order
SEQ = PALETTE["sequential_ember"]
DIV = PALETTE["diverging"]
STATUS = PALETTE["status"]

PROM = {"type": "prometheus", "uid": "cf-prometheus"}
LOKI = {"type": "loki", "uid": "cf-loki"}
ALERTMGR = {"type": "alertmanager", "uid": "cf-alertmanager"}

# Runbook base, so a panel description can link to the same document the alert
# that fires on it links to. An operator reading a red panel and an operator
# reading a page should arrive at the same page.
RUNBOOK = "https://github.com/cloudsforge-online/stack/blob/main/micro/deploy/runbooks"


def _panel_id(state={"n": 0}):
    state["n"] += 1
    return state["n"]


def _series_overrides(names):
    """Fixed colour per named series, assigned in slot order and never cycled.

    Keyed by NAME, not by position in the result, which is the palette's
    'colour follows the entity, not its rank' rule: filtering a chart down to
    three chains must not recolour the survivors.
    """
    if len(names) > len(CAT):
        raise ValueError(
            f"{len(names)} series but only {len(CAT)} slots. A ninth series is "
            "never a generated hue — fold to 'Other', use small multiples, or "
            "the form is wrong (chart-palette.md §2)."
        )
    return [
        {
            "matcher": {"id": "byName", "options": name},
            "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": CAT[i]}}],
        }
        for i, name in enumerate(names)
    ]


def _quantile_overrides():
    """p50/p95/p99 are an ORDINAL scale, so they take the ember ramp.

    Three categorical hues would say the quantiles are three unrelated things.
    Lightness says they are the same measurement at increasing severity, which
    is what they are — the same reasoning that keeps Lantern's five-level
    severity ramp single-hue.
    """
    return [
        {
            "matcher": {"id": "byName", "options": label},
            "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": colour}}],
        }
        for label, colour in (("p50", SEQ["300"]), ("p95", SEQ["500"]), ("p99", SEQ["700"]))
    ]


def target(expr, legend, ref="A", instant=False, fmt="time_series"):
    return {
        "datasource": PROM,
        "editorMode": "code",
        "expr": expr,
        "legendFormat": legend,
        "range": not instant,
        "instant": instant,
        "format": fmt,
        "refId": ref,
    }


def timeseries(title, targets, unit, gridPos, description="",
               overrides=None, fixed=None, fill=0, stack=False,
               thresholds=None, exemplars=False, decimals=None, legend=True):
    """One panel, ONE unit. There is no second-axis argument, on purpose.

    Two measures of different scale become two panels sharing a time range
    (chart-palette.md §10). Hashrate and difficulty are the estate's named
    example; the rule is general.
    """
    colour = {"mode": "fixed", "fixedColor": fixed} if fixed else {"mode": "palette-classic"}
    steps = thresholds or [{"color": STATUS["good"], "value": None}]
    return {
        "id": _panel_id(),
        "type": "timeseries",
        "title": title,
        "description": description,
        "datasource": PROM,
        "gridPos": gridPos,
        "targets": [dict(t, **{"exemplar": exemplars}) for t in targets],
        "options": {
            # Legend present for >=2 series, absent for one — the title names it
            # (chart-palette.md §7). Passing legend=False is how a one-series
            # panel says so.
            "legend": {
                "displayMode": "list" if legend else "hidden",
                "placement": "bottom",
                "showLegend": legend,
                "calcs": [],
            },
            # Crosshair + shared tooltip on line/area, per the mark spec.
            "tooltip": {"mode": "multi" if legend else "single", "sort": "desc"},
        },
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "decimals": decimals,
                "color": colour,
                "custom": {
                    "drawStyle": "line",
                    # 2px, no shadow, no gradient stroke.
                    "lineWidth": 2,
                    "fillOpacity": fill,
                    "gradientMode": "none",
                    "showPoints": "never",
                    "stacking": {"mode": "normal" if stack else "none", "group": "A"},
                    # Horizontal grid only, behind the marks.
                    "axisGridShow": True,
                    "axisBorderShow": False,
                    "spanNulls": False,
                    # An empty chart and a failed chart must not look the same.
                    # `insertNulls` leaves a gap rather than joining across a
                    # scrape that never answered.
                    "insertNulls": 300000,
                },
                "thresholds": {"mode": "absolute", "steps": steps},
            },
            "overrides": overrides or [],
        },
    }


def stat(title, targets, unit, gridPos, description="", steps=None,
         decimals=None, mappings=None, graph=True, text_size=None):
    return {
        "id": _panel_id(),
        "type": "stat",
        "title": title,
        "description": description,
        "datasource": PROM,
        "gridPos": gridPos,
        "targets": targets,
        "options": {
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "orientation": "auto",
            "textMode": "auto",
            # Colour the VALUE, not the whole tile: a wall of coloured
            # rectangles reads as decoration and stops being a signal.
            "colorMode": "value",
            "graphMode": "area" if graph else "none",
            "justifyMode": "auto",
            "text": text_size or {},
        },
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "decimals": decimals,
                "mappings": mappings or [],
                "color": {"mode": "thresholds"},
                "thresholds": {
                    "mode": "absolute",
                    "steps": steps or [{"color": STATUS["good"], "value": None}],
                },
                # Mono numerals, tabular — the palette's numeral rule.
                "custom": {},
            },
            "overrides": [],
        },
    }


def bargauge(title, targets, unit, gridPos, description="", steps=None, maxv=None):
    """Sorted horizontal bars. Never a pie, and never a gauge dial for a
    magnitude — bar length already encodes it."""
    return {
        "id": _panel_id(),
        "type": "bargauge",
        "title": title,
        "description": description,
        "datasource": PROM,
        "gridPos": gridPos,
        "targets": targets,
        "options": {
            "displayMode": "gradient",
            "orientation": "horizontal",
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "showUnfilled": True,
            "valueMode": "text",
            "sizing": "auto",
            "minVizWidth": 8,
            "minVizHeight": 16,
        },
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "max": maxv,
                "color": {"mode": "thresholds"},
                "thresholds": {
                    "mode": "absolute",
                    "steps": steps or [{"color": STATUS["good"], "value": None}],
                },
            },
            "overrides": [],
        },
    }


def table(title, targets, gridPos, description="", transformations=None, overrides=None):
    return {
        "id": _panel_id(),
        "type": "table",
        "title": title,
        "description": description,
        "datasource": PROM,
        "gridPos": gridPos,
        "targets": targets,
        "transformations": transformations or [],
        "options": {"showHeader": True, "cellHeight": "sm", "footer": {"show": False}},
        "fieldConfig": {
            "defaults": {"custom": {"align": "auto", "filterable": True}},
            "overrides": overrides or [],
        },
    }


# Status marks ship icon + label + colour, because colour never carries meaning
# alone. Beacon's three-state model is correct and is kept: a fourth "serious"
# step cannot clear the normal-vision floor against warning on this surface.
JOURNEY_MAPPINGS = [
    {"type": "value", "options": {
        "1":   {"text": "● pass", "color": STATUS["good"], "index": 0},
        "0.5": {"text": "▲ skip", "color": STATUS["warn"], "index": 1},
        "0":   {"text": "■ fail", "color": STATUS["crit"], "index": 2},
    }},
    # A journey with no reading at all is not a pass. It is the scheduler
    # having stopped, and it must not render as an empty cell that reads green.
    {"type": "special", "options": {"match": "null", "result": {
        "text": "▲ no data answered", "color": STATUS["warn"], "index": 3}}},
]

TARGET_MAPPINGS = [
    {"type": "value", "options": {
        "1":   {"text": "● up", "color": STATUS["good"], "index": 0},
        "0.5": {"text": "▲ degraded", "color": STATUS["warn"], "index": 1},
        "0":   {"text": "■ down", "color": STATUS["crit"], "index": 2},
    }},
    {"type": "special", "options": {"match": "null", "result": {
        "text": "▲ no data answered", "color": STATUS["warn"], "index": 3}}},
]


def row(title, y):
    return {"id": _panel_id(), "type": "row", "title": title, "collapsed": False,
            "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []}


NETWORK_VAR = {
    # ── ONE ESTATE AT A TIME, DEFAULTING TO THE ONE THAT MATTERS ──────────────────────────────────
    #
    # The SLO recording rules group by `network` as of 2026-08-25, so every series below exists twice
    # for a service that serves both estates. Without a selector the panels SUM them: the headline
    # error ratio blends a testnet spike into mainnet's number, the p95 moves for a testnet
    # regression, and the burn-rate bars show two identical service names.
    #
    # A dropdown rather than a second dashboard, and rather than a `network` legend on every panel:
    # during an incident the question is "is mainnet healthy", and the answer should not require
    # reading which half of a stacked bar belongs to which estate. `mainnet` is the default because
    # that is the estate with users on it.
    "name": "network",
    "label": "Network",
    "type": "query",
    "datasource": PROM,
    "query": {"query": "label_values(http_requests_total, network)", "refId": "cf-network"},
    "refresh": 2,
    "includeAll": False,
    "multi": False,
    "sort": 1,
    "current": {"text": "mainnet", "value": "mainnet", "selected": True},
}

def dashboard(uid, title, description, panels, templating=None, refresh="30s"):
    return {
        "uid": uid,
        "title": title,
        "description": description,
        "tags": ["cloudsforge"],
        "timezone": "utc",
        "editable": False,
        "schemaVersion": 39,
        "version": 1,
        "refresh": refresh,
        "time": {"from": "now-6h", "to": "now"},
        "timepicker": {},
        "templating": {"list": templating or []},
        "annotations": {"list": [{
            "builtIn": 1,
            "datasource": {"type": "grafana", "uid": "-- Grafana --"},
            "enable": True,
            "hide": True,
            "iconColor": CAT[0],
            "name": "Annotations & Alerts",
            "type": "dashboard",
        }, {
            # Deploy markers. "Did this start at 14:02?" in one glance is the
            # single most valuable annotation on any of these dashboards, and it
            # is what makes 'roll back before diagnosing' a decision rather than
            # a guess. Posted by `cfctl release` (AD-03) against the Grafana
            # annotations API with tag `deploy`.
            "datasource": {"type": "grafana", "uid": "-- Grafana --"},
            "enable": True,
            "hide": False,
            "iconColor": CAT[4],
            "name": "Deploys",
            "target": {"limit": 100, "matchAny": False, "tags": ["deploy"], "type": "tags"},
        }]},
        "panels": panels,
    }


# The seven product groups of §6.1 plus the platform itself: eight, which is
# exactly the number of categorical slots. That is not a coincidence — the
# overview aggregates by product group rather than by container name for the
# same reason the public status page does, and it is what keeps this panel
# inside the palette instead of cycling hues at service twenty-six.
PRODUCT_GROUPS = [
    ("Account", 'service=~"identity|hub-api|policy"'),
    ("Wallet", 'service=~"wallet|ledger|settlement|pricing|custody|indexer"'),
    ("Trading", 'service=~"trade"'),
    ("Worlds", 'service=~"worlds|nda"'),
    ("Network", 'service=~"indexer|hearth"'),
    ("Create", 'service=~"mint|studio"'),
    ("Market", 'service=~"market|billing|community"'),
    ("Platform", 'service=~"gateway|notify|activity|admin-api|devplatform|analytics"'),
]


# ===========================================================================
# 1 — Platform overview.  Owner: on-call.  Question: is anything wrong now?
# ===========================================================================
def platform_overview():
    p, y = [], 0
    p.append(row("Global RED", y)); y += 1

    p.append(stat(
        "Requests/sec", [target('sum(rate(http_requests_total{network="$network"}[5m]))', "req/s")],
        "reqps", {"h": 4, "w": 4, "x": 0, "y": y}, decimals=1,
        description="Rate. Zero here with services up means nothing is reaching them — "
                    "check the gateway before the services."))
    p.append(stat(
        "Error ratio (5xx)",
        [target('sum(rate(http_requests_total{network="$network",status=~"5.."}[5m])) / '
                "clamp_min(sum(rate(http_requests_total[5m])), 1e-9)", "error ratio")],
        "percentunit", {"h": 4, "w": 4, "x": 4, "y": y}, decimals=2,
        # Three states, not four. 1% is a ticket, 5% is the gateway page.
        steps=[{"color": STATUS["good"], "value": None},
               {"color": STATUS["warn"], "value": 0.01},
               {"color": STATUS["crit"], "value": 0.05}],
        description="5xx only. A 4xx is a client being wrong; counting it here means a "
                    "scanner probing /wp-admin burns the availability budget."))
    for i, (q, x) in enumerate((("p50", 8), ("p95", 12), ("p99", 16))):
        p.append(stat(
            f"Latency {q}", [target(f'cf:http_latency_ms:{q}{{network="$network"}}', q)],
            "ms", {"h": 4, "w": 4, "x": x, "y": y}, decimals=0,
            steps=[{"color": STATUS["good"], "value": None},
                   {"color": STATUS["warn"], "value": 250},
                   {"color": STATUS["crit"], "value": 1000}],
            description="From the recording rule, not computed on read: a dashboard that "
                        "puts Prometheus under load during an incident is a dashboard "
                        "nobody can open during an incident."))
    p.append(stat(
        "Telemetry plane", [target("sum(up{job=~\"otel-collector|tempo|loki|prometheus|alertmanager|grafana|beacon\"})", "up")],
        "none", {"h": 4, "w": 4, "x": 20, "y": y}, decimals=0, graph=False,
        steps=[{"color": STATUS["crit"], "value": None},
               {"color": STATUS["warn"], "value": 6},
               {"color": STATUS["good"], "value": 7}],
        description="Seven components. Fewer means part of this dashboard is reporting "
                    "silence, which is not the same as health."))
    y += 4

    p.append(timeseries(
        "Request rate by product group",
        [target(f"sum(rate(http_requests_total{{{sel}}}[5m]))", name, ref=chr(65 + i))
         for i, (name, sel) in enumerate(PRODUCT_GROUPS)],
        "reqps", {"h": 8, "w": 12, "x": 0, "y": y},
        overrides=_series_overrides([n for n, _ in PRODUCT_GROUPS]), decimals=1,
        description="By product group, not by container name — the same projection the "
                    "public status page uses, and the reason this panel fits inside the "
                    "eight validated slots instead of cycling hues at service twenty-six."))

    # Error ratio is a SEPARATE panel sharing the time range, not a second axis
    # on the panel above. Two measures of different scale, two panels.
    p.append(timeseries(
        "Error ratio by product group",
        [target(f"sum(rate(http_requests_total{{{sel},status=~\"5..\"}}[5m])) / "
                f"clamp_min(sum(rate(http_requests_total{{{sel}}}[5m])), 1e-9)",
                name, ref=chr(65 + i))
         for i, (name, sel) in enumerate(PRODUCT_GROUPS)],
        "percentunit", {"h": 8, "w": 12, "x": 12, "y": y},
        overrides=_series_overrides([n for n, _ in PRODUCT_GROUPS]), decimals=3,
        description="A separate panel sharing this dashboard's time range, NOT a second "
                    "y-axis on the rate panel. Rate and ratio are different scales."))
    y += 8

    p.append(row("User-visible failure", y)); y += 1

    p.append(stat(
        "Journey status",
        [target("beacon_journey_status", "{{journey}}", instant=True)],
        "none", {"h": 8, "w": 12, "x": 0, "y": y}, mappings=JOURNEY_MAPPINGS, graph=False,
        steps=[{"color": STATUS["crit"], "value": None},
               {"color": STATUS["warn"], "value": 0.5},
               {"color": STATUS["good"], "value": 1}],
        description="Icon + label + colour, never colour alone. 0.5 is a SKIP, and a skip "
                    "is not-run, which is never green — anyone alerting on '== 0' would "
                    "treat a journey whose credentials went missing as passing. "
                    "A journey says a user is blocked; a metric only says a number is ugly. "
                    "Page on this, ticket on the rest."))

    p.append(bargauge(
        "Error-budget burn rate (1h)",
        [target('sort_desc(cf:slo_burn_rate:1h{network="$network"})', "{{service}}", instant=True)],
        "none", {"h": 8, "w": 12, "x": 12, "y": y}, maxv=20,
        steps=[{"color": STATUS["good"], "value": None},
               {"color": STATUS["warn"], "value": 6},
               {"color": STATUS["crit"], "value": 14.4}],
        description="Which SLO to defend this week. 14.4x over an hour is 2% of a 28-day "
                    "budget in an hour and pages; 6x over six hours tickets. Sorted, "
                    "horizontal, direct-labelled — never a pie and never a dial."))
    y += 8

    p.append(table(
        "Top 5 failing routes",
        [target("topk(5, sum by (service, route, status) "
                "(rate(http_requests_total{status=~\"5..\"}[5m])))", "", instant=True, fmt="table")],
        {"h": 8, "w": 12, "x": 0, "y": y},
        transformations=[{"id": "organize", "options": {
            "excludeByName": {"Time": True, "job": True, "instance": True},
            "renameByName": {"Value": "5xx/sec"}}}],
        description="A table, not a chart: five rows read faster than five lines, and "
                    "the answer wanted here is a name, not a trend."))

    p.append({
        "id": _panel_id(),
        "type": "alertlist",
        "title": "Active alerts",
        "description": "Read straight from Alertmanager. Every one of these has already "
                       "opened a Beacon incident — the public page and this timeline "
                       "share one record rather than being two systems to reconcile.",
        "datasource": ALERTMGR,
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": y},
        "options": {
            "alertInstanceLabelFilter": "",
            "datasource": "Alertmanager",
            "viewMode": "list",
            "groupMode": "default",
            "sortOrder": 3,
            "stateFilter": {"firing": True, "pending": True, "noData": False, "normal": False},
        },
    })
    y += 8

    return dashboard(
        "cf-platform-overview", "CloudsForge · Platform overview",
        "Owner: on-call. Question: is anything wrong right now? Every panel below "
        "changes a decision; a panel that cannot is removed at review.",
        p, templating=[NETWORK_VAR], refresh="30s")


# ===========================================================================
# 2 — Service detail, templated by $service.  Owner: the service's team.
# ===========================================================================
def service_detail():
    p, y = [], 0
    tmpl = [{
        "name": "service",
        "label": "Service",
        "type": "query",
        "datasource": PROM,
        "query": {"query": "label_values(http_requests_total, service)", "refId": "cf-service"},
        "refresh": 2,
        "includeAll": False,
        "multi": False,
        "sort": 1,
        "current": {},
    }, NETWORK_VAR]

    p.append(row("RED — $service", y)); y += 1
    p.append(timeseries(
        "Request rate by route",
        [target('sum by (route) (rate(http_requests_total{service="$service",network="$network"}[5m]))', "{{route}}")],
        "reqps", {"h": 7, "w": 8, "x": 0, "y": y}, fixed=CAT[0], decimals=1,
        description="Route cardinality is unbounded, so this is the one place a fixed "
                    "eight-slot assignment cannot apply. One hue, and the route you want "
                    "is found by hovering — not by hunting a colour that means nothing."))
    p.append(timeseries(
        "Errors by status",
        [target('sum by (status) (rate(http_requests_total{service="$service",network="$network",status=~"[45].."}[5m]))',
                "{{status}}")],
        "reqps", {"h": 7, "w": 8, "x": 8, "y": y}, decimals=2,
        overrides=_series_overrides(["500", "502", "503", "504", "400", "401", "403", "404"]),
        description="4xx and 5xx together here, split by code, because the SHAPE of the "
                    "split is the diagnosis: a wall of 401s is an auth change, a wall of "
                    "502s is an upstream."))
    p.append(timeseries(
        "Latency quantiles",
        [target(f'histogram_quantile({q}, sum by (le) '
                f'(rate(http_request_duration_ms_bucket{{service="$service",network="$network"}}[5m])))', label,
                ref=ref)
         for q, label, ref in ((0.50, "p50", "A"), (0.95, "p95", "B"), (0.99, "p99", "C"))],
        "ms", {"h": 7, "w": 8, "x": 16, "y": y}, overrides=_quantile_overrides(),
        exemplars=True, decimals=0,
        description="Exemplars ON: each bucket carries the trace id of a request in it, so "
                    "a p99 spike is one click to the trace that was slow rather than a "
                    "search for one. This is the panel AD-20's exemplar requirement exists "
                    "for. Quantiles take the ordinal ember ramp, not three categorical "
                    "hues — they are one measurement at increasing severity."))
    y += 7

    p.append(row("Saturation", y)); y += 1
    p.append(timeseries(
        "Requests in flight",
        [target('http_requests_in_flight{service="$service"}', "in flight")],
        "none", {"h": 6, "w": 8, "x": 0, "y": y}, fixed=CAT[1], legend=False, decimals=0,
        description="Concurrency, not rate. Climbing while rate is flat means requests are "
                    "not finishing — which shows here before it shows in p99."))
    p.append(timeseries(
        "Process CPU",
        [target('rate(process_cpu_seconds_total{service="$service"}[5m])', "cores")],
        "none", {"h": 6, "w": 8, "x": 8, "y": y}, fixed=CAT[2], legend=False, decimals=2,
        description="A cause, not a symptom. There is deliberately no alert on this: CPU is "
                    "not an alert, latency is."))
    p.append(timeseries(
        "Resident memory",
        [target('process_resident_memory_bytes{service="$service"}', "rss")],
        "bytes", {"h": 6, "w": 8, "x": 16, "y": y}, fixed=CAT[3], legend=False,
        description="Separate panel from CPU. Bytes and cores are different scales, so they "
                    "are never one chart with two axes."))
    y += 6

    p.append(row("Job runner", y)); y += 1
    p.append(timeseries(
        "Job throughput",
        [target('sum by (kind) (rate(jobs_claimed_total{service="$service"}[5m]))', "claimed {{kind}}", ref="A"),
         target('sum by (kind) (rate(jobs_completed_total{service="$service"}[5m]))', "completed {{kind}}", ref="B"),
         target('sum by (kind) (rate(jobs_failed_total{service="$service"}[5m]))', "failed {{kind}}", ref="C")],
        "ops", {"h": 7, "w": 8, "x": 0, "y": y}, decimals=2,
        description="Claimed above completed with the gap not closing is work being started "
                    "and not finished, which is the shape of a worker dying mid-lease — the "
                    "class of bug that produced the estate's double-billing."))
    p.append(timeseries(
        "Queue depth",
        [target('jobs_pending{service="$service"}', "pending", ref="A"),
         target('jobs_overdue{service="$service"}', "overdue", ref="B")],
        "none", {"h": 7, "w": 8, "x": 8, "y": y}, decimals=0,
        overrides=_series_overrides(["pending", "overdue"]),
        description="`jobs_overdue` is work due more than five minutes ago. Non-zero while "
                    "`claimed` is flat means nothing is claiming; non-zero while claimed is "
                    "healthy means a lease is held by something that is gone."))
    p.append(stat(
        "Dead-lettered (1h)",
        [target('sum(increase(jobs_dead_total{service="$service"}[1h]))', "dead")],
        "none", {"h": 7, "w": 8, "x": 16, "y": y}, decimals=0, graph=False,
        steps=[{"color": STATUS["good"], "value": None},
               {"color": STATUS["warn"], "value": 1},
               {"color": STATUS["crit"], "value": 10}],
        description=f"A dead letter is work that will never happen unless somebody makes it "
                    f"happen. Drain deliberately — replaying blindly is how a double "
                    f"withdrawal is created. Runbook: {RUNBOOK}/runbook-dead-letter-drain.md"))
    y += 7

    p.append(row("Logs", y)); y += 1
    p.append({
        "id": _panel_id(),
        "type": "logs",
        "title": "Recent errors — $service",
        "description": "Loki holds the raw stream; Lantern holds the triage view, which "
                       "groups these into issues by fingerprint. 1,240 rows here are four "
                       "distinct problems there. Every line carries trace_id: click it to "
                       "land in Tempo on the trace that produced it.",
        "datasource": LOKI,
        "gridPos": {"h": 10, "w": 24, "x": 0, "y": y},
        "targets": [{
            "datasource": LOKI,
            "refId": "A",
            "expr": '{service_name="$service"} | json | level =~ "error|fatal"',
            "queryType": "range",
        }],
        "options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending",
                    "enableLogDetails": True, "dedupStrategy": "none"},
    })
    y += 10

    return dashboard(
        "cf-service-detail", "CloudsForge · Service detail",
        "Owner: the service's team. Question: why is THIS service unhealthy?",
        p, templating=tmpl, refresh="30s")


# ===========================================================================
# 3 — Money integrity.  Owner: ledger team, read daily by finance.
# ===========================================================================
def money_integrity():
    p, y = [], 0

    # THE FIRST PANEL. Not by layout convention — by operational instruction:
    # "SEV1, minute two: Money integrity dashboard first, always." The number an
    # operator needs before any other is this one.
    p.append(stat(
        "Trial balance — Σ debits − Σ credits",
        [target("ledger_trial_balance_delta", "{{currency}}")],
        "none", {"h": 7, "w": 24, "x": 0, "y": y}, decimals=8, graph=False,
        text_size={"valueSize": 56},
        # Any non-zero is critical. There is no warning band, because there is no
        # amount by which double-entry is allowed to be wrong.
        steps=[{"color": STATUS["crit"], "value": None},
               {"color": STATUS["good"], "value": 0},
               {"color": STATUS["crit"], "value": 0.000000001}],
        mappings=[{"type": "value", "options": {
            "0": {"text": "● 0 — balanced", "color": STATUS["good"], "index": 0}}},
            {"type": "special", "options": {"match": "null", "result": {
                "text": "▲ no data answered", "color": STATUS["warn"], "index": 1}}}],
        description="MUST BE EXACTLY 0, per currency. Double-entry has one invariant and "
                    "this is it; non-zero does not mean a number is off, it means the "
                    "accounting is not accounting and every balance derived from it is "
                    "unproven — including the ones users are looking at right now. "
                    "Non-zero for two consecutive evaluations PAGES immediately, SEV1, and "
                    "there is no error budget: the objective is 100%. Never correct this "
                    "with an UPDATE — an adjustment is a new balanced entry under dual "
                    f"approval. Runbook: {RUNBOOK}/runbook-trial-balance-nonzero.md — and "
                    "note that 'no data answered' is NOT balanced. A metric nobody "
                    "publishes and a ledger that balances look identical here, which is why "
                    "MoneyMetricContractMissing exists as a separate alert."))
    y += 7

    p.append(timeseries(
        "Posting rate by source",
        [target("sum by (source) (rate(ledger_postings_total[5m]))", "{{source}}")],
        "ops", {"h": 7, "w": 12, "x": 0, "y": y}, fixed=CAT[0], decimals=2,
        description="Per-product revenue is derivable from this and was not derivable from "
                    "anything before. Every posting records the calling service, so 'which "
                    "product earned this' stops being a reconstruction."))

    p.append(timeseries(
        "Reconciliation drift per chain",
        [target("ledger_reconciliation_drift_native", "{{chain}}")],
        "none", {"h": 7, "w": 12, "x": 12, "y": y}, decimals=8,
        # Drift has a sign and a polarity: the ledger is over or under what the
        # chain says. That is the diverging pair's job, not a categorical hue's.
        overrides=[{"matcher": {"id": "byValue", "options": {"op": "gte", "reducer": "allValues", "value": 0}},
                    "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": DIV["gain"]}}]}],
        fill=10, thresholds=[{"color": DIV["mid"], "value": None}],
        description="Ledger's custody account against the indexer's observed on-chain "
                    "balance. Ticket at any non-zero, page above the chain's dust "
                    "threshold. Two truths is exactly what one journal exists to prevent, "
                    f"so this is a real finding even when it is small. Runbook: "
                    f"{RUNBOOK}/runbook-reconciliation-drift.md"))
    y += 7

    p.append(bargauge(
        "Unreconciled entries by age",
        [target("ledger_unreconciled_entries", "{{age_bucket}}", instant=True)],
        "none", {"h": 7, "w": 8, "x": 0, "y": y},
        steps=[{"color": STATUS["good"], "value": None},
               {"color": STATUS["warn"], "value": 1},
               {"color": STATUS["crit"], "value": 50}],
        description="Ordinal buckets, so bars rather than hues. Any entry past 24h is a "
                    "ticket."))
    p.append(bargauge(
        "Reservations open, by age",
        [target("ledger_reservations_open", "{{age_bucket}}", instant=True)],
        "none", {"h": 7, "w": 8, "x": 8, "y": y},
        steps=[{"color": STATUS["good"], "value": None},
               {"color": STATUS["warn"], "value": 1},
               {"color": STATUS["crit"], "value": 20}],
        description="A reservation older than 24h is a user's money they cannot see and "
                    "cannot spend. It will not appear in any error rate."))
    p.append(timeseries(
        "Failed postings by reason",
        [target("sum by (reason) (rate(ledger_posting_failures_total[5m]))", "{{reason}}")],
        "ops", {"h": 7, "w": 8, "x": 16, "y": y}, decimals=3,
        overrides=_series_overrides(["unbalanced", "idempotency_conflict", "account_frozen",
                                     "insufficient_funds", "unknown_account"]),
        description="reason=\"unbalanced\" is a code bug and pages. The others are the "
                    "system refusing correctly, which is a different fact."))
    y += 7

    p.append(timeseries(
        "Idempotency replay ratio",
        [target("sum(rate(ledger_idempotency_replay_total[5m])) / "
                "clamp_min(sum(rate(ledger_postings_total[5m])), 1e-9)", "replay ratio")],
        "percentunit", {"h": 6, "w": 24, "x": 0, "y": y}, fixed=CAT[1], legend=False, decimals=3,
        description="A sudden rise means a caller is retrying, which means something "
                    "upstream is timing out. Idempotency working is not the same as "
                    "idempotency being needed — this is the panel that tells them apart."))
    y += 6

    return dashboard(
        "cf-money-integrity", "CloudsForge · Money integrity",
        "Owner: the ledger team; read daily by finance. Question: is the ledger right? "
        "Sourced from metrics the ledger EMITS, never from queries Grafana runs against "
        "it — operational observability is never derived from the financial plane.",
        p, refresh="1m")


# ===========================================================================
# 4 — Deposits & withdrawals.  Owner: the wallet team.
# ===========================================================================
def deposits_withdrawals():
    p, y = [], 0

    p.append(stat(
        "Stuck withdrawals",
        [target("sum(withdrawal_stuck)", "stuck")],
        "none", {"h": 6, "w": 6, "x": 0, "y": y}, decimals=0, graph=False,
        text_size={"valueSize": 48},
        steps=[{"color": STATUS["good"], "value": None}, {"color": STATUS["crit"], "value": 1}],
        description="PAGES ON >= 1. One user unable to get their money out is the failure "
                    "this platform is least allowed to have, and it is invisible to every "
                    "latency and error-rate metric — the request succeeded, the money did "
                    f"not move. Runbook: {RUNBOOK}/runbook-stuck-withdrawal.md"))

    p.append(bargauge(
        "Deposit funnel — detected → confirmed → credited",
        [target("wallet_deposit_total", "{{stage}}", instant=True)],
        "none", {"h": 6, "w": 10, "x": 6, "y": y},
        description="An ORDINAL funnel: the stages are a sequence, so the form is a sorted "
                    "bar and the reading is where the drop is. Detected-but-not-credited "
                    "is a user staring at a wallet that has not changed."))

    # Was "Frozen deposit addresses" on `sum(wallet_deposit_address_frozen)`, a
    # metric no service has ever published and a STATE micro-wallet cannot be in
    # — its status check admits active/rotated/retired and nothing else. The
    # panel therefore read "0" forever, which on a stat panel is indistinguish-
    # able from a measured all-clear. See the DepositAddressUnwatched comment in
    # prometheus/rules/alerts.yaml for the full history.
    p.append(stat(
        "Deposit addresses the indexer is not watching",
        [target("sum(wallet_deposit_addresses_unwatched - wallet_deposit_addresses_unobservable)",
                "unwatched")],
        "none", {"h": 6, "w": 4, "x": 16, "y": y}, decimals=0, graph=False,
        steps=[{"color": STATUS["good"], "value": None}, {"color": STATUS["warn"], "value": 1}],
        description="Assigned to users, and the indexer has not been told to watch them — a "
                    "deposit to one is never seen and is credited to nobody. `unobservable` "
                    "is subtracted deliberately: a chain the indexer follows no source for "
                    "is an owner's decision, and today that is seven of eight chains. "
                    f"Runbook: {RUNBOOK}/runbook-deposit-address-unwatched.md"))

    p.append(stat(
        "Sweep backlog",
        [target("sum(settlement_sweep_pending)", "pending")],
        "none", {"h": 6, "w": 4, "x": 20, "y": y}, decimals=0,
        steps=[{"color": STATUS["good"], "value": None},
               {"color": STATUS["warn"], "value": 25},
               {"color": STATUS["crit"], "value": 200}],
        description="Sweeps queue while custody is down, and that is the correct "
                    "degradation. A backlog that does not drain after custody returns is "
                    "not."))
    y += 6

    p.append(timeseries(
        "Confirmation lag per chain — p50",
        [target('indexer_confirmation_lag_seconds{quantile="0.5"}', "{{chain}}", ref="A")],
        "s", {"h": 7, "w": 12, "x": 0, "y": y}, decimals=0,
        overrides=_series_overrides(["hearth", "ethereum", "ember", "solana", "bitcoin", "xrp"]),
        description="Colour follows the CHAIN, not its rank: filtering this down to three "
                    "chains must not recolour the survivors."))
    p.append(timeseries(
        "Confirmation lag per chain — p95",
        [target('indexer_confirmation_lag_seconds{quantile="0.95"}', "{{chain}}", ref="A")],
        "s", {"h": 7, "w": 12, "x": 12, "y": y}, decimals=0,
        overrides=_series_overrides(["hearth", "ethereum", "ember", "solana", "bitcoin", "xrp"]),
        description="A separate panel from p50 sharing the time range. Same measure, "
                    "different quantile — and the SLO is 'credited within confirmation "
                    "depth + 5 min', which p95 answers and p50 hides."))
    y += 7

    p.append(bargauge(
        "Withdrawal state age",
        [target("withdrawal_state_age_seconds", "{{state}}", instant=True)],
        "s", {"h": 7, "w": 12, "x": 0, "y": y},
        steps=[{"color": STATUS["good"], "value": None},
               {"color": STATUS["warn"], "value": 900},
               {"color": STATUS["crit"], "value": 3600}],
        description="pending / signed / broadcast. The SLO is broadcast within 15 minutes "
                    "of approval, so 900s is the warning line. Age, not count: one "
                    "withdrawal sitting for six hours matters more than fifty for six "
                    "seconds."))

    p.append(timeseries(
        "Treasury balance vs target float",
        [target("settlement_treasury_balance_native", "{{chain}}", ref="A")],
        "none", {"h": 7, "w": 12, "x": 12, "y": y}, decimals=6,
        overrides=_series_overrides(["hearth", "ethereum", "ember", "solana", "bitcoin", "xrp"]) + [
            # The target is a THRESHOLD, drawn as a line by the threshold config
            # — deliberately not a second series. A target is not a measurement,
            # and putting it in the legend invites somebody to plot it.
            {"matcher": {"id": "byName", "options": "target"},
             "properties": [{"id": "custom.hideFrom",
                             "value": {"legend": True, "tooltip": False, "viz": False}}]}],
        thresholds=[{"color": STATUS["crit"], "value": None}, {"color": STATUS["good"], "value": 0.1}],
        description="Target float is drawn as a threshold, not as a second series. A target "
                    "is not a measurement; giving it a legend entry invites somebody to "
                    "treat it as one."))
    y += 7

    return dashboard(
        "cf-deposits-withdrawals", "CloudsForge · Deposits & withdrawals",
        "Owner: the wallet team. Question: is money moving?",
        p, refresh="1m")


# ===========================================================================
# 5 — Chain health.  Owner: the indexer team.
# ===========================================================================
def chain_health():
    p, y = [], 0

    p.append(timeseries(
        "Indexer lag, in blocks",
        [target("indexer_lag_blocks", "{{chain}}", ref="A"),
         target("indexer_confirmation_depth", "depth — {{chain}}", ref="B")],
        "none", {"h": 7, "w": 12, "x": 0, "y": y}, decimals=0,
        overrides=_series_overrides(["hearth", "ethereum", "ember", "solana", "bitcoin", "xrp"]),
        description="Both series are BLOCKS, which is why the confirmation depth may share "
                    "this panel — it is the same unit and the same scale. Past the depth, "
                    "deposits are provably not being credited, and that pages. Hearth's "
                    "depth is 60 and Bitcoin's is not, so the threshold is read from the "
                    f"chain rather than hardcoded. Runbook: {RUNBOOK}/runbook-indexer-lag.md"))

    p.append(timeseries(
        "Reorg depth events",
        [target("indexer_reorg_depth", "{{chain}}", ref="A")],
        "none", {"h": 7, "w": 12, "x": 12, "y": y}, decimals=0,
        overrides=_series_overrides(["hearth", "ethereum", "ember", "solana", "bitcoin", "xrp"]),
        description="A reorg deeper than the policy depth means something was credited on a "
                    f"block that no longer exists. Runbook: {RUNBOOK}/runbook-reorg-recovery.md"))
    y += 7

    p.append(timeseries(
        "RPC provider success ratio",
        [target("indexer_rpc_success_ratio", "{{provider}}", ref="A")],
        "percentunit", {"h": 7, "w": 8, "x": 0, "y": y}, decimals=3,
        fixed=CAT[1],
        description="The indexer is the largest consumer of chain RPC and these metrics are "
                    "the bill as well as the health. Provider count is open-ended, so one "
                    "hue and hover — not a ninth generated colour."))
    p.append(timeseries(
        "RPC failovers",
        [target("sum by (provider) (increase(indexer_rpc_failover_total[15m]))", "{{provider}}")],
        "none", {"h": 7, "w": 8, "x": 8, "y": y}, decimals=0, fixed=CAT[2],
        description=f"Failover working is a ticket, not a page. Runbook: "
                    f"{RUNBOOK}/runbook-rpc-provider-failover.md"))
    p.append(timeseries(
        "RPC rate-limit rejections",
        [target("sum by (provider) (increase(indexer_rpc_rate_limited_total[15m]))", "{{provider}}")],
        "none", {"h": 7, "w": 8, "x": 16, "y": y}, decimals=0, fixed=CAT[5],
        description="A separate panel from failover: a provider rate-limiting us and a "
                    "provider being down look the same in a success ratio and are different "
                    "problems with different fixes."))
    y += 7

    p.append(row("Forge Network — Hearth", y)); y += 1

    # Three measures, three panels. Never one chart with two axes — the estate's
    # named example of the rule (chart-palette.md §10).
    p.append(timeseries(
        "Block height",
        [target("beacon_chain_height", "height")],
        "none", {"h": 6, "w": 6, "x": 0, "y": y}, fixed=CAT[0], legend=False, decimals=0,
        description="One unlabelled series, because the chain has one height. Which node is "
                    "ahead is not the question anyone asks of this metric — whether the "
                    "nodes disagree is, and that is the next panel."))
    p.append(stat(
        "Height spread across nodes",
        [target("beacon_chain_height_spread", "spread")],
        "none", {"h": 6, "w": 6, "x": 6, "y": y}, decimals=0,
        steps=[{"color": STATUS["good"], "value": None},
               {"color": STATUS["warn"], "value": 1},
               {"color": STATUS["crit"], "value": 4}],
        description="Sustained non-zero is a partition or a fork, not a slow node. Do not "
                    f"restart nodes until you know which chain is the chain. Runbook: "
                    f"{RUNBOOK}/runbook-hearth-fork.md"))
    p.append(timeseries(
        "Peers per node",
        [target("beacon_chain_peers", "{{node}}")],
        "none", {"h": 6, "w": 6, "x": 12, "y": y}, decimals=0,
        overrides=_series_overrides(["seed", "miner1", "miner2"]),
        description="A miner at zero peers is not down. It is mining a chain nobody will "
                    f"accept, which is worse. Runbook: {RUNBOOK}/runbook-hearth-node-down.md"))
    p.append(timeseries(
        "Mempool depth",
        [target("beacon_chain_mempool", "pending")],
        "none", {"h": 6, "w": 6, "x": 18, "y": y}, fixed=CAT[3], legend=False, decimals=0,
        description="Read from the seed only: a backlog is a property of the network, and "
                    "reading it from three nodes emits three answers to one question. "
                    "Rising depth means transactions are not being mined, not that the "
                    "chain is busy."))
    y += 6

    p.append(table(
        "EVM conformance — failing vectors by suite",
        [target('beacon_conformance_vectors{result="failed"} > 0', "", instant=True, fmt="table")],
        {"h": 7, "w": 12, "x": 0, "y": y},
        transformations=[{"id": "organize", "options": {
            "excludeByName": {"Time": True, "job": True, "instance": True, "result": True},
            "renameByName": {"Value": "failed vectors"}}}],
        description="Beacon runs Hearth's 31 suites, not Hearth's own CI. A suite that could "
                    "not be RUN reports under result=\"skipped\" and never under \"passed\", "
                    "so an empty table here means passing and not missing. Non-zero blocks "
                    "the next Hearth release."))

    p.append(stat(
        "Chain probe state",
        [target('beacon_target_up{group="chain"}', "{{target}}", instant=True)],
        "none", {"h": 7, "w": 12, "x": 12, "y": y}, mappings=TARGET_MAPPINGS, graph=False,
        steps=[{"color": STATUS["crit"], "value": None},
               {"color": STATUS["warn"], "value": 0.5},
               {"color": STATUS["good"], "value": 1}],
        description="Beacon's hysteresis-filtered state — the same value the status grid "
                    "shows, so an alert built on it fires when the status page turns red "
                    "and not before. 0.5 is 'answered, but with a caveat', which is a real "
                    "third state and not a rounding of down."))
    y += 7

    return dashboard(
        "cf-chain-health", "CloudsForge · Chain health",
        "Owner: the indexer team. Question: are we seeing the chains correctly?",
        p, refresh="1m")


BUILDERS = [platform_overview, service_detail, money_integrity,
            deposits_withdrawals, chain_health]

if __name__ == "__main__":
    out = HERE / "dashboards"
    out.mkdir(exist_ok=True)
    for build in BUILDERS:
        d = build()
        path = out / f"{d['uid']}.json"
        path.write_text(json.dumps(d, indent=2) + "\n")
        n = sum(1 for p in d["panels"] if p["type"] != "row")
        print(f"{path.name}: {n} panels")
