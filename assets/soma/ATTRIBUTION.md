# Official SOMA character

Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES.

Source: https://github.com/NVlabs/motionbricks/blob/54fc563aeaaf819a753d72cc9fdc6713989cdd43/motionbricks/assets/human/soma_base_skel_minimal_no_root.usd

Repository asset terms: CC-BY-4.0, https://creativecommons.org/licenses/by/4.0/
The upstream license is copied to `UPSTREAM_LICENSE.txt` during conversion.

Changes: USD geometry, local rest pose, joint hierarchy, skin weights and inverse
bind transforms are converted to glTF 2.0 binary by `bridge/export_soma.py`.
Smooth vertex normals are recomputed; at most eight strongest skin influences
are retained and normalized. The official gray material is reproduced. No
retargeting or character redesign is performed.

The model weights and bundled motion samples have separate terms. Motion samples
are used from the local upstream checkout for internal evaluation only and are
not copied into this asset folder.
