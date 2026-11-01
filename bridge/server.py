"""Loopback-only UDP bridge: control JSON in, binary local bone transforms out.

Pose header <4sIdffII: MBP1, acknowledged command, server time, inference ms,
generation wall ms, generation count, joint count; then joint_count * 7 floats.
Opt-in target header <4sIII: MBT1, generation, joint count, pose count;
then pose_count * joint_count * 7 floats. Zero poses clears reset targets.
Gym status: MBS1 followed by JSON state, interaction boxes and station entries.
Interaction/station controls use repeated event serials to survive UDP loss.
"""
import argparse
import json
import logging
import math
import os
import socket
import struct
import subprocess
import threading
import time
import traceback
from paths import ROOT
from locomotion_profile import WALK_SPEED, RUN_SPEED

HEADER = struct.Struct("<4sIdffII")
TARGET_HEADER = struct.Struct("<4sIII")  # MBT1, generation, joints, target frames


def monitor_gpu(stop, output):
    """Total GPU usage includes the desktop and other apps, not just this model."""
    import csv
    with output.open("w", newline="", encoding="utf-8") as file:
        writer = csv.writer(file)
        writer.writerow(["unix_seconds", "gpu_memory_mib", "gpu_total_mib", "gpu_utilization_percent"])
        while not stop.is_set():
            try:
                result = subprocess.run(["nvidia-smi", "--query-gpu=memory.used,memory.total,utilization.gpu",
                    "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=4,
                    creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
                if result.returncode == 0:
                    values = result.stdout.strip().splitlines()[0].split(",")
                    writer.writerow([time.time(), *[value.strip() for value in values]])
                    file.flush()
            except (OSError, subprocess.TimeoutExpired, IndexError):
                logging.warning("GPU telemetry unavailable")
                return
            stop.wait(2)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=27841)
    parser.add_argument("--benchmark", action="store_true")
    parser.add_argument("--flat", action="store_true")
    args = parser.parse_args()
    logs = ROOT / "logs"
    logs.mkdir(exist_ok=True)
    (logs / ".gdignore").touch()
    logging.basicConfig(filename=logs / "bridge.log", level=logging.INFO, force=True,
                        format="%(asctime)s %(levelname)s %(message)s")
    status = logs / "bridge_status.json"
    status.write_text(json.dumps({"state": "building", "message": "Loading MotionBricks / building TensorRT cache"}))
    runtime = None
    stop_monitor = threading.Event()
    threading.Thread(target=monitor_gpu, args=(stop_monitor, logs / "gpu.csv"), daemon=True).start()
    try:
        if args.flat or args.benchmark:
            from runtime import MotionRuntime
        else:
            from gym_runtime import GymRuntime as MotionRuntime
        started = time.perf_counter()
        runtime = MotionRuntime()
        setup_seconds = time.perf_counter() - started
        # Warm all Warp kernels and CUDA graph before reporting ready.
        runtime.step(1/60, [0, 1, 0], WALK_SPEED, 1)
        runtime.step(1/60, [0, 1, 0], 0, 2)
        runtime.reset()
        status.write_text(json.dumps({"state": "ready", "setup_seconds": setup_seconds}))
        if args.benchmark:
            import numpy as np
            samples, roots = [], []
            for frame in range(360):
                speed = 0 if frame < 30 or frame >= 270 else (WALK_SPEED if frame < 150 else RUN_SPEED)
                angle = 0 if frame < 210 else 1.57
                pose = runtime.step(1/60, [np.sin(angle), np.cos(angle), 0], speed, frame)
                roots.append(pose[0, :3].tolist())
                if frame == 0 or runtime.generations != last_generation:
                    samples.append({"wall_ms": runtime.wall_ms, "inference_ms": runtime.gpu_ms})
                last_generation = runtime.generations
            report = {"setup_seconds": setup_seconds, "generation_samples": samples,
                      "generations": runtime.generations, "start_root": roots[0], "end_root": roots[-1],
                      "finite": bool(np.isfinite(roots).all()), "frames": len(roots)}
            (logs / "benchmark.json").write_text(json.dumps(report, indent=2))
            print(json.dumps(report), flush=True)
            return
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as connection:
            connection.bind(("127.0.0.1", args.port))
            connection.setblocking(False)
            peer, command, last_input = None, {"direction": [0, 0, -1], "speed": 0, "seq": 0}, time.perf_counter()
            last_tick = time.perf_counter()
            debug_requested = False
            target_key, target_packet, next_target_send = None, b"", 0.0
            last_interact = last_station = 0
            pending_interact = False
            last_jump = 0
            pending_jump = False
            pending_station = None
            auto_interact, debug_scene, next_status_send = True, True, 0.0
            logging.info("Bridge ready on 127.0.0.1:%s", args.port)
            while True:
                tick = time.perf_counter()
                dt = min(max(tick - last_tick, 1/240), 0.1)
                last_tick = tick
                while True:
                    try:
                        packet, address = connection.recvfrom(2048)
                    except BlockingIOError:
                        break
                    try:
                        incoming = json.loads(packet)
                        values = incoming["direction"]
                        if len(values) != 3 or not all(math.isfinite(float(v)) for v in values):
                            continue
                        if incoming.get("quit"):
                            return
                        if not args.flat and "scene_layout" in incoming:
                            try:
                                runtime.configure_scene(incoming["scene_layout"])
                            except (KeyError, TypeError, ValueError) as error:
                                raise RuntimeError(f"Invalid Godot editor scene layout: {error}") from error
                        if incoming.get("reset"):
                            runtime.reset()
                        if not args.flat:
                            jump_sequence = int(incoming.get("jump_seq", 0))
                            if jump_sequence != last_jump:
                                pending_jump = True
                                last_jump = jump_sequence
                            interact_sequence = int(incoming.get("interact_seq", 0))
                            if interact_sequence != last_interact:
                                pending_interact = True
                                last_interact = interact_sequence
                            station_sequence = int(incoming.get("station_seq", 0))
                            if station_sequence != last_station:
                                pending_station = int(incoming.get("station_id", 0))
                                last_station = station_sequence
                            auto_interact = bool(incoming.get("auto_interact", True))
                            debug_scene = bool(incoming.get("debug_scene", True))
                        requested_speed = float(incoming["speed"])
                        if not math.isfinite(requested_speed):
                            continue
                        incoming_debug = bool(incoming.get("debug_targets", False))
                        if incoming_debug and (not debug_requested or address != peer):
                            next_target_send = 0.0
                        debug_requested = incoming_debug
                        command = {"direction": values, "speed": min(max(requested_speed, 0), RUN_SPEED),
                                   "seq": int(incoming["seq"]) & 0xffffffff}
                        peer, last_input = address, tick
                    except (KeyError, TypeError, ValueError, OverflowError):
                        continue
                speed = command["speed"] if tick - last_input < 0.5 else 0
                x, _, z = command["direction"]
                if args.flat:
                    pose = runtime.step(dt, [x, -z, 0], speed, command["seq"])
                else:
                    if pending_station is not None:
                        runtime.select_station(pending_station)
                        pending_station = None
                    pose = runtime.step(dt, [x, -z, 0], speed, command["seq"],
                        interact=pending_interact, jump=pending_jump, auto_interact=auto_interact)
                    pending_interact = False
                    pending_jump = False
                if peer is not None:
                    connection.sendto(HEADER.pack(b"MBP1", runtime.ack, time.perf_counter(),
                        runtime.gpu_ms, runtime.wall_ms, runtime.generations, len(pose)) + pose.tobytes(), peer)
                    if not args.flat and tick >= next_status_send:
                        snapshot = json.dumps(runtime.scene_status(debug_scene), separators=(",", ":")).encode("utf-8")
                        connection.sendto(b"MBS1" + snapshot, peer)
                        next_status_send = tick + 0.1
                    if debug_requested:
                        current_key = (runtime.generations, runtime.has_target)
                        if current_key != target_key:
                            targets = runtime.debug_target_poses()
                            target_packet = TARGET_HEADER.pack(b"MBT1", runtime.generations,
                                len(pose), len(targets)) + targets.tobytes()
                            target_key = current_key
                            next_target_send = 0.0
                        # Retransmit cached snapshots to recover lost UDP packets.
                        if tick >= next_target_send:
                            connection.sendto(target_packet, peer)
                            next_target_send = tick + 0.5
                elapsed = time.perf_counter() - tick
                time.sleep(max(0, 1/60 - elapsed))
    except Exception as error:
        logging.error("Bridge failed\n%s", traceback.format_exc())
        status.write_text(json.dumps({"state": "error", "message": str(error)}))
        raise
    finally:
        stop_monitor.set()
        if runtime is not None:
            runtime.close()


if __name__ == "__main__":
    main()
