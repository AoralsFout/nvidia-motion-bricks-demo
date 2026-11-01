"""Official SOMA runtime with local steering. MotionBricks owns root movement."""
import math
import time
import numpy as np
from paths import RUNTIME, UPSTREAM, initialize_warp
from locomotion_profile import WALK_SPEED, RUN_SPEED, load_forward_locomotion, needs_regeneration


class MotionRuntime:
    def __init__(self):
        self.wp = wp = initialize_warp()
        from motionbricks.io.utils import get_soma_human_model
        from motionbricks.io.bvh import load_bvh
        from motionbricks.model.soma.engine import MotionBricksSOMAEngine
        from motionbricks.model.soma.contract import SOMA_N1_FP16_ONNX_PATH
        from motionbricks.inference.builder import TensorRTBuildOptions
        from motionbricks.runtime.motion_player import GeneratedMotionPlayer
        from motionbricks.utils.space_conversion_utils import FacingDirectionType, SpaceConverter

        self.model = get_soma_human_model()
        self.skeleton = self.model.skeleton
        self.to_runtime = SpaceConverter(FacingDirectionType.MUJOCO).convert_transform(wp.transform_identity())
        self.from_runtime = wp.transform_inverse(self.to_runtime)
        self.engine = MotionBricksSOMAEngine(SOMA_N1_FP16_ONNX_PATH,
            model_to_runtime=self.to_runtime, cache_dir=RUNTIME / "trt-cache",
            build_options=TensorRTBuildOptions(workspace_size_bytes=256 * 1024**2,
                builder_optimization_level=1, enable_fp16=True))
        self.player = GeneratedMotionPlayer(self.engine, self.skeleton)
        self.targets = {}
        clips = {
            "idle": "locomotion/idle/idle_loop_001__A268.bvh",
        }
        with wp.ScopedStream(self.engine.stream):
            for mode, path in clips.items():
                clip = load_bvh(str(UPSTREAM / "assets/motions/soma" / path), self.skeleton)
                poses = wp.empty((4, self.skeleton.num_joints), dtype=wp.transform)
                for frame in range(4):
                    clip.sample(1.8 + frame / 30, poses[frame], root_offset=self.to_runtime,
                                stream=self.engine.stream)
                roots = poses.numpy()[:, 0]
                forward = wp.transform_vector(wp.transform(*roots[0]), wp.vec3(0, 1, 0))
                heading = math.atan2(forward[1], forward[0])
                origin = wp.transform(wp.vec3(float(roots[0, 0]), float(roots[0, 1]), 0),
                                      wp.quat_from_axis_angle(wp.vec3(0, 0, 1), heading))
                offset = wp.mul(wp.transform_inverse(origin), self.to_runtime)
                for frame in range(4):
                    clip.sample(1.8 + frame / 30, poses[frame], root_offset=offset, stream=self.engine.stream)
                self.targets[mode] = poses
            self.current = wp.clone(self.targets["idle"][0])
            # Start facing Godot -Z (runtime +Y).
            initial = self.current.numpy()
            initial[0] = np.array(wp.mul(wp.transform(wp.vec3(0, 0, 0),
                wp.quat_from_axis_angle(wp.vec3(0, 0, 1), math.pi/2)), wp.transform(*initial[0])))
            self.current.assign(initial)
            self.player.seed_history_from_pose(self.current)
            self.initial_pose = wp.clone(self.current)
        self.target = wp.empty_like(self.targets["idle"])
        with wp.ScopedStream(self.engine.stream):
            self.locomotion = load_forward_locomotion(self.skeleton, self.to_runtime)
        from app.runtime.common.motion import MovementControl
        from app.runtime.soma.target_pose_blender import SOMATargetPoseBlender
        self.movement = MovementControl(np.array([0, 1, 0], dtype=np.float32))
        self.target_pose_blender = SOMATargetPoseBlender(self.skeleton.reference_local_transforms)
        self.blended_poses = wp.empty_like(self.target)
        self.character_ground_position = np.zeros(3, dtype=np.float32)
        self.actual_velocity = np.zeros(3, dtype=np.float32)
        self.generation_velocity = np.zeros(3, dtype=np.float32)
        self.has_target = False
        self.contacts = wp.zeros(4, dtype=wp.float32)
        self.direction = np.array([0, 1, 0], dtype=np.float32)
        self.mode = "idle"
        self.generations = 0
        self.gpu_ms = self.wall_ms = 0.0
        self.ack = 0
        self.relaxed = self.model.override_poses.get("RelaxedHands")
        self.fingers = [i for i, name in enumerate(self.skeleton.joint_names)
                        if name.startswith(("LeftHandThumb", "RightHandThumb", "LeftHandIndex", "RightHandIndex",
                                            "LeftHandMiddle", "RightHandMiddle", "LeftHandRing", "RightHandRing",
                                            "LeftHandPinky", "RightHandPinky"))]
        self.relaxed_numpy = self.relaxed.numpy() if self.relaxed is not None else None

    def reset(self):
        wp = self.wp
        with wp.ScopedStream(self.engine.stream):
            wp.copy(self.current, self.initial_pose)
            self.player.seed_history_from_pose(self.current)
        self.player.output.num_frames = 0
        self.player.playback_time = 0
        self.mode = "idle"
        self.ack = 0
        self.has_target = False
        from app.runtime.common.motion import MovementControl
        self.direction[:] = [0, 1, 0]
        self.movement = MovementControl(self.direction.copy())
        self.generation_velocity.fill(0)
        self.actual_velocity.fill(0)
        self.character_ground_position.fill(0)

    def step(self, dt, direction, speed, sequence):
        wp = self.wp
        from motionbricks.runtime.target_pose import place_target_poses, TargetPoseInferenceParams
        from app.runtime.common.motion import LocomotionCommand
        direction = np.asarray(direction, dtype=np.float32)
        length = np.linalg.norm(direction)
        if length > 0.01:
            self.direction = direction / length
        moving = speed >= 0.1
        mode = "idle" if not moving else ("run" if speed > WALK_SPEED else "walk")
        profile = self.locomotion.definition
        base_speed = RUN_SPEED if mode == "run" else WALK_SPEED
        command = LocomotionCommand(facing_direction=self.direction,
            movement=self.direction * min(speed / base_speed, 1.0) if moving else None,
            use_max_speed=mode == "run")
        self.movement.update(command, profile, dt)
        starting = moving and self.mode == "idle"
        stopping = not moving and self.mode != "idle"
        if starting:
            # Scene Preview realigns the spring to the actually played velocity on entry.
            self.movement.realign(self.actual_velocity, profile)
        previous_position = self.current.numpy()[0, :3].copy()
        self.character_ground_position[:] = previous_position
        self.character_ground_position[2] = 0
        renew = moving and self.player.time_to_transition <= dt
        regenerate = moving and needs_regeneration(self.movement, self.generation_velocity, profile)
        with wp.ScopedStream(self.engine.stream):
            if starting or stopping or renew or regenerate:
                if moving:
                    # Official blend space, authored sample phases, constrained hips,
                    # 0.97 velocity scale and one second of target lookahead.
                    self.target_pose_blender.evaluate(self, self.locomotion, self.blended_poses, self.target)
                else:
                    position = self.character_ground_position + self.direction * float(np.linalg.norm(self.actual_velocity)) * 0.15
                    place_target_poses(wp.vec3(*position), wp.vec3(*self.direction), self.targets["idle"],
                                       self.target, stream=self.engine.stream)
                    self.movement.reset_desired_velocity()
                start = time.perf_counter()
                self.player.generate(self.target, TargetPoseInferenceParams(
                    transition_early_by_frames=profile.transition_early_by_frames if moving else 0,
                    num_poses_to_use=4, allowed_token_counts=profile.allowed_token_counts))
                self.wall_ms = (time.perf_counter() - start) * 1000
                self.gpu_ms = float(self.engine.timer.milliseconds.get("inference", 0))
                self.generations += 1
                self.has_target = True
                self.ack = sequence
                self.generation_velocity[:] = self.movement.desired_velocity
            if self.player.output.num_frames:
                self.player.sample(dt, self.current, self.contacts)
            self.player.record_pose(dt, self.current)
            self.engine.synchronize()
        result = self.current.numpy()
        self.actual_velocity[:] = (result[0, :3] - previous_position) / dt
        self.actual_velocity[2] = 0
        self.mode = mode
        # Only the root is in Z-up runtime space. Child joints remain source-local.
        result[0] = np.array(wp.mul(self.from_runtime, wp.transform(*result[0])))
        if self.relaxed_numpy is not None:
            result[self.fingers] = self.relaxed_numpy[self.fingers]
        if not np.isfinite(result).all():
            raise RuntimeError("Generated pose contains non-finite values")
        return result.astype("<f4", copy=False)

    def debug_target_poses(self):
        """The actual four conditioning poses, with only the root restored to Y-up."""
        if not self.has_target:
            return np.empty((0, self.skeleton.num_joints, 7), dtype="<f4")
        wp = self.wp
        with wp.ScopedStream(self.engine.stream):
            result = self.target.numpy()
        for pose in result:
            pose[0] = np.array(wp.mul(self.from_runtime, wp.transform(*pose[0])))
        if not np.isfinite(result).all():
            raise RuntimeError("Target pose contains non-finite values")
        return result.astype("<f4", copy=False)

    def close(self):
        self.engine.close()
