# Parameter values adapted from NVIDIA MotionBricks app/runtime/soma/presets.py.
# Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. SPDX-License-Identifier: Apache-2.0
"""The official forward locomotion profile, without importing its viewer stack."""
from paths import UPSTREAM

WALK_SPEED = 2.3
RUN_SPEED = 4.5


def needs_regeneration(movement, previous_velocity, mode):
    """Same speed/direction thresholds as official LocomotionState._needs_regeneration."""
    import numpy as np
    settings = movement.settings
    previous_speed = float(np.linalg.norm(previous_velocity))
    if movement.desired_speed > 0 and previous_speed <= 1e-6:
        return True
    delta = movement.desired_speed - previous_speed
    remaining = mode.max_speed - previous_speed if delta > 0 else previous_speed
    threshold = max(remaining * settings.speed_regeneration_fraction,
                    mode.max_speed * settings.minimum_speed_regeneration_fraction)
    if abs(delta) > threshold:
        return True
    return previous_speed > 1e-6 and float(movement.desired_velocity_direction @
        (previous_velocity / previous_speed)) < settings.direction_regeneration_dot


def load_forward_locomotion(skeleton, model_to_runtime):
    from motionbricks.model.contract import ModelRig
    from motionbricks.runtime.blend_spaces import BlendSpaceType
    from app.runtime.common.clip_registry import ClipRegistry
    from app.runtime.common.io.smart_primitive_document import SmartPrimitiveAssetPool
    from app.runtime.common.motion import LocomotionMode, load_locomotion_mode

    # Keep these aligned with LINEAR_LOCOMOTION in the pinned upstream preset.
    # Loading its Smart Primitive also preserves clip time, authored root heading
    # and hips_constrained; selecting four arbitrary clip frames does not.
    mode = LocomotionMode(
        name="linear_1d",
        smart_primitive_path=UPSTREAM / "assets/smart_primitives/soma/locomotion_bs1_linear.smart_primitive.json",
        blend_space_type=BlendSpaceType.LINEAR_1D,
        target_values=(("Idle", (0.0, 0.0)), ("Walk", (WALK_SPEED/RUN_SPEED, 0.0)),
                      ("Jog", (3.0/RUN_SPEED, 0.0)), ("Run", (1.0, 0.0))),
        max_speed=RUN_SPEED, default_speed=WALK_SPEED, minimum_speed=0.8*WALK_SPEED,
        velocity_scale=0.97, position_scale=1.0, transition_early_by_frames=10,
        allowed_token_counts=tuple(range(8, 15)), label="Forward",
    )
    registry = ClipRegistry(ModelRig.SOMA, skeleton=skeleton)
    pool = SmartPrimitiveAssetPool(registry, skeleton.reference_local_transforms, model_to_runtime)
    return load_locomotion_mode(mode, pool)
