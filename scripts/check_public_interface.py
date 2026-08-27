#!/usr/bin/env python3
"""Assert graded's public API names no `graded/internal` type.

A `pub fn` name allowlist cannot see an allowed function acquiring an internal
parameter or return type, and the package's own build happily imports its own
internals — so this inspects what a *consumer* sees: the package interface
Gleam exports, walked for every type reference in the `graded` module.
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

INTERNAL_PREFIX = "graded/internal"


def type_references(node, path):
    """Yield (path, module) for every named type reference under `node`."""
    if isinstance(node, dict):
        module = node.get("module")
        if node.get("kind") == "named" and isinstance(module, str):
            yield path, module
        for key, value in node.items():
            # Documentation is prose, not a type reference.
            if key in ("documentation", "deprecation"):
                continue
            yield from type_references(value, f"{path}.{key}")
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from type_references(value, f"{path}[{index}]")


def main():
    with tempfile.TemporaryDirectory() as directory:
        out = Path(directory) / "interface.json"
        subprocess.run(
            ["gleam", "export", "package-interface", "--out", str(out)],
            check=True,
        )
        interface = json.loads(out.read_text())

    module = interface["modules"].get("graded")
    if module is None:
        sys.exit("no `graded` module in the exported package interface")

    leaks = sorted(
        {
            f"{path}: {referenced}"
            for path, referenced in type_references(module, "graded")
            if referenced.startswith(INTERNAL_PREFIX)
        }
    )
    if leaks:
        print("graded's public API names internal types:", file=sys.stderr)
        for leak in leaks:
            print(f"  {leak}", file=sys.stderr)
        sys.exit(1)

    print("graded's public API names no graded/internal type")


if __name__ == "__main__":
    main()
