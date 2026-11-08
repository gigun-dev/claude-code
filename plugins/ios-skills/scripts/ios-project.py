#!/usr/bin/env python3
"""Resolve one Xcode input consistently for device builds and archive/upload."""
import argparse
from pathlib import Path
import sys


def resolve(value):
    path = Path(value).expanduser().resolve()
    if "\n" in str(path) or "\r" in str(path):
        raise ValueError("project paths must not contain newlines")
    if not path.is_dir():
        raise ValueError("project must be an existing .xcodeproj/.xcworkspace directory")
    if path.suffix not in (".xcworkspace", ".xcodeproj"):
        candidates = sorted(p for p in path.glob("*.xcworkspace") if p.is_dir())
        if not candidates:
            candidates = sorted(p for p in path.glob("*.xcodeproj") if p.is_dir())
        if len(candidates) != 1:
            raise ValueError("directory must contain exactly one workspace or project; pass it explicitly")
        path = candidates[0]
    if "\n" in str(path) or "\r" in str(path):
        raise ValueError("project paths must not contain newlines")
    return ("-workspace" if path.suffix == ".xcworkspace" else "-project", str(path))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project")
    args = parser.parse_args()
    try:
        print("\n".join(resolve(args.project)))
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 4
    return 0


if __name__ == "__main__":
    sys.exit(main())
