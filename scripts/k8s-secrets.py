#!/usr/bin/env python3
"""Load the estate's untracked env files into Kubernetes Secrets. Values NEVER printed.

    ./scripts/k8s-secrets.py --network mainnet          # show what WOULD be created, by name
    ./scripts/k8s-secrets.py --network mainnet --apply  # create/update them

══════════════════════════════════════════════════════════════════════════════
WHAT THIS IS ALLOWED TO PRINT, AND WHY THE RULE IS ABSOLUTE
══════════════════════════════════════════════════════════════════════════════

Variable NAMES, file names, and counts. Never a value, never part of a value,
never a length, never a hash.

Not a style preference — a rule this estate arrived at by losing twice. A
"redacting" pattern that prints values with a regex applied leaked a live
credential on two separate occasions, because the leak is always the case the
pattern did not match: a value with a newline in it, a name the pattern did not
recognise as sensitive, a URL that carried the credential in its userinfo. So
this does not redact. It never has the value in a printable position at all.
Values move from the file to the Kubernetes API through a 0600 temp file and are
unlinked, and the only thing that reaches a terminal is a name.

══════════════════════════════════════════════════════════════════════════════
WHY IT PARSES THE ENV FILES ITSELF INSTEAD OF USING `--from-env-file`
══════════════════════════════════════════════════════════════════════════════

`kubectl create secret generic --from-env-file` exists and is one flag, and it
would have been wrong. kubectl takes the whole of the line after `=` literally.
Compose does not: it strips matched surrounding quotes, processes `\n` and `\"`
inside double quotes, treats single quotes as literal-with-no-escapes, and drops
a trailing ` #` comment on an unquoted value.

So for any value written as `KEY="hunter2"`, kubectl's Secret holds
`"hunter2"` — six characters plus two quotes — while every container running
under compose today receives `hunter2`. The estate would come up on Kubernetes
with a subset of its credentials silently wrong, authenticating nowhere, and the
symptom would be 401s from services whose configuration looks correct in
`kubectl get secret -o yaml` because the quotes are the value.

This implements compose's dotenv rules directly, and `--audit-quoting` reports
how many values in each file are affected so the difference is a measured number
rather than a worry.

MEASURED 2026-08-19, and the answer is reassuring: across all 16 files, both
networks, 0 of 61 mainnet and 0 of 53 testnet values differ from a naive parse.
Nothing in the estate is quoted today, so `--from-env-file` would in fact have
produced identical Secrets.

That is a fact about today, not a property of the system, and it is exactly the
kind of fact that stops being true when somebody adds a password containing a
`#` and correctly quotes it. Keeping the parser costs nothing and means that
edit does not become an outage; `--audit-quoting` is how the claim gets
re-checked rather than assumed.

There is a SECOND thing compose does to these files that a literal copy does
not: it interpolates `${VAR}` inside their values. That one is not hypothetical
— it took the indexer down on the first cluster deploy. See
`interpolate_env_file`.
"""
import argparse
import os
import pathlib
import re
import subprocess
import sys
import tempfile

try:
    import yaml
except ModuleNotFoundError:
    sys.exit(
        "FAIL: PyYAML is not installed, so the render-vars file cannot be read.\n"
        "       python3 -m pip install pyyaml"
    )

