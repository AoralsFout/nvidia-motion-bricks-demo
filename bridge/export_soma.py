"""Convert the official SOMA USD through its own loader into a skinned GLB.

No rig retargeting: joint order, local rest transforms, and inverse binds come
directly from MotionBricks. The source is Y-up/metres, just like the GLB.
"""
import json
import struct
import shutil
import numpy as np
from scipy.spatial.transform import Rotation
from paths import ROOT, UPSTREAM, initialize_warp


def export():
    initialize_warp("cpu")
    from motionbricks.io.utils import get_soma_human_model
    model = get_soma_human_model()
    skeleton = model.skeleton
    rest = skeleton.reference_local_transforms.numpy()
    parents = skeleton.parent_indices.numpy()
    binary = bytearray()
    document = {
        "asset": {"version": "2.0", "generator": "MotionBricks Godot USD converter",
                  "copyright": "NVIDIA CORPORATION & AFFILIATES; asset CC-BY-4.0"},
        "scene": 0, "scenes": [{"nodes": [0]}],
        "nodes": [{"name": "SOMA", "children": [1]}],
        "meshes": [], "skins": [], "buffers": [], "bufferViews": [], "accessors": [],
        "materials": [{"name": "Official gray SOMA", "doubleSided": False,
                       "pbrMetallicRoughness": {"baseColorFactor": [0.7, 0.7, 0.7, 1],
                                                "metallicFactor": 0, "roughnessFactor": 0.72}}],
    }

    def accessor(values, component, kind, bounds=False):
        values = np.ascontiguousarray(values)
        while len(binary) % 4:
            binary.append(0)
        offset = len(binary)
        binary.extend(values.tobytes())
        view = len(document["bufferViews"])
        document["bufferViews"].append({"buffer": 0, "byteOffset": offset, "byteLength": values.nbytes})
        entry = {"bufferView": view, "componentType": component, "count": len(values), "type": kind}
        if bounds:
            entry.update(min=values.min(axis=0).tolist(), max=values.max(axis=0).tolist())
        document["accessors"].append(entry)
        return len(document["accessors"]) - 1

    for i, name in enumerate(skeleton.joint_names):
        document["nodes"].append({"name": name, "translation": rest[i, :3].tolist(),
                                  "rotation": rest[i, 3:].tolist()})
    for i, parent in enumerate(parents):
        if parent >= 0:
            document["nodes"][int(parent) + 1].setdefault("children", []).append(i + 1)

    binds = model.inverse_bind_transforms.numpy()
    matrices = np.tile(np.eye(4, dtype=np.float32), (len(binds), 1, 1))
    matrices[:, :3, :3] = Rotation.from_quat(binds[:, 3:]).as_matrix()
    matrices[:, :3, 3] = binds[:, :3]
    inverse_bind_accessor = accessor(matrices.transpose(0, 2, 1).copy(), 5126, "MAT4")
    document["skins"].append({"name": "SOMA", "joints": list(range(1, len(rest) + 1)),
                               "skeleton": 1, "inverseBindMatrices": inverse_bind_accessor})

    for part_index, part in enumerate(model.skinned_meshes):
        vertices = part.points.numpy().astype("<f4")
        triangles = part.indices.numpy().reshape(-1, 3).astype("<u4")
        normals = np.zeros_like(vertices)
        face_normals = np.cross(vertices[triangles[:, 1]] - vertices[triangles[:, 0]],
                                vertices[triangles[:, 2]] - vertices[triangles[:, 0]])
        for corner in range(3):
            np.add.at(normals, triangles[:, corner], face_normals)
        normals /= np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-10)
        joints = part.joint_indices.numpy().reshape(len(vertices), -1)
        weights = part.joint_weights.numpy().reshape(len(vertices), -1)
        # Preserve up to eight strongest influences, supported by Godot/glTF.
        order = np.argsort(-weights, axis=1)[:, :8]
        joints = np.take_along_axis(joints, order, axis=1)
        weights = np.take_along_axis(weights, order, axis=1)
        weights /= np.maximum(weights.sum(axis=1, keepdims=True), 1e-10)
        padding = (-weights.shape[1]) % 4
        joints = np.pad(joints, ((0, 0), (0, padding)))
        weights = np.pad(weights, ((0, 0), (0, padding)))
        attributes = {"POSITION": accessor(vertices, 5126, "VEC3", True),
                      "NORMAL": accessor(normals, 5126, "VEC3")}
        for start in range(0, weights.shape[1], 4):
            attributes[f"JOINTS_{start // 4}"] = accessor(joints[:, start:start+4].astype("<u2"), 5123, "VEC4")
            attributes[f"WEIGHTS_{start // 4}"] = accessor(weights[:, start:start+4].astype("<f4"), 5126, "VEC4")
        document["meshes"].append({"name": f"SOMA_{part_index}", "primitives": [
            {"attributes": attributes, "indices": accessor(triangles.flatten(), 5125, "SCALAR"), "material": 0}]})
        mesh_node = len(document["nodes"])
        document["nodes"].append({"name": f"Body_{part_index}", "mesh": part_index, "skin": 0})
        document["nodes"][0]["children"].append(mesh_node)
    while len(binary) % 4:
        binary.append(0)
    document["buffers"] = [{"byteLength": len(binary)}]
    encoded = json.dumps(document, separators=(",", ":")).encode()
    encoded += b" " * ((-len(encoded)) % 4)
    output = ROOT / "assets/soma"
    output.mkdir(parents=True, exist_ok=True)
    glb = struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(encoded) + 8 + len(binary))
    glb += struct.pack("<II", len(encoded), 0x4E4F534A) + encoded
    glb += struct.pack("<II", len(binary), 0x004E4942) + binary
    (output / "soma.glb").write_bytes(glb)
    (output / "rig.json").write_text(json.dumps({"joints": skeleton.joint_names,
        "parents": parents.tolist(), "rest": rest.tolist()}, separators=(",", ":")), encoding="utf-8")
    shutil.copyfile(UPSTREAM / "LICENSE", output / "UPSTREAM_LICENSE.txt")
    print(f"Exported official SOMA: {len(rest)} joints, {len(glb):,} bytes", flush=True)


if __name__ == "__main__":
    export()
