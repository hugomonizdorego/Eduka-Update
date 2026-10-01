#!/usr/bin/python3
"""Write the current EUS panel state atomically for Eduka-Panel."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
import time
from pathlib import Path


VALID_STATES = ("hidden", "idle", "available", "running", "finished")


def runtime_base() -> Path:
    configured = os.environ.get("XDG_RUNTIME_DIR")
    if configured:
        return Path(configured)
    normal = Path("/run/user") / str(os.getuid())
    if normal.is_dir():
        return normal
    return Path(tempfile.gettempdir()) / f"eus-runtime-{os.getuid()}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Set Eduka-Update-System panel status")
    parser.add_argument("state", choices=VALID_STATES)
    parser.add_argument("--count", type=int, default=0)
    parser.add_argument("--progress", type=int, default=-1)
    parser.add_argument("--message", default="")
    args = parser.parse_args()

    state_dir = runtime_base() / "eduka-update-system"
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    state_file = state_dir / "panel-status.json"
    payload = {
        "version": 1,
        "state": args.state,
        "count": max(0, args.count),
        "progress": min(100, max(-1, args.progress)),
        "message": args.message.strip(),
        "updated_at": int(time.time()),
    }
    temp_file = state_dir / f"panel-status.{os.getpid()}.tmp"
    temp_file.write_text(json.dumps(payload, separators=(",", ":")) + "\n", encoding="utf-8")
    temp_file.chmod(0o600)
    os.replace(temp_file, state_file)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