# ── THE FILE MAP: which env file becomes which Secret ─────────────────────────
#
# `kind` decides how the Secret is consumed by the rendered workloads:
#
#   "envfrom"  the file is an `env_file:` in compose, so every key becomes an
#              environment variable. Rendered as `envFrom: [secretRef: ...]`.
#   "interp"   the file is an `--env-file` for INTERPOLATION — compose
#              substitutes `${VAR}` in the compose file itself and the container
#              never sees these names. The renderer reads it to build values,
#              and it is stored so the cluster can be rebuilt without the host.
#
# The distinction matters: `tokens.env` holds the variables that get interpolated
# INTO connection strings, so its keys must not be injected wholesale into every
# container's environment. That would hand every service every other service's
# credential, which is the opposite of what the 57 separate DSNs are for.
#
# ── WHY `env-traefik` IS HERE, WHEN THE FILE IS COMMITTED AND HOLDS NO SECRET ──
#
# `compose/env/traefik.env` is tracked and public — the file says so itself, and
# ACME credentials are deliberately kept out of it. It is loaded here anyway,
# because of one line:
#
#     CF_RPC_UPSTREAM=http://${CF_CHAIN_HOST:-host.docker.internal}:8545
#
# CF_CHAIN_HOST is a `secret_vars` entry that lives in the untracked tokens file.
# So the file is public but its INTERPOLATED result is not derivable from the
# repository, and this is the one path in the estate that already resolves such a
# value correctly, never prints it, and stores it where the cluster can rebuild
# itself without the host. A ConfigMap built by hand would have needed a second
# copy of the interpolation rules and a second chance to get the fallback wrong —
# and getting it wrong is silent: the gateway would proxy to
# `host.docker.internal`, which does not resolve in a pod, and every chain-facing
# route would answer 502 while the gateway itself stayed healthy.
FILES = {
    "mainnet": [
        ("estate-tokens", "compose/estate/tokens.env", "interp"),
        ("secret-outbox", "compose/secrets/outbox.mainnet.env", "envfrom"),
        ("secret-custody", "compose/secrets/custody.mainnet.env", "envfrom"),
        ("secret-identity-key", "compose/secrets/identity-key.mainnet.env", "envfrom"),
        ("secret-analytics-pepper", "compose/secrets/analytics-pepper.mainnet.env", "envfrom"),
        ("secret-studio", "compose/secrets/studio.mainnet.env", "envfrom"),
        ("secret-chainrpc", "compose/secrets/chainrpc.mainnet.env", "envfrom"),
        ("env-chain", "compose/env/chain.mainnet.env", "envfrom"),
        ("env-traefik", "compose/env/traefik.env", "envfrom"),
    ],
    "testnet": [
        ("estate-tokens", "compose/estate/tokens.testnet.env", "interp"),
        ("secret-outbox", "compose/secrets/outbox.testnet.env", "envfrom"),
        ("secret-custody", "compose/secrets/custody.testnet.env", "envfrom"),
        ("secret-identity-key", "compose/secrets/identity-key.testnet.env", "envfrom"),
        ("secret-analytics-pepper", "compose/secrets/analytics-pepper.testnet.env", "envfrom"),
        ("secret-studio", "compose/secrets/studio.testnet.env", "envfrom"),
        ("secret-chainrpc", "compose/secrets/chainrpc.testnet.env", "envfrom"),
        ("env-chain", "compose/env/chain.testnet.env", "envfrom"),
        ("env-traefik", "compose/env/traefik.testnet.env", "envfrom"),
    ],
}

NAMESPACES = {"mainnet": "cloudsforge-estate", "testnet": "cf-testnet"}

# The estate's OTHER `--env-file`. Compose is handed BOTH — `release-deploy.sh`
# builds `ENVSET=(--env-file "$ESTATE_ENV" --env-file "$TOKENS_FILE")` — and the
# environment it interpolates with is their merge. Measured on the deployment
# host, 2026-08-19, with a two-file probe: a name in both files takes the value
# from the file passed LAST, and names unique to either file are all present. So
# the merge here is `estate` first, `tokens` over the top, in that order.
#
# The shell environment is deliberately NOT part of it. Compose would let an
# exported variable outrank both files, which is the hazard `release-deploy.sh`
# spends a paragraph on; a Secret whose contents depend on who ran the script is
# not a Secret anybody can reason about.
ESTATE_ENV = "compose/{network}.env"

# The variable holding the Postgres password, which becomes a basic-auth Secret
# of its own because CloudNativePG requires that shape for `bootstrap.initdb`.
PG_PASSWORD_VAR = "CF_POSTGRES_PASSWORD"
PG_USER = "cloudsforge"
PG_SECRET = "pg-cloudsforge"

