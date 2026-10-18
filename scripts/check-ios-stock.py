#!/usr/bin/env python3
"""Verify that the iOS source, extension, project and config match upstream."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=True).stdout


def main():
    manifest = json.loads((ROOT / "Config/TV-Upstream.json").read_text())
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default=manifest["commit"], help="Upstream commit/ref to compare against")
    args = parser.parse_args()
    baseline = git("rev-parse", "--verify", args.baseline + "^{commit}").strip()
    paths = manifest["paths"]
    changed = git("diff", "--name-status", baseline, "--", *paths).strip()
    untracked = git("ls-files", "--others", "--exclude-standard", "--", *paths).strip()
    if changed or untracked:
        print(f"iOS differs from upstream {baseline[:12]}:", file=sys.stderr)
        if changed:
            print(changed, file=sys.stderr)
        if untracked:
            print("Unexpected iOS files:\n" + untracked, file=sys.stderr)
        return 1
    print(f"iOS source, extension, project and config match upstream {baseline[:12]}.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (subprocess.CalledProcessError, OSError, ValueError) as error:
        sys.exit(f"Could not verify upstream baseline: {error}")
