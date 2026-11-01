# Official SOMA Gym scene

Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES.

Source: https://github.com/NVlabs/motionbricks/blob/54fc563aeaaf819a753d72cc9fdc6713989cdd43/assets/scenes/soma_gym.scene.json

Scene asset terms: CC-BY-4.0, https://creativecommons.org/licenses/by/4.0/
The upstream license is included as `UPSTREAM_LICENSE.txt`.

Changes: flatten the scene's parent hierarchy, convert Z-up transforms to Godot's
Y-up space, reproduce the four Solid Cubes with their authored dimensions and
colors, add translated station labels and optional debug displays.

Motion samples remain in the local upstream checkout under their separate
NVIDIA Sample Data Evaluation License; this is an internal evaluation scene.