# The Secret holding values that had to be COMPUTED from other credentials
# because Kubernetes' `$(VAR)` expansion cannot express the computation. Today
# that is `SETTLEMENT_RPC_URLS` alone; see the render-vars comment for why a
# conditional JSON object is not something a manifest can assemble.
DERIVED_SECRET = "estate-derived"
RENDER_VARS = "k8s/estate/render-vars.{network}.yaml"

# The subset of shell parameter expansion the derived expressions use. Anything
# outside it is a hard failure rather than a best effort — see `expand`.
EXPANSION = re.compile(
    r"""\$\{
          ([A-Za-z_][A-Za-z0-9_]*)      # 1: name
          (?: (:-|:\+) ([^{}]*) )?      # 2: operator, 3: operand
        \}
      | \$ ([A-Za-z_][A-Za-z0-9_]*)     # 4: bare $NAME
    """,
    re.VERBOSE,
)


def expand(expression, values, depth=0, where="a derived expression"):
    """Evaluate the restricted shell expansion the derived expressions use.

    Supports exactly `${NAME}`, `${NAME:-default}`, `${NAME:+alternative}` and
    `$NAME`, where an operand may itself contain expansions. Empty counts as
    unset, which is what `:-` and `:+` mean in a shell and what the compose file
    is relying on.

    IMPLEMENTED HERE RATHER THAN BY CALLING A SHELL, and not for tidiness. The
    inputs are credentials. Handing a string containing a live value to `bash -c`
    means a value containing a backtick or `$(` is executed, and the estate's
    tokens are machine-generated strings nobody has audited for shell
    metacharacters. Passing them through the environment instead of argv fixes
    the `ps` exposure but not the execution. There is no safe way to let a shell
    see them, so no shell does.
    """
    if depth > 8:
        sys.exit(f"FAIL: {where} nests more than 8 levels; refusing to evaluate it.")

    # Refuse anything this parser would silently mis-read. A `${` that does not
    # match the grammar would otherwise be copied through as a literal, and the
    # result — a settlement RPC map with `${` in it — fails at boot in a way that
    # points at settlement rather than at here.
    for stray in re.finditer(r"\$\{", expression):
        if not any(m.start() == stray.start() for m in EXPANSION.finditer(expression)):
            sys.exit(
                "FAIL: {} uses parameter expansion this script does not implement\n"
                "      (nesting, or an operator other than `:-` / `:+`).\n"
                "      Position {} of the expression. The expression is not printed: it is a\n"
                "      template over credentials.".format(where, stray.start())
            )
    if "$(" in expression or "`" in expression:
        sys.exit(f"FAIL: {where} contains command substitution. Refusing to evaluate it.")

    def one(match):
        name = match.group(1) or match.group(4)
        operator, operand = match.group(2), match.group(3)
        current = values.get(name) or ""
        if operator == ":-":
            return current or expand(operand, values, depth + 1, where)
        if operator == ":+":
            return expand(operand, values, depth + 1, where) if current else ""
        return current

    return EXPANSION.sub(one, expression)


