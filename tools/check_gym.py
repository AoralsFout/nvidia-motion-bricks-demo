"""Drive every official Gym interaction through its real probe and state machine."""
import json
from pathlib import Path
import sys
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bridge"))
from gym_runtime import GymRuntime
from locomotion_profile import WALK_SPEED


def check_station(runtime, station_id):
    runtime.select_station(station_id)
    direction = runtime.entries[station_id][1]
    completed_before = len(runtime.completed)
    started_before = len(runtime.started)
    jumps_before = runtime.jump_started
    jump_tested = False
    frames, states = [], []
    seated_frames, stand_requested, settle = 0, False, 0
    parents = runtime.skeleton.parent_indices.numpy()
    head_index = runtime.skeleton.joint_index("Head")
    head_heights = []
    for frame in range(1200):
        started = len(runtime.started) > started_before
        seated = runtime.character.state_machine.is_interacting and runtime.character.state_machine.interaction_state.is_looping
        seated_frames += int(seated)
        press = station_id == 10 and seated_frames >= 60 and not stand_requested
        stand_requested |= press
        jump_press = started and not jump_tested
        jump_tested |= jump_press
        pose = runtime.step(1/60, direction, 0 if started else WALK_SPEED, frame,
                            interact=press, jump=jump_press, auto_interact=True)
        frames.append(pose.copy())
        states.append(runtime.character.state_machine.state.name)
        chain, index = [], head_index
        while index >= 0:
            chain.append(index)
            index = parents[index]
        transform = runtime.wp.transform_identity()
        for index in reversed(chain):
            transform = runtime.wp.mul(transform, runtime.wp.transform(*pose[index]))
        head_heights.append(float(transform.p[1]))
        if len(runtime.completed) > completed_before:
            settle += 1
            if settle >= 30:
                break
    values = np.stack(frames).astype("<f4")
    report = {"id": station_id, "frames": len(frames), "seconds": len(frames)/60,
        "started": len(runtime.started) > started_before,
        "completed": len(runtime.completed) > completed_before,
        "seated_frames": seated_frames, "stand_requested": stand_requested,
        "min_root_height": float(values[:, 0, 1].min()),
        "max_root_height": float(values[:, 0, 1].max()),
        "min_head_height": min(head_heights), "initial_head_height": head_heights[0],
        "finite": bool(np.isfinite(values).all()),
        "start_root": values[0, 0, :3].tolist(), "end_root": values[-1, 0, :3].tolist(),
        "states": sorted(set(states)), "generations": runtime.generations}
    report["busy_jump_ignored"] = jump_tested and runtime.jump_started == jumps_before
    passed = report["started"] and report["completed"] and report["finite"]
    passed &= report["busy_jump_ignored"]
    if station_id in (2, 5):
        passed &= report["max_root_height"] > values[0, 0, 1] + 0.15
    elif station_id == 10:
        passed &= seated_frames >= 60 and stand_requested and report["min_root_height"] < 0.8
    else:
        passed &= min(head_heights) < head_heights[0] - 0.15
    report["passed"] = bool(passed)
    output = ROOT / "logs/gym"
    output.mkdir(parents=True, exist_ok=True)
    (output / f"{station_id}.poses.bin").write_bytes(values.tobytes())
    (output / f"{station_id}.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report), flush=True)
    return report


def main():
    runtime = GymRuntime()
    try:
        reports = [check_station(runtime, station_id) for station_id in (2, 5, 10, 12)]
    finally:
        runtime.close()
    output = ROOT / "logs/gym/check.json"
    output.write_text(json.dumps(reports, indent=2), encoding="utf-8")
    raise SystemExit(0 if all(report["passed"] for report in reports) else 1)


if __name__ == "__main__":
    main()
