"""Validate editor-owned flat-ground placements and convert Y-up to Z-up."""
import math
import numpy as np


def _transform(wp, value):
    position = np.asarray(value["position"], dtype=np.float32)
    rotation = np.asarray(value["rotation"], dtype=np.float32)
    if position.shape != (3,) or rotation.shape != (4,) or not np.isfinite(position).all() or not np.isfinite(rotation).all():
        raise ValueError("Scene transforms must contain finite position[3] and quaternion[4]")
    length = float(np.linalg.norm(rotation))
    if length < 1e-6 or abs(float(position[1])) > 0.01:
        raise ValueError("Scene roots must have a valid rotation and remain on Y=0")
    q = wp.quat(*(rotation/length))
    if wp.quat_rotate(q, wp.vec3(0, 1, 0))[1] < 0.999:
        raise ValueError("Only yaw rotation is supported on the flat interaction ground")
    conversion = wp.quat_from_axis_angle(wp.vec3(1, 0, 0), math.pi/2)
    return wp.transform(wp.quat_rotate(conversion, wp.vec3(*position)),
        wp.mul(wp.mul(conversion, q), wp.quat_inverse(conversion)))


def parse_layout(wp, layout, station_ids):
    revision = layout["revision"]
    if not isinstance(revision, str) or not 1 <= len(revision) <= 128:
        raise ValueError("Scene layout needs a revision identifier")
    start = _transform(wp, layout["start"])
    stations = layout["stations"]
    if not isinstance(stations, list) or len(stations) > len(station_ids):
        raise ValueError("Invalid number of scene stations")
    overrides = {key: {"enabled": False} for key in station_ids}
    seen = set()
    for value in stations:
        key = int(value["id"])
        if key not in station_ids or key in seen or not isinstance(value["enabled"], bool):
            raise ValueError("Station IDs must be known, unique, and have a boolean enabled flag")
        seen.add(key)
        overrides[key] = {"enabled": value["enabled"], "transform": _transform(wp, value)}
    return revision, start, overrides
