"""tools_path — the one place this project's server reaches into ../../tools/.

Relative-path import, per the `universal-wave-translation-layer` convention (there is no shared
package registry in this monorepo). Every tool is an OPTIONAL sibling: someone may have checked
this project out alone, and the server must degrade rather than crash.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "tools"

DESIGN = TOOLS / "design"