def interpolate_env_file(rel, data, environment):
    """Substitute `${VAR}` in an `env_file:`'s VALUES, exactly as compose does.

    Returns `(values, report)`, where `report` is a list of
    `(key, [referenced names])` — names only, for printing.

    ── THE DEFECT THIS CLOSES, WHICH TOOK THE INDEXER DOWN ──────────────────
    #
    An `env_file:` is usually thought of as literal: kubectl treats it that way,
    and so does `docker run --env-file`. Compose does not. It interpolates the
    values inside one against the project environment, and `docker-compose.
    estate.yml` is built on that behaviour deliberately — the comment above the
    indexer's `env_file:` records it as measured on the deployment host rather
    than assumed, because two of the variables carry the network in their NAME
    and a compose `environment:` key cannot be interpolated.

    So `compose/env/chain.mainnet.env` contains

        INDEXER_RPC_EMBER_MAINNET=hearth-seed=${EMBER_RPC_URL:-...}

    and the running container receives a URL. Copying the file into a Secret
    verbatim — which is what this script did — hands the container the eleven
    literal characters `${EMBER_RPC_URL`… instead. `indexer/src/env.ts` checks
    that every `INDEXER_RPC_*` parses as a URL and exits, so the symptom was a
    CrashLoopBackOff naming the variable, with a Secret that looks correct in
    `kubectl get secret -o yaml` because the template IS the value.

    ── WHY IT IS A CLASS OF BUG AND NOT ONE VARIABLE ────────────────────────
    #
    Measured across both networks, 2026-08-19: exactly one value per network
    contains a `$` at all, and it is this one. Every value in all twelve
    `compose/secrets/*.env` files is literal today. That is a fact about today —
    the moment somebody writes a second such reference, this would have produced
    another service down at boot with a correct-looking manifest. Interpolating
    here is what makes the compose file and the cluster the same estate.

    ── AND WHY IT REFUSES RATHER THAN GUESSES ──────────────────────────────
    #
    Three things it will not do, each because the failure would be silent:

      * `$$`, which compose renders as a literal `$`. Not implemented, because a
        credential containing one would otherwise be quietly mangled into a
        different credential. None exists today; the check is what keeps that
        true.
      * an input that is ITSELF a template. Compose's rules for a chained
        reference through two `--env-file`s are not something to infer from the
        documentation, and the estate has no such case, so it is refused rather
        than modelled.
      * an expansion that comes out empty, or that lands on
        `host.docker.internal`. The first means an input is unset; the second
        means a compose default fired that render-vars records as `drop`,
        because Kubernetes has no Docker bridge. Both would produce a service
        that starts and talks to nothing.
    """
    expanded = {}
    report = []
    for key, value in data.items():
        if "$" not in value:
            expanded[key] = value
            continue
        where = f"{rel}, variable {key}"
        if "$$" in value:
            sys.exit(
                f"FAIL: {where} contains `$$`, compose's escape for a literal dollar sign.\n"
                f"      This script does not implement it, and treating it as a reference would\n"
                f"      change the value rather than fail. Implement it here, with a test, before\n"
                f"      adding one."
            )
        references = sorted({m.group(1) or m.group(4) for m in EXPANSION.finditer(value)})
        for name in references:
            if "$" in (environment.get(name) or ""):
                sys.exit(
                    f"FAIL: {where} refers to {name}, whose own value is a template.\n"
                    f"      Compose's resolution order for a reference chained through two\n"
                    f"      --env-file paths is not something this script should guess. Flatten\n"
                    f"      {name} in the env file, or implement the chain here deliberately."
                )
        result = expand(value, environment, where=where)
        if not result:
            sys.exit(
                f"FAIL: {where} interpolated to the empty string.\n"
                f"      It refers to: {', '.join(references)} — at least one is unset in this\n"
                f"      network's env files. Under compose the container would receive an empty\n"
                f"      variable; here it would receive one too, and the service that reads it\n"
                f"      would fail at boot or, worse, at first use."
            )
        if "host.docker.internal" in result:
            sys.exit(
                f"FAIL: {where} fell back to a `host.docker.internal` default.\n"
                f"      render-vars records `extra_hosts: host.docker.internal: drop` on the\n"
                f"      evidence that no value resolves to it — Kubernetes has no Docker bridge\n"
                f"      and nothing in the cluster resolves the name. An input is unset in this\n"
                f"      network's env files: set it, or change the default and that decision\n"
                f"      together. Referenced: {', '.join(references)}"
            )
        expanded[key] = result
        report.append((key, references))
    return expanded, report


