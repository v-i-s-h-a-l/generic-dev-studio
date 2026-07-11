#!/usr/bin/env python3
"""SDL trust-anchor validation wrapper.

Calls the shared helper in ``.stibdedlom/lib/sdl_hooks.py``.
"""

from __future__ import annotations

import sys
from pathlib import Path

lib_dir = Path(__file__).resolve().parent.parent / "lib"
sys.path.insert(0, str(lib_dir))

from sdl_hooks import trust_anchor_cli  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(trust_anchor_cli())
