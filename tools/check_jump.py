"""Check generated free jumps, airborne feet, landing, input recovery and gating."""
import json
from pathlib import Path
import sys
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bridge"))
from gym_runtime import GymRuntime


def check(runtime, speed, direction):
    runtime.reset()
    direction = np.asarray(direction, dtype=np.float32)
    for frame in range(100 if speed else 10):
        runtime.step(1/60, direction, speed, frame, auto_interact=False)
    initial = runtime.step(1/60, direction, speed, 101, jump=True, auto_interact=False)
    before = runtime.jump_completed
    started = runtime.jump_started
    parents = runtime.skeleton.parent_indices.numpy()
    chains = []
    for name in ("LeftFoot", "LeftToeBase", "RightFoot", "RightToeBase"):
        chain, index = [], runtime.skeleton.joint_index(name)
        if index < 0:
            raise ValueError(f"Missing foot joint {name}")
        while index >= 0:
            chain.append(index)
            index = parents[index]
        chains.append(chain[::-1])
    frames, clearances = [initial], []
    completed_frame = None
    for frame in range(420):
        # Repeated presses during the action must not cause a second jump.
        pose = runtime.step(1/60, direction, speed, 102+frame,
            jump=frame in (10, 20, 30), auto_interact=False)
        frames.append(pose)
        heights = []
        for chain in chains:
            transform = runtime.wp.transform_identity()
            for index in chain:
                transform = runtime.wp.mul(transform, runtime.wp.transform(*pose[index]))
            heights.append(float(transform.p[1]))
        clearances.append(min(heights))
        if runtime.jump_completed > before and completed_frame is None:
            completed_frame = frame
        if completed_frame is not None and frame - completed_frame >= 60:
            break
    values = np.stack(frames)
    displacement = values[-1, 0, [0, 2]] - initial[0, [0, 2]]
    grounded = abs(float(values[-1, 0, 1] - initial[0, 1])) < 0.2
    passed = (completed_frame is not None and runtime.jump_started == started
        and np.isfinite(values).all() and max(clearances) > 0.1 and grounded)
    if speed == 0:
        passed &= float(np.linalg.norm(displacement)) < 0.6
    else:
        # Input is still held: after landing the official state must locomote.
        passed &= runtime.character.state_machine.is_locomoting
    report = {"speed": speed, "direction": direction.tolist(), "passed": bool(passed),
        "action_seconds": (completed_frame + 1)/60 if completed_frame is not None else None,
        "peak_root": float(values[:, 0, 1].max()),
        "max_foot_clearance": max(clearances), "airborne_frames": sum(h > 0.1 for h in clearances),
        "displacement": displacement.tolist(), "final_root_height": float(values[-1, 0, 1]),
        "duplicate_presses_ignored": runtime.jump_started == started,
        "final_state": runtime.character.state_machine.state.name}
    label = "idle" if not speed else ("walk" if speed < 3 else "run")
    output = ROOT / "logs/jump"
    output.mkdir(parents=True, exist_ok=True)
    (output / f"{label}.poses.bin").write_bytes(values.astype("<f4").tobytes())
    print(json.dumps(report), flush=True)
    return report


def main():
    runtime = GymRuntime()
    try:
        reports = [check(runtime, speed, direction) for speed, direction in
            ((0.0, [1, 0, 0]), (2.3, [0, 1, 0]), (4.5, [-1, 0, 0]))]
    finally:
        runtime.close()
    (ROOT / "logs/jump/check.json").write_text(json.dumps(reports, indent=2), encoding="utf-8")
    raise SystemExit(0 if all(r["passed"] for r in reports) else 1)


if __name__ == "__main__":
    main()
