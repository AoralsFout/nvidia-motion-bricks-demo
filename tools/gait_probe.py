"""Fixed-input real-model gait capture; compare leg excursion and actual travel."""
import argparse
import csv
import json
from pathlib import Path
import sys
import time
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bridge"))
from runtime import MotionRuntime
from locomotion_profile import WALK_SPEED


def measure(runtime, seconds, speed):
    wp = runtime.wp
    parents = runtime.skeleton.parent_indices.numpy()
    feet = [runtime.skeleton.joint_index(name) for name in ("LeftFoot", "RightFoot")]
    frames, poses = [], []
    for frame in range(round(seconds * 60)):
        pose = runtime.step(1/60, [0, 1, 0], speed, 1)
        poses.append(pose.copy())
        cache = {}

        def world(index):
            if index not in cache:
                local = wp.transform(*pose[index])
                parent = parents[index]
                cache[index] = wp.mul(world(parent), local) if parent >= 0 else local
            return cache[index]

        positions = [np.array(world(index))[:3] for index in feet]
        root = pose[0, :3]
        frames.append([frame/60, *root.tolist(), *positions[0].tolist(), *positions[1].tolist()])
    values = np.asarray(frames)
    steady = values[values[:, 0] >= 3]
    # Forward is Godot -Z. This measures actual spatial separation of the feet,
    # independent of how motion tokens or target frames are configured.
    separation = steady[:, 6] - steady[:, 9]
    travel = -(steady[-1, 3] - steady[0, 3])
    report = {
        "requested_speed_m_s": speed,
        "actual_speed_m_s": float(travel / (steady[-1, 0] - steady[0, 0])),
        "p95_fore_aft_foot_separation_m": float(np.percentile(abs(separation), 95)),
        "peak_fore_aft_foot_separation_m": float(np.max(abs(separation))),
        "left_foot_root_relative_range_m": float(np.ptp(steady[:, 6] - steady[:, 3])),
        "right_foot_root_relative_range_m": float(np.ptp(steady[:, 9] - steady[:, 3])),
        "generations": runtime.generations,
        "frames": len(frames),
        "finite": bool(np.isfinite(values).all()),
    }
    runtime.reset()
    runtime.step(1/60, [0, 1, 0], 0, 2)
    report["reset_clears_locomotion"] = bool(
        np.allclose(runtime.movement.desired_velocity, 0)
        and np.allclose(runtime.actual_velocity, 0)
        and np.allclose(runtime.generation_velocity, 0)
        and not runtime.has_target)
    return report, frames, np.stack(poses).astype("<f4")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", default="current")
    parser.add_argument("--speed", type=float, default=WALK_SPEED)
    parser.add_argument("--seconds", type=float, default=10)
    parser.add_argument("--min-step", type=float, default=0.6)
    args = parser.parse_args()
    output = ROOT / "logs/gait"
    output.mkdir(parents=True, exist_ok=True)
    runtime = MotionRuntime()
    try:
        report, frames, poses = measure(runtime, args.seconds, args.speed)
    finally:
        runtime.close()
    (output / f"{args.label}.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    (output / f"{args.label}.poses.bin").write_bytes(poses.tobytes())
    with (output / f"{args.label}.csv").open("w", newline="") as file:
        writer = csv.writer(file)
        writer.writerow(["time", "root_x", "root_y", "root_z", "left_x", "left_y", "left_z", "right_x", "right_y", "right_z"])
        writer.writerows(frames)
    print(json.dumps(report, indent=2), flush=True)
    passed = report["finite"] and report["reset_clears_locomotion"] and report["p95_fore_aft_foot_separation_m"] >= args.min_step
    print("GAIT_PASS" if passed else "GAIT_SHORT_STEPS", flush=True)
    raise SystemExit(0 if passed else 1)


if __name__ == "__main__":
    main()
