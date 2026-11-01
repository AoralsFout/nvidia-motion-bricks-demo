"""Check recorded real-model / rendered soak evidence against the agreed targets."""
import csv
import json
import argparse
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--recording", type=Path, default=root / "logs")
args = parser.parse_args()
logs = args.recording if args.recording.is_absolute() else root / args.recording
soak = json.loads((logs / "soak.json").read_text(encoding="utf-8"))
rig = json.loads((logs / "rig_verification.json").read_text(encoding="utf-8"))
benchmark = json.loads((logs / "benchmark.json").read_text(encoding="utf-8"))
with (logs / "gpu.csv").open(encoding="utf-8", newline="") as file:
    memory = [int(row["gpu_memory_mib"]) for row in csv.DictReader(file)]
with (logs / "session.csv").open(encoding="utf-8", newline="") as file:
    live_rows = [row for row in csv.DictReader(file) if row["live"] == "true"]
if not live_rows or float(live_rows[-1]["seconds"]) < soak["wall_seconds"] - 1:
    raise SystemExit("session.csv does not match soak.json. Run a fresh soak, or use --recording logs/verified.")
engine_path = logs / "engine.log" if (logs / "engine.log").exists() else root / ".runtime/soak.log"
engine_log = engine_path.read_text(encoding="utf-8", errors="replace")
checks = {
    "77_original_joints_preserved": rig["bones"] == 77 and not rig["issues"],
    "real_model_finite": benchmark["finite"] and benchmark["generations"] > 2,
    "600_live_seconds": soak["live_seconds"] >= 600,
    "no_connection_gaps_over_500ms": soak.get("connection_gaps_over_500ms", -1) == 0,
    "average_render_fps_at_least_60": soak["average_fps"] >= 60,
    "p95_frame_ms_at_most_16_7": soak["p95_frame_ms"] <= 16.7,
    "at_least_20_control_changes_measured": soak["command_samples"] >= 20,
    "p95_command_plus_one_frame_under_200ms": soak["p95_command_to_pose_ms"] + soak["p95_frame_ms"] < 200,
    "no_godot_runtime_errors": "ERROR:" not in engine_log,
}
sampled_fps = [float(row["fps"]) for row in live_rows]
report = {"aggregate_targets_passed": all(checks.values()), "checks": checks, "soak": soak,
    "gpu_total_device_memory_mib": {"min": min(memory), "peak": max(memory),
        "note": "Includes desktop and other apps; not model-only VRAM"},
    "render_observations": {"live_sampled_fps_min": min(sampled_fps),
        "samples_below_60fps": sum(fps < 60 for fps in sampled_fps),
        "total_live_samples": len(sampled_fps),
        "continuous_60fps_demonstrated": min(sampled_fps) >= 60,
        "note": "Average/P95 targets do not imply an uninterrupted 60 FPS minimum. Raw hitches are retained."},
    "source_commit": "54fc563aeaaf819a753d72cc9fdc6713989cdd43",
    "device": "NVIDIA GeForce RTX 3050 Ti Laptop GPU, 4096 MiB",
    "precision": "SOMA FP16 / TensorRT 10.8.0.43 / batch 1"}
(logs / "validation.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
print(json.dumps(report, indent=2, ensure_ascii=False))
raise SystemExit(0 if report["aggregate_targets_passed"] else 1)
