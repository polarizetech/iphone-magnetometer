"""tools_path — the one place the server looks outside this repo, for OPTIONAL siblings.

Today that is only a design system (fonts, colour tokens, icons) for the web page. It is optional:
without it the page renders with its own plain styles. Set FIELDLAB_DESIGN to a directory holding
`design.css`, `design.js`, `tokens.json`, `fonts/` and `icons/`; otherwise `../../tools/design` is
tried, which is where it sits when this repo is checked out as `tools/<name>` in a larger workspace.
"""
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "tools"

DESIGN = Path(os.environ["FIELDLAB_DESIGN"]) if os.environ.get("FIELDLAB_DESIGN") else TOOLS / "design"
