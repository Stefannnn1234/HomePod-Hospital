#!/usr/bin/env python3
# Superseded by pack.py (same output, Python standard library only — no pyimg4).
# Kept as a thin alias so older references keep working.
import os, runpy
runpy.run_path(os.path.join(os.path.dirname(os.path.abspath(__file__)), "pack.py"), run_name="__main__")
