"""Fetch only the pinned official SOMA Gym's referenced motion assets."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bridge"))
from paths import UPSTREAM, RUNTIME

REVISION = "54fc563aeaaf819a753d72cc9fdc6713989cdd43"


def referenced_motions():
    assets = UPSTREAM / "assets"
    scene = assets / "scenes/soma_gym.scene.json"
    scene_data = json.loads(scene.read_text())
    documents = [(scene.parent / item["reference"]).resolve() for item in scene_data["smart_primitives"]]
    documents += [assets / f"smart_primitives/soma/{name}.smart_primitive.json" for name in
                  ("locomotion_bs1_linear", "locomotion_bs2_directional", "locomotion_bs2_directional_crouch")]
    motions = set()

    def visit(node, base):
        if isinstance(node, dict):
            if node.get("clip"):
                motions.add((base / node["clip"]).resolve())
            for value in node.values():
                visit(value, base)
        elif isinstance(node, list):
            for value in node:
                visit(value, base)

    for document in documents:
        visit(json.loads(document.read_text()), document.parent)
    motions.update(assets / f"motions/soma/locomotion/idle/{name}.bvh" for name in
        ("idle_loop_001__A268", "neutral_looking_around_R_001__A542", "warm_up_neck_001__A359",
         "legs_relax_002__A407", "crouch_idle_001__A529"))
    motions.add(assets / "motions/soma/sitting/sit_on_chair_loop.bvh")
    return sorted(motions)


def prepare():
    for path in referenced_motions():
        relative = path.relative_to(UPSTREAM).as_posix()
        pointer = subprocess.check_output(["git", "-C", str(UPSTREAM), "show", f"{REVISION}:{relative}"], text=True)
        digest = next(line.split(":", 1)[1] for line in pointer.splitlines() if line.startswith("oid sha256:"))
        if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == digest:
            continue
        cache = RUNTIME / "downloads" / digest
        lfs = UPSTREAM / ".git/lfs/objects" / digest[:2] / digest[2:4] / digest
        cache.parent.mkdir(parents=True, exist_ok=True)
        if lfs.exists():
            shutil.copyfile(lfs, cache)
        if not cache.exists():
            print(f"Downloading {relative}", flush=True)
            temporary = cache.with_suffix(".partial")
            url = f"https://media.githubusercontent.com/media/NVlabs/motionbricks/{REVISION}/{relative}"
            with urllib.request.urlopen(url, timeout=60) as response, temporary.open("wb") as output:
                shutil.copyfileobj(response, output)
            if hashlib.sha256(temporary.read_bytes()).hexdigest() != digest:
                raise RuntimeError(f"SHA256 mismatch: {relative}")
            temporary.replace(cache)
        if hashlib.sha256(cache.read_bytes()).hexdigest() != digest:
            raise RuntimeError(f"Cached SHA256 mismatch: {relative}")
        shutil.copyfile(cache, path)
    print("Official SOMA Gym motion assets ready", flush=True)


if __name__ == "__main__":
    prepare()