def verify_names(render_vars, tokens, tokens_rel):
    """Compare render-vars' `secret_vars` against the real file, BOTH directions.

    The renderer classifies every `${VAR}` in the compose file as either a
    credential or a setting, and it does so from a committed list because
    `tokens.env` is not in the repository. That list can drift from the file in
    two ways, and they are not equally bad:

      a name here the file lacks — the rendered `secretKeyRef` points at a
      missing key. `optional: false`, so the pod does not start. Loud, and
      recoverable in a minute.

      a name in the file not here — the renderer sees an unclassified variable,
      treats it as configuration, and WRITES ITS VALUE INTO k8s/estate/, which is
      committed. Silent, and recoverable only by rotating the credential.

    The second is the reason this check exists, and the reason it is fatal on
    every run rather than something you opt into with a flag.
    """
    declared = set(render_vars.get("secret_vars") or [])
    present = set(tokens)
    missing_from_file = sorted(declared - present)
    missing_from_list = sorted(present - declared)

    print(f"  secret_vars: {len(declared)} declared, {len(present)} in {tokens_rel}")
    if not missing_from_file and not missing_from_list:
        print("    both directions agree")
        return True
    for name in missing_from_file:
        print(f"    ! declared but absent from the file: {name}   (pod would not start)")
    for name in missing_from_list:
        print(f"    ! in the file but not declared: {name}   (RENDERER WOULD COMMIT ITS VALUE)")
    return False


def parse_env(path):
    """Compose's dotenv semantics. Returns {name: value} — never logs either.

    Implements the rules compose-go/dotenv applies, which is what every container
    in the estate is receiving today:

      * `export ` prefix is stripped
      * `'single'`  → literal; no escape processing at all
      * `"double"`  → \\n \\t \\r \\" \\\\ processed
      * unquoted    → trailing ` #comment` removed, surrounding space trimmed
      * blank lines and lines whose first non-space character is `#` are skipped
    """
    out = {}
    for lineno, raw in enumerate(path.read_text().split("\n"), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        if "=" not in line:
            # Named, not shown: the LINE NUMBER is safe, the line is not — a
            # malformed line is very often a value that lost its key.
            print(f"  ! {path}:{lineno} has no '=' and was skipped", file=sys.stderr)
            continue
        name, _, value = line.partition("=")
        name = name.strip()
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name):
            print(f"  ! {path}:{lineno} has a name that is not a shell identifier, skipped", file=sys.stderr)
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] == "'":
            value = value[1:-1]
        elif len(value) >= 2 and value[0] == value[-1] == '"':
            value = value[1:-1]
            value = (
                value.replace("\\n", "\n")
                .replace("\\r", "\r")
                .replace("\\t", "\t")
                .replace('\\"', '"')
                .replace("\\\\", "\\")
            )
        else:
            # An unquoted value ends at an inline comment, which must be
            # preceded by whitespace to count as one.
            value = re.split(r"\s+#", value, maxsplit=1)[0].rstrip()
        out[name] = value
    return out


def kubectl(args_list, stdin=None):
    env = dict(os.environ)
    env.setdefault("KUBECONFIG", "/etc/rancher/k3s/k3s.yaml")
    return subprocess.run(["kubectl", *args_list], input=stdin, capture_output=True, text=True, env=env)


