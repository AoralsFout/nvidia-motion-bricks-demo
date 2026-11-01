"""Convert the pinned official Gym's authored geometry to Godot coordinates."""
import json
import shutil
from paths import ROOT, UPSTREAM, initialize_warp

SCENE_PATH = UPSTREAM / "assets/scenes/soma_gym.scene.json"
STATIONS = {2: ("低箱跨越", "Small jump"), 5: ("高墙跨越", "High vault"),
            10: ("坐下 / 站起", "Sit / stand"), 12: ("低杆躲避", "Duck under")}


def load_definition():
    from app.runtime.common.io.scene_document import load_scene_document
    scene, _, _ = load_scene_document(SCENE_PATH)
    return scene.flatten()


def godot_transform(wp, transform):
    conversion = wp.quat_from_axis_angle(wp.vec3(1, 0, 0), wp.radians(90.0))
    inverse = wp.quat_inverse(conversion)
    position = wp.quat_rotate(inverse, transform.p)
    rotation = wp.mul(wp.mul(inverse, transform.q), conversion)
    return {"position": list(position), "rotation": list(rotation)}


def godot_vector(wp, vector):
    return list(wp.quat_rotate(wp.quat_from_axis_angle(wp.vec3(1, 0, 0), wp.radians(-90.0)), vector))


def export_scene():
    wp = initialize_warp("cpu")
    scene = load_definition()
    data = {"source": "NVlabs/motionbricks/assets/scenes/soma_gym.scene.json",
            "source_commit": "54fc563aeaaf819a753d72cc9fdc6713989cdd43",
            "start": godot_transform(wp, scene.character_start.transform), "objects": [], "stations": []}
    for cube in scene.solid_cubes:
        data["objects"].append({"id": cube.id, "name": cube.name,
            **godot_transform(wp, cube.transform), "size": [cube.width, cube.height, cube.depth],
            "color": list(cube.color)})
    for number, definition in enumerate(scene.smart_primitives, 1):
        title, english = STATIONS[definition.id]
        data["stations"].append({"id": definition.id, "number": number, "name": title,
            "english": english, "behavior": definition.behavior,
            **godot_transform(wp, definition.transform), "color": list(definition.target_pose_color)})
    output = ROOT / "assets/gym"
    output.mkdir(parents=True, exist_ok=True)
    (output / "gym.json").write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    shutil.copyfile(UPSTREAM / "LICENSE", output / "UPSTREAM_LICENSE.txt")
    print(f"Exported official Gym: {len(data['objects'])} solids, {len(data['stations'])} interactions", flush=True)


if __name__ == "__main__":
    export_scene()
