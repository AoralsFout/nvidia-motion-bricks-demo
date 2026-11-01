"""Official SOMACharacter + authored Smart Primitive behaviors, without a viewer.

Interaction probing and once-per-approach dispatch follow app/scene_preview.py.
The original flat runtime remains available for isolated gait checks.
"""
import gc
import math
import time
import numpy as np
from runtime import MotionRuntime
from locomotion_profile import WALK_SPEED
from gym_scene import load_definition, godot_transform, godot_vector


class GymRuntime(MotionRuntime):
    def __init__(self):
        super().__init__()
        from motionbricks.model.contract import ModelRig
        from app.runtime.common.clip_registry import ClipRegistry
        from app.runtime.common.io.smart_primitive_document import SmartPrimitiveAssetPool
        from app.runtime.common.smart_primitive_behaviors import behavior_types
        self.definition = load_definition()
        self.start_transform = self.definition.character_start.transform
        self.station_overrides = {}
        self.layout_revision = ""
        self.asset_pool = SmartPrimitiveAssetPool(ClipRegistry(ModelRig.SOMA, skeleton=self.skeleton),
            self.skeleton.reference_local_transforms, self.to_runtime)
        self.behavior_types = behavior_types()
        self.generation_offset = 0
        self.teleport_serial = 0
        self.started = []
        self.completed = []
        self.entries = {}
        self.jump_started = self.jump_completed = 0
        self.character = None
        self.reset()

    def _new_character(self, transform):
        wp = self.wp
        from app.runtime.soma.character import SOMACharacter
        from app.runtime.soma.presets import LINEAR_LOCOMOTION, DIRECTIONAL_LOCOMOTION, CROUCH_LOCOMOTION

        class TrackedCharacter(SOMACharacter):
            """Observe official generation calls; do not replace their motion logic."""
            def __init__(self, *args, **kwargs):
                self.generation_count = 0
                self.command_sequence = self.generation_ack = 0
                self.generation_ms = self.inference_ms = 0.0
                self.target_count = 0
                super().__init__(*args, **kwargs)

            def generate_to_target_poses(self, poses, settings, *args, **kwargs):
                start = time.perf_counter()
                super().generate_to_target_poses(poses, settings, *args, **kwargs)
                self.generation_ms = (time.perf_counter() - start) * 1000
                self.inference_ms = float(self.engine.timer.milliseconds["inference"])
                self.generation_count += 1
                self.generation_ack = self.command_sequence
                self.target_count = settings.num_poses_to_use

        with wp.ScopedStream(self.engine.stream):
            return TrackedCharacter(self.engine, asset_pool=self.asset_pool, initial_transform=transform,
                modes=(LINEAR_LOCOMOTION, DIRECTIONAL_LOCOMOTION, CROUCH_LOCOMOTION))

    def reset(self, transform=None):
        wp = self.wp
        self.selected_station = 0
        if self.character is not None:
            self.generation_offset += self.character.generation_count
            if self.character.state_machine.is_interacting:
                self.character.state_machine.interaction_state.primitive.unbind()
        self.character = self._new_character(self.start_transform if transform is None else transform)
        self.instances = []
        offset = 0
        with wp.ScopedStream(self.engine.stream):
            for definition in self.definition.smart_primitives:
                override = self.station_overrides.get(definition.id, {})
                if not override.get("enabled", True):
                    continue
                placement = override.get("transform", definition.transform)
                behavior = self.asset_pool.instantiate(definition.reference, self.behavior_types[definition.behavior])
                behavior.set_node_world_transform(0, placement, stream=self.engine.stream)
                self.character.state_machine.interaction_state.prepare(self.character, behavior)
                self.instances.append({"definition": definition, "transform": placement, "behavior": behavior, "offset": offset,
                    "count": behavior.interaction_box_count, "overlap": False})
                offset += behavior.interaction_box_count
            from motionbricks.runtime.smart_primitive import InteractionBox
            self.boxes = wp.empty(max(offset, 1), dtype=InteractionBox)
            self.overlaps = wp.empty(max(offset, 1), dtype=wp.int32)
            self.box_count = offset
            self._refresh_boxes()
            if not self.entries:
                self._find_entries()
            from free_jump import FreeJumpBehavior, JUMP_ASSET
            self.free_jump = self.asset_pool.instantiate(JUMP_ASSET, FreeJumpBehavior)
        self.active = self.nearest = None
        self.jumping = False
        self.jump_cooldown = 0.0
        self.blocked = set()
        self.teleport_serial += 1
        self._sync()
        gc.collect()

    def _refresh_boxes(self):
        for item in self.instances:
            start = item["offset"]
            item["behavior"].get_world_interaction_boxes(self.boxes[start:start + item["count"]], stream=self.engine.stream)

    def _find_entries(self):
        """Entry shortcuts start before the authored sequence, outside its probe range."""
        wp = self.wp
        for item in self.instances:
            behavior, definition = item["behavior"], item["definition"]
            output = wp.empty((max(1, behavior.max_sequence_length) * 4, self.skeleton.num_joints), dtype=wp.transform)
            params = behavior.get_world_target_poses_for_sequence(0, output, stream=self.engine.stream)
            roots = output.numpy()[:, 0]
            first = roots[0, :3].copy()
            center = np.array(item["transform"].p, dtype=np.float32)
            direction = center - first
            direction[2] = 0
            if np.linalg.norm(direction) < 0.2:
                direction = roots[(len(params) - 1) * 4, :3] - first
                direction[2] = 0
            if np.linalg.norm(direction) < 0.1:
                direction = np.array(wp.transform_vector(wp.transform(*roots[0]), wp.vec3(0, 1, 0)))
                direction[2] = 0
            direction /= np.linalg.norm(direction)
            position = first - direction * 2.5
            position[2] = 0
            rotation = wp.quat_from_axis_angle(wp.vec3(0, 0, 1), math.atan2(direction[1], direction[0]))
            self.entries[definition.id] = (wp.transform(wp.vec3(*position), rotation), direction.copy())

    def select_station(self, station_id):
        if station_id not in self.entries:
            return
        self.reset(self.entries[station_id][0])
        self.selected_station = station_id

    def configure_scene(self, layout):
        """Apply a complete editor scene once; later packets acknowledge its hash."""
        if layout.get("revision", "") == self.layout_revision:
            return False
        from scene_layout import parse_layout
        ids = {definition.id for definition in self.definition.smart_primitives}
        revision, start, overrides = parse_layout(self.wp, layout, ids)
        self.layout_revision = revision
        self.start_transform = start
        self.station_overrides = overrides
        self.entries = {}
        self.reset()
        return True

    def _sync(self):
        character = self.character
        self.current = character.current_pose
        self.player = character.player
        self.movement = character.movement
        self.actual_velocity = character.actual_velocity
        self.character_ground_position = character.character_ground_position
        self.generations = self.generation_offset + character.generation_count
        self.gpu_ms, self.wall_ms = character.inference_ms, character.generation_ms
        self.ack = character.generation_ack
        self.has_target = character.target_count > 0
        self.target = character.player.target.poses

    def _dispatch(self, pressed, auto_interact, jump=False, jump_direction=None, jump_speed=0.0):
        from motionbricks.runtime.smart_primitive import compute_interaction_box_overlaps
        character = self.character
        machine = character.state_machine
        self._refresh_boxes()
        compute_interaction_box_overlaps(self.boxes[:self.box_count], character.probe_box,
            self.overlaps[:self.box_count], stream=self.engine.stream)
        overlaps = self.overlaps.numpy()
        for item in self.instances:
            start = item["offset"]
            item["overlap"] = bool(np.any(overlaps[start:start + item["count"]]))
            if not item["overlap"]:
                self.blocked.discard(item["definition"].id)
        if self.active is not None and not machine.is_interacting:
            finished = self.active["definition"].id
            self.blocked.add(finished)
            self.completed.append(finished)
            self.active = None
        if self.jumping and not machine.is_interacting:
            self.jumping = False
            self.jump_completed += 1
            self.jump_cooldown = 0.2
        candidates = [item for item in self.instances if item["overlap"]]
        self.nearest = min(candidates, key=lambda item: np.linalg.norm(
            np.array(item["transform"].p) - character.character_ground_position), default=None)
        if jump and not machine.is_interacting and self.jump_cooldown <= 0:
            facing = jump_direction if jump_speed > 0.1 else character.movement.current_facing
            self.free_jump.configure_jump(character, facing, jump_speed)
            machine.start_interaction(character, self.free_jump)
            self.jumping = True
            self.jump_started += 1
            self.blocked.update(item["definition"].id for item in candidates)
        elif machine.is_interacting:
            if pressed:
                machine.interact()
        elif self.nearest is not None and (pressed or (
                auto_interact and self.jump_cooldown <= 0 and self.nearest["definition"].id not in self.blocked)):
            machine.start_interaction(character, self.nearest["behavior"])
            self.active = self.nearest
            self.started.append(self.active["definition"].id)

    def step(self, dt, direction, speed, sequence, *, interact=False, jump=False, auto_interact=True, requested_mode=None):
        wp = self.wp
        from app.runtime.common.motion import LocomotionCommand
        direction = np.asarray(direction, dtype=np.float32)
        length = np.linalg.norm(direction)
        if length > 0.01:
            direction /= length
        mode = self.character.state_machine.active_locomotion_state.active_mode
        base_speed = mode.max_speed if speed > WALK_SPEED else mode.default_speed
        command = LocomotionCommand(facing_direction=direction,
            movement=direction * min(speed/base_speed, 1.0) if speed > 0.1 else None,
            use_max_speed=speed > WALK_SPEED, requested_mode=requested_mode)
        with wp.ScopedStream(self.engine.stream):
            self.jump_cooldown = max(0.0, self.jump_cooldown - dt)
            self.character.command_sequence = sequence
            self.character.step(dt, command)
            self._dispatch(interact, auto_interact, jump, direction, speed)
            self.engine.synchronize()
        self._sync()
        result = self.current.numpy()
        result[0] = np.array(wp.mul(self.from_runtime, wp.transform(*result[0])))
        if self.relaxed_numpy is not None:
            result[self.fingers] = self.relaxed_numpy[self.fingers]
        if not np.isfinite(result).all():
            raise RuntimeError("Official Gym generated non-finite poses")
        return result.astype("<f4", copy=False)

    def debug_target_poses(self):
        if not self.has_target:
            return np.empty((0, self.skeleton.num_joints, 7), dtype="<f4")
        result = super().debug_target_poses()
        return result[:self.character.target_count]

    def scene_status(self, debug_scene=False):
        wp = self.wp
        machine = self.character.state_machine
        active_id = self.active["definition"].id if self.active else 0
        status = {"time": time.perf_counter(), "state": machine.state.name,
            "layout_revision": self.layout_revision,
            "selected": self.selected_station,
            "interacting": machine.is_interacting, "seated": machine.is_interacting and machine.interaction_state.is_looping,
            "jumping": self.jumping, "jump_started": self.jump_started, "jump_completed": self.jump_completed,
            "active": active_id, "near": self.nearest["definition"].id if self.nearest else 0,
            "started": len(self.started), "completed": len(self.completed), "teleport": self.teleport_serial,
            "facing": godot_vector(wp, wp.vec3(*self.character.movement.current_facing)),
            "entries": [{"id": key, **godot_transform(wp, value[0]),
                         "facing": godot_vector(wp, wp.vec3(*value[1]))} for key, value in self.entries.items()]}
        if debug_scene:
            raw = self.boxes.numpy()
            boxes = []
            for item in self.instances:
                for index in range(item["offset"], item["offset"] + item["count"]):
                    box = raw[index]
                    boxes.append({"id": item["definition"].id,
                        **godot_transform(wp, wp.transform(*box["transform"])),
                        "size": [float(box["half_extents"][0])*2, float(box["half_extents"][2])*2,
                                 float(box["half_extents"][1])*2]})
            status["boxes"] = boxes
        return status
