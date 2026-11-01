"""Player-triggered ground jump, adapted from the official SOMA low jump targets.

MotionBricks generates the whole action. This changes input targets only; it
does not add a ballistic offset or play a jump clip on the rendered character.
"""
import math
import numpy as np

from paths import UPSTREAM
from app.runtime.common.smart_primitive_behaviors import SmartPrimitiveBehavior
from motionbricks.runtime.target_pose import TargetPoseInferenceParams

JUMP_ASSET = UPSTREAM / "assets/smart_primitives/soma/jump_0_5m.smart_primitive.json"


class FreeJumpBehavior(SmartPrimitiveBehavior):
    def configure_jump(self, character, direction, speed):
        self.start_pose = character.current_pose.numpy().copy()
        self.direction = np.asarray(direction, dtype=np.float32).copy()
        self.direction[2] = 0
        self.direction /= max(float(np.linalg.norm(self.direction)), 1e-6)
        self.distance = min(max(float(speed), 0.0) * 0.75, 3.2)

    def get_targets(self, character_properties, output_target_poses, stream=None):
        import warp as wp
        # The slower official variation has entry, airborne, and exit targets.
        # Free jumping goes directly toward the airborne target, then landing.
        index = min(range(self.sequence_count), key=self.sequence_start_speed)
        params = self.get_world_target_poses_for_sequence(index, output_target_poses, stream)
        authored = output_target_poses.numpy()
        entry = authored[0, 0, :2].copy()
        end = authored[8, 0, :2].copy()
        travel = end - entry
        length = float(np.linalg.norm(travel))
        source_direction = travel / length
        heading = math.atan2(self.direction[1], self.direction[0]) - math.atan2(source_direction[1], source_direction[0])
        rotation = wp.quat_from_axis_angle(wp.vec3(0, 0, 1), heading)
        targets = authored[4:12].copy()
        ground = np.asarray(character_properties.position, dtype=np.float32)
        for frame in range(8):
            root = targets[frame, 0]
            progress = float(np.dot(root[:2] - entry, source_direction) / length)
            root[:2] = ground[:2] + self.direction[:2] * (progress * self.distance)
            root[2] += ground[2]
            root[3:] = np.array(wp.mul(rotation, wp.quat(*root[3:])))
        if self.distance < 0.05:
            # Recover to the actual standing pose, rather than a running stride.
            targets[4:8] = self.start_pose
        output_target_poses[:8].assign(targets)
        # Retain the authored target counts and early transitions, with a bounded
        # duration suitable for an immediate button-triggered action.
        return tuple(TargetPoseInferenceParams(p.transition_early_by_frames,
            p.num_poses_to_use, p.ik_pin_mask, allowed_token_counts=(6, 7, 8)) for p in params[1:3])