def apply_secret(namespace, name, data, secret_type="Opaque", dry=True):
    """Create-or-update, with every value passing through a 0600 file and no argv.

    NOT `--from-literal`, which puts the value in argv where `ps` shows it to
    every other user on the box for as long as the call takes. The temp files are
    created with mode 0600 by `mkstemp` and unlinked in a `finally`.
    """
    if dry:
        for key in sorted(data):
            print(f"    {key}")
        return True
    tmpdir = tempfile.mkdtemp(prefix="cfk8s-")
    try:
        os.chmod(tmpdir, 0o700)
        cmd = ["create", "secret", "generic" if secret_type == "Opaque" else "generic", name, "-n", namespace]
        if secret_type != "Opaque":
            cmd += ["--type", secret_type]
        for key, value in sorted(data.items()):
            fp = pathlib.Path(tmpdir) / key
            # `wb` and an explicit encode: a value that is not valid UTF-8 must
            # fail here rather than be silently transcoded into something the
            # service will not accept.
            fp.write_bytes(value.encode("utf-8"))
            fp.chmod(0o600)
            cmd += [f"--from-file={key}={fp}"]
        cmd += ["--dry-run=client", "-o", "yaml"]
        rendered = kubectl(cmd)
        if rendered.returncode != 0:
            # stderr from `create secret` names files and flags, not contents.
            print(f"    FAILED to render {name}: {rendered.stderr.strip()}", file=sys.stderr)
            return False
        applied = kubectl(["apply", "-n", namespace, "-f", "-"], stdin=rendered.stdout)
        if applied.returncode != 0:
            print(f"    FAILED to apply {name}: {applied.stderr.strip()}", file=sys.stderr)
            return False
        print(f"    {applied.stdout.strip()}")
        return True
    finally:
        for child in pathlib.Path(tmpdir).iterdir():
            child.unlink()
        os.rmdir(tmpdir)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--network", required=True, choices=sorted(FILES))
    parser.add_argument("--root", default=".", help="the deploy checkout holding compose/")
    parser.add_argument("--apply", action="store_true", help="actually create them; default is a name-only dry run")
    parser.add_argument(
        "--audit-quoting",
        action="store_true",
        help="report how many values would differ under kubectl's --from-env-file. Counts only.",
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="only compare render-vars' secret_vars against the real file, both directions. Creates nothing.",
    )
    args = parser.parse_args()

    root = pathlib.Path(args.root)
    namespace = NAMESPACES[args.network]
    entries = FILES[args.network]
    mode = "VERIFY" if args.verify else ("APPLY" if args.apply else "dry-run (names only)")

    render_vars_rel = RENDER_VARS.format(network=args.network)
    render_vars_path = root / render_vars_rel
    if not render_vars_path.exists():
        sys.exit(f"FAIL: {render_vars_rel} is missing; it says which variables are credentials.")
    render_vars = yaml.safe_load(render_vars_path.read_text()) or {}

    print(f"network={args.network} namespace={namespace} mode={mode}")
    print()

    missing = [rel for _, rel, _ in entries if not (root / rel).exists()]
    if missing:
        # Refuse the whole run. A partial secret set produces an estate that
        # starts and fails authentication in a subset of services, which is
        # harder to diagnose than one that does not start.
        sys.exit(
            "FAIL: these env files are not present, so the Secret set would be incomplete:\n"
            + "\n".join(f"  {m}" for m in missing)
            + "\n\nThey are gitignored by design and live only on the host. Transfer them; do not recreate them."
        )

    # Everything is parsed BEFORE anything is created. The name check below can
    # fail, and a half-applied Secret set is worse than none: the estate would
    # come up with a subset of its credentials current and no single command that
    # says so.
    parsed = [(name, rel, kind, parse_env(root / rel)) for name, rel, kind in entries]
    tokens_rel, tokens = next(((rel, data) for _, rel, kind, data in parsed if kind == "interp"), (None, None))
    if tokens is None:
        sys.exit("FAIL: this network has no `interp` file, so there is nothing to verify secret_vars against.")

    if not verify_names(render_vars, tokens, tokens_rel):
        sys.exit(
            "\nFAIL: the committed classification and the host's file disagree.\n"
            "      Fix the list in {}, or the file, before rendering or applying\n"
            "      anything. See the comment above `secret_vars:` for what each direction costs.".format(
                render_vars_rel
            )
        )
    print()
    if args.verify:
        print("Nothing above is a value. If you can read a credential in this output, that is a bug — report it.")
        sys.exit(0)

    # ── THE INTERPOLATION ENVIRONMENT ────────────────────────────────────────
    #
    # What compose would substitute WITH: both `--env-file` paths merged, the
    # tokens file last because that is the order every entry point passes them
    # in and the later file wins. See the note on ESTATE_ENV for the
    # measurement, and `interpolate_env_file` for what this is for.
    estate_env_rel = ESTATE_ENV.format(network=args.network)
    estate_env_path = root / estate_env_rel
    if not estate_env_path.exists():
        sys.exit(
            f"FAIL: {estate_env_rel} is missing. It is one of the two `--env-file` paths every\n"
            f"      deploy passes to compose, so without it an `env_file:` value that resolves\n"
            f"      today would resolve to something else here."
        )
    environment = dict(parse_env(estate_env_path))
    environment.update(tokens)

    ok = True
    pg_password = None
    for name, rel, kind, raw in parsed:
        path = root / rel
        # An `interp` file is stored VERBATIM. It is compose's substitution
        # source rather than a container's environment, and it is not mounted
        # into anything — see the note on FILES.
        if kind == "interp":
            data, report = raw, []
        else:
            data, report = interpolate_env_file(rel, raw, environment)
        print(f"  {name}  ({kind})  <- {rel}   [{len(data)} key(s)]")
        for key, references in report:
            print(f"    interpolated: {key}  <-  {', '.join(references)}")
        if args.audit_quoting:
            naive = {}
            for line_raw in path.read_text().split("\n"):
                line = line_raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                naive[k.strip()] = v
            # Against the RAW parse, not the interpolated one. This audit asks a
            # question about quoting alone; counting the interpolated values as
            # differences would answer a question nobody asked and hide the one
            # number the flag exists to report.
            differ = sum(1 for k in raw if k in naive and naive[k] != raw[k])
            print(f"    quoting audit: {differ} of {len(raw)} value(s) differ from a naive parse")
        if PG_PASSWORD_VAR in data:
            pg_password = data[PG_PASSWORD_VAR]
        if not apply_secret(namespace, name, data, dry=not args.apply):
            ok = False

    print()
    if pg_password is None:
        sys.exit(
            f"FAIL: {PG_PASSWORD_VAR} is in none of this network's env files.\n"
            f"      CloudNativePG bootstraps the `{PG_USER}` role from it, and without it the\n"
            f"      cluster would come up with a password the estate's 57 DSNs do not know."
        )
    print(f"  {PG_SECRET}  (kubernetes.io/basic-auth)  <- {PG_PASSWORD_VAR}   [username={PG_USER}]")
    if not apply_secret(
        namespace,
        PG_SECRET,
        {"username": PG_USER, "password": pg_password},
        secret_type="kubernetes.io/basic-auth",
        dry=not args.apply,
    ):
        ok = False

    # ── THE COMPUTED VALUES ──────────────────────────────────────────────────
    #
    # Evaluated here, with the real values, because the expression is
    # conditional and a manifest cannot be. The renderer has already checked
    # this expression byte-for-byte against the compose file, so what is
    # computed here and what compose computes today cannot have drifted.
    derived_vars = render_vars.get("derived_vars") or {}
    if derived_vars:
        print()
        derived = {}
        for key, spec in sorted(derived_vars.items()):
            value = expand(spec["from"], tokens)
            if not value:
                sys.exit(
                    f"FAIL: {key} evaluated to the empty string.\n"
                    f"      Its consumers ({', '.join(spec.get('consumers') or [])}) read it at import and\n"
                    f"      exit; an empty Secret key would take them down at start rather than\n"
                    f"      at first use. Check that its inputs are set in {tokens_rel}."
                )
            if "host.docker.internal" in value:
                # The `:-` default in the compose expression names Docker's
                # bridge gateway. render-vars records `host.docker.internal: drop`
                # on the evidence that it never fires — every network sets its
                # EMBER_RPC_URL explicitly. If it fires here that evidence has
                # expired, and the result would be settlement pointed at a name
                # no cluster DNS resolves: withdrawals failing with a lookup
                # error, on the money tier, with nothing wrong in the manifests.
                sys.exit(
                    f"FAIL: {key} fell back to its `host.docker.internal` default, which does not\n"
                    f"      exist on Kubernetes. An input is unset in {tokens_rel} that was set when\n"
                    f"      render-vars was written. Set it, or change the default and the\n"
                    f"      `extra_hosts:` decision together."
                )
            derived[key] = value
            # The COUNT of contributing variables is safe and is the number worth
            # seeing: it is how you notice a chain silently dropping out.
            contributors = sorted(set(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", spec["from"])) & set(tokens))
            live = [name for name in contributors if tokens.get(name)]
            print(f"  {DERIVED_SECRET}/{key}  <- {len(live)} of {len(contributors)} input(s) set: {', '.join(live)}")
        if not apply_secret(namespace, DERIVED_SECRET, derived, dry=not args.apply):
            ok = False

    print()
    print("Nothing above is a value. If you can read a credential in this output, that is a bug — report it.")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
