"""Prove saved editor placements drive targets, probes, entries and reset spawn."""
import json
from pathlib import Path
import sys
import numpy as np
from scipy.spatial.transform import Rotation

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/"bridge"))
from gym_runtime import GymRuntime
from check_gym import check_station


def matrix(value):
    result = np.eye(4)
    result[:3, :3] = Rotation.from_quat(value["rotation"]).as_matrix()
    result[:3, 3] = value["position"]
    return result


def main():
    directory = ROOT/"logs/editor-scene"
    default = json.loads((directory/"default-layout.json").read_text(encoding="utf-8"))
    edited = json.loads((directory/"edited-layout.json").read_text(encoding="utf-8"))
    runtime = GymRuntime()
    try:
        assert runtime.configure_scene(default)
        baseline = runtime.scene_status(True)
        serial = runtime.teleport_serial
        assert not runtime.configure_scene(default)
        assert runtime.teleport_serial == serial, "Repeated UDP config must not reset the player"
        assert runtime.configure_scene(edited)
        moved = runtime.scene_status(True)
        assert set(runtime.entries) == {2, 5, 10}, "Disabled station must not retain triggers or shortcuts"
        original_station = next(s for s in default["stations"] if s["id"] == 2)
        changed_station = next(s for s in edited["stations"] if s["id"] == 2)
        delta = matrix(changed_station) @ np.linalg.inv(matrix(original_station))
        errors = []
        for key in ("entries", "boxes"):
            before = [item for item in baseline[key] if item["id"] == 2]
            after = [item for item in moved[key] if item["id"] == 2]
            assert len(before) == len(after) > 0
            for a, b in zip(before, after):
                error = float(np.max(np.abs(delta@matrix(a)-matrix(b))))
                errors.append(error)
                assert error < 1e-3, f"Edited {key} remained at the old placement: {error}"
        pose = runtime.step(1/60, [1, 0, 0], 0, 1, auto_interact=False)
        spawn_error = float(np.linalg.norm(pose[0, [0, 2]]-np.asarray(edited["start"]["position"])[[0, 2]]))
        assert spawn_error < 0.1
        interaction = check_station(runtime, 2)
        assert interaction["passed"], "Moved/rotated station must still generate its action"
        runtime.reset()
        pose = runtime.step(1/60, [1, 0, 0], 0, 2, auto_interact=False)
        assert np.linalg.norm(pose[0, [0, 2]]-np.asarray(edited["start"]["position"])[[0, 2]]) < 0.1
        assert runtime.configure_scene(default)
        assert set(runtime.entries) == {2, 5, 10, 12}
        report = {"passed": True, "max_entry_and_trigger_transform_error": max(errors),
            "spawn_error_m": spawn_error, "configuration_is_idempotent": True,
            "disabled_station_removed": True, "moved_station_interaction": True,
            "reset_uses_editor_spawn": True, "default_scene_restored": True}
        (directory/"backend-check.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(json.dumps(report), flush=True)
    finally:
        runtime.close()


if __name__ == "__main__":
    main()
