"""Project-local runtime paths and DLL/cache setup; no global Python changes."""
import os
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / ".runtime"
_temporary = RUNTIME / "tmp"
_temporary.mkdir(parents=True, exist_ok=True)
os.environ["TEMP"] = os.environ["TMP"] = str(_temporary)
tempfile.tempdir = str(_temporary)
UPSTREAM = RUNTIME / "motionbricks"
sys.path.insert(0, str(UPSTREAM))
os.environ.setdefault("PROCESSOR_ARCHITECTURE", "AMD64")
_dll_handles = []
if os.name == "nt":
    for directory in (Path(sys.prefix) / "Lib/site-packages").glob("**/bin"):
        _dll_handles.append(os.add_dll_directory(str(directory)))


def initialize_warp(device="cuda:0"):
    import warp as wp
    wp.config.kernel_cache_dir = str(RUNTIME / "warp-cache")
    wp.init()
    wp.set_device(device)
    return wp
