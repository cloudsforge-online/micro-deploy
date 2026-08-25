"""The two consolidation sets, readable without running the renderer.

`k8s-render.py` parses `argv` and reads files at import time, so it cannot be
imported for its constants — and its filename has a hyphen, which is not a valid
module name anyway. This lifts the two sets out by parsing the source.

Parsed rather than duplicated, deliberately. A second hand-maintained copy of
"which services are consolidated" is exactly the drift this plan has produced
three times already: two lists that are each individually correct and disagree.
"""
from __future__ import annotations

import ast
import pathlib

_SOURCE = pathlib.Path(__file__).resolve().parent / "k8s-render.py"


def _set_literal(name: str) -> set[str]:
    tree = ast.parse(_SOURCE.read_text())
    for node in tree.body:
        target = None
        if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            target = node.target.id
        elif isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            target = node.targets[0].id
        if target != name or node.value is None:
            continue
        value = ast.literal_eval(node.value)
        return set(value)
    raise SystemExit(f"FAIL: {name} not found in {_SOURCE} — the renderer moved it, and this shim is now silently wrong")


CONSOLIDATED_SERVICES: set[str] = _set_literal("CONSOLIDATED_SERVICES")
SINGLE_DATABASE_SERVICES: set[str] = _set_literal("SINGLE_DATABASE_SERVICES")
