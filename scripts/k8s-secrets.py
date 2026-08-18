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
"""
import argparse
import os
import pathlib
import re
import subprocess
import sys
import tempfile

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
    ],
}

NAMESPACES = {"mainnet": "cloudsforge-estate", "testnet": "cf-testnet"}

# The variable holding the Postgres password, which becomes a basic-auth Secret
# of its own because CloudNativePG requires that shape for `bootstrap.initdb`.
PG_PASSWORD_VAR = "CF_POSTGRES_PASSWORD"
PG_USER = "cloudsforge"
PG_SECRET = "pg-cloudsforge"


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
    args = parser.parse_args()

    root = pathlib.Path(args.root)
    namespace = NAMESPACES[args.network]
    entries = FILES[args.network]

    print(f"network={args.network} namespace={namespace} mode={'APPLY' if args.apply else 'dry-run (names only)'}")
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

    ok = True
    pg_password = None
    for name, rel, kind in entries:
        path = root / rel
        data = parse_env(path)
        print(f"  {name}  ({kind})  <- {rel}   [{len(data)} key(s)]")
        if args.audit_quoting:
            naive = {}
            for raw in path.read_text().split("\n"):
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                naive[k.strip()] = v
            differ = sum(1 for k in data if k in naive and naive[k] != data[k])
            print(f"    quoting audit: {differ} of {len(data)} value(s) differ from a naive parse")
        if PG_PASSWORD_VAR in data:
            pg_password = data[PG_PASSWORD_VAR]
        # An `interp` file is stored whole so the cluster can be rebuilt without
        # the host, but it is not mounted into anything — see the note on FILES.
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

    print()
    print("Nothing above is a value. If you can read a credential in this output, that is a bug — report it.")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
