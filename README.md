# MotionBricks × Godot

Windows 本机技术验证：官方 SOMA 人物与 SOMA Gym 场景，WASD 行走、Shift 跑步、自然停止和转向，支持四种物体交互。
MotionBricks 生成骨架及根位移；Godot 负责场景、输入、相机和蒙皮显示。

## 启动

安装与首次构建（工程目录内隔离，不修改系统 Python）：

```powershell
pwsh -File tools/setup.ps1
pwsh -File tools/run.ps1
```

首次下载包含约 380 MB 的 FP16 模型和约 1.5 GB 的 TensorRT 运行库，需要额外缓存及解压空间。
首次 TensorRT 编译需要数分钟；后续复用 `.runtime/trt-cache/`。
`run.ps1` 使用工程内标准版 Godot 4.7.2，避免依赖系统 .NET 环境。
Godot 使用便携模式，编辑器设置和缓存也保留在工程内。
依赖、Python、上游代码和缓存均在 `.runtime/`，Godot 不会导入该目录。

Godot 编辑器中打开 `project.godot` 并按 F6/F5 也可启动；模型服务由场景自动启动并随场景关闭。
WASD：相对相机方向移动；Shift：跑步；右键拖动：环视；滚轮：缩放；R：重置；Esc：退出。
默认加载官方公开的 `assets/scenes/soma_gym.scene.json`，保留四个方块的尺寸、颜色和世界变换。
这次复刻范围是公开的 SOMA Gym 测试场景。

| 入口键 / 左侧按钮 | 交互 |
| --- | --- |
| 1 | 低箱跨越 |
| 2 | 高墙跨越（官方手部 IK） |
| 3 | 坐下，保持坐姿，再按 E / I 起身 |
| 4 | 低杆躲避 |

按入口键后，人物移至对应站点前方并面朝接近方向，按住 W 接近即可自动交互。

**空格：自由跳跃。** 静止时原地跳，移动时向输入方向前跳；落地后继续响应移动。
跳跃采用官方低箱跳跃的腾空/落地目标，按当前位置、朝向及输入速度重新放置，再由 MotionBricks 生成动作。
空中重复按空格不会连跳；坐下、跨越等交互期间不打断当前动作。此功能用于默认 Gym 模式。

右上角可以关闭「自动交互」，改为进入触发范围后按 E / I。
F3 切换真实交互包围盒：粉色为普通区域，绿色为可交互区域，橙色为当前动作。
M 切换场景总览；地面箭头标记各站的建议接近方向。
交互结束后恢复移动；坐姿会保持到收到起身指令。同一次接近只自动触发一次，离开区域后可再次触发。
四站交互依据官方 Smart Primitive 的目标序列及速度匹配生成；人物与物体的接触不使用 Godot 刚体碰撞求解。
需要原先的平地步态演示时运行 `pwsh -File tools/run.ps1 -Flat`。
失焦或指令中断时发送/执行停止目标。
同时识别物理键与逻辑键；极短的按键会保留 60 ms，避免跨帧及桥接采样丢失。

地面使用 1 米细网格和 5 米主网格，红色为 X 轴、蓝色为 Z 轴。
右上角「目标骨架 [F2]」复选框或 F2 可切换目标姿态调试绘制，默认关闭。
开启后显示实际送入模型的 1–4 帧目标骨架：青、紫、橙、粉依次对应第 1–4 帧。
骨架允许透过人物查看；每次重新生成时更新，重置后清空，等待下一次生成。
关闭时后端不读取或传输目标骨架数据。命令行可追加 `--debug-targets` 初始开启。

## 在 Godot 编辑器中编辑

打开 `scenes/main.tscn` 即可查看完整场景。主体节点已保存为场景资源，运行时只绑定节点，不再重新生成灯光、地面、人物、四个站点或 HUD。
主场景已开启子场景的可编辑子节点，也可以单独打开下列子场景修改。

| 场景树 / 资源 | 可编辑内容 |
| --- | --- |
| `main.tscn → World` | 环境、背景、太阳光、补光、地面 Mesh |
| `main.tscn → Gym` / `scenes/gym.tscn` | 四个站点的位置、朝向、物体材质、标签 |
| `main.tscn → Player` / `scenes/character.tscn` | 玩家出生位置与朝向、官方人物模型和骨架查看 |
| `main.tscn → CameraRig` | 跟随相机、总览相机的 FOV / 裁剪距离与总览构图 |
| 主场景根节点 Inspector 的 `Camera` 组 | 跟随开关、视角俯仰、距离、侧向偏移；关闭 `Follow Player` 后可直接布置跟随相机位置 |
| `scenes/hud.tscn` | 标题、按钮、字体、颜色、锚点、容器布局和统计面板；保留带 `%` 唯一名称的运行时控件 |
| `assets/ui/panel_style.tres` | 共享面板背景、边框、圆角和内边距 |
| `assets/materials/grid_floor.tres` | 网格间距、粗细和配色等 Shader 参数 |
| `scenes/target_skeleton_debug.tscn` | 目标骨架的骨骼 / 关节 Mesh、材质、半径与目标颜色 |

移动交互物体时，请选中 `SmallJump`、`HighVault`、`SitStand` 或 `Avoidance` 整个站点根节点，保存后重新运行。
启动时场景中的刚体变换会同步给 Python，目标姿态、触发区域和入口快捷键会一起移动；R 也会重置到编辑后的 `Player` 起点。
站点的 `Interaction Enabled` 可关闭交互及其入口按钮。当前保留四种官方交互，每种 ID 在场景内保持唯一。

交互目前基于水平地面：玩家与站点根节点保持 Y=0、单位缩放，只沿 X/Z 平移或绕 Y 轴旋转。
`Geometry` 子节点的 Mesh 尺寸、缩放和局部变换只改变外观；修改实际接触高度或形状，需要同时修改对应的官方 Smart Primitive 目标。
地面也应保持水平。添加普通装饰节点不受站点类型限制。

骨架姿态、实际触发包围盒和入口箭头来自模型运行数据，仍在运行时更新；它们的承载节点和绘制资源已经保存在场景树中。
`setup.ps1` 不会重写这些 `.tscn` 文件。`assets/gym/gym.json` 保留为官方场景来源记录，运行时布局以 Godot 场景节点为准。

## 验证

```powershell
# 编辑器结构、保存 / 重载、变换同步，以及移动站点后的真实动作
.runtime/tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path . --script tools/check_editor_scene.gd
.runtime/motionbricks/.venv/Scripts/python.exe tools/check_scene_layout.py
.runtime/tools/godot/Godot_v4.7.2-stable_win64_console.exe --path . --script tools/check_editor_scene_ui.gd -- --debug-targets
# 四站真实模型动作检查：跨越、坐姿保持与起身、降低头部通过低杆
.runtime/motionbricks/.venv/Scripts/python.exe tools/check_gym.py
# 原地 / 行走 / 跑步跳跃：双脚腾空、落地、恢复移动、禁止空中重复起跳
.runtime/motionbricks/.venv/Scripts/python.exe tools/check_jump.py
# 空格输入 → UDP → 模型 → Godot 骨架显示的有窗口检查
.runtime/tools/godot/Godot_v4.7.2-stable_win64_console.exe --path . --script tools/check_jump_ui.gd
# Godot + UDP + 模型的有窗口交互检查（站点 ID 为 2、5、10、12）
.runtime/tools/godot/Godot_v4.7.2-stable_win64_console.exe --path . -- --interaction-test=10
# 真实模型离线基准：起步、行走、跑步、转向、停止
.runtime/motionbricks/.venv/Scripts/python.exe bridge/server.py --benchmark
# 有窗口自动运行，累计 600 秒实时连接后退出
pwsh -File tools/run.ps1 -SoakSeconds 600
# 校验上述结果是否满足验收目标
.runtime/motionbricks/.venv/Scripts/python.exe tools/summarize.py
```

`logs/benchmark.json` 记录模型生成耗时；`logs/session.csv` 记录现场指标；
`logs/soak.json` 记录持续运行汇总；`logs/demo.png` 是自动运行的截图。
`logs/bridge.log` 与 `logs/bridge_status.json` 记录后端状态和错误。
`logs/gpu.csv` 记录整张显卡的占用（包含桌面和其他应用），`logs/validation.json` 是验收汇总。
四站动作统计保存在 `logs/gym/check.json` 和各站原始姿态；
有窗口检查保存在 `logs/gym/ui-{id}.json`，动作截图为 `logs/gym/live-{id}.png`。
自由跳跃检查及原始姿态保存在 `logs/jump/`，`ui.json` 为有窗口检查，`live.png` 为腾空截图。
编辑器布局检查位于 `logs/editor-scene/`：包括保存后的测试场景、发送给后端的布局、变换误差及动作检查结果。
四种交互的模型侧检查和 Godot 端完整触发检查均已通过；坐姿检查包含保持和手动起身。
这些是功能检查，尚未对 Gym 模式重复执行十分钟性能验收。持续运行命令仍使用平地模式。

目标：10 分钟连续运行、渲染 60 FPS、指令到首个新生成姿态争取低于 200 ms。
“指令→姿态”是 Godot 发出变化指令到接收带对应生成编号的姿态，再加一帧内插显示；
不是角色完全停止/转身所需时间，也不是经过显示器光学测量的端到端延迟。
GPU 推理耗时与完整生成耗时分别显示，不能混为一谈。

### 本机实测（2026-11-01）

RTX 3050 Ti Laptop 4 GB，Windows，标准版 Godot 4.7.2，OpenGL Compatibility，1280×800，未限制 FPS。
以下是最初接入版本的持续运行记录；步态参数更新的独立检查见文末。
完整原始记录保存在 `logs/verified/`，后续手动运行不会覆盖这份记录。

| 指标 | 结果 |
| --- | --- |
| 持续接收姿态 | 600.01 秒 |
| 模型生成 / 接收姿态 | 621 次 / 35,403 帧 |
| 超过 500 ms 的连接中断 / Godot 运行错误 | 0 / 0 |
| 指令到首个新生成姿态 P95（120 次变化） | 41.75 ms |
| 渲染帧耗时 P95 | 9.04 ms |
| 未限帧平均渲染 FPS | 389.68 |
| 整张显卡显存峰值，包含桌面与其他应用 | 2,795 MiB / 4,096 MiB |

**限制：尚未证明全程稳定 60 FPS。** 约每四分之一秒采样中，61/2358 个有效样本低于 60 FPS，最低为 2 FPS。
发生过短时掉帧后恢复，原因尚未确认；平均值和按渲染帧计算的 P95 不能代表没有卡顿。
报告的 `aggregate_targets_passed` 只表示所列平均值/P95检查通过；
`continuous_60fps_demonstrated` 明确为 `false`。前台可操作演示已接通，仍属于技术验证版本。
随后单独完成了原生窗口的 W、Shift+W、D、R、Esc 和滚轮缩放检查，
输入记录见 `logs/verified/manual_input.csv`。右键环视已实现，未用 UI 工具直接执行右键拖动。
可用 `tools/summarize.py --recording logs/verified` 重查这份保存的持续运行记录。

## 接入边界

- 官方代码固定在 `54fc563aeaaf819a753d72cc9fdc6713989cdd43`。
- Gym 复用官方 `SOMACharacter`、状态机、`ClipRegistry`、`SmartPrimitiveAssetPool` 与交互行为类；平地模式保留独立运行时用于对比。
- FP16 模型、batch=1、TensorRT 构建 workspace=256 MiB、优化等级 1，适配 4 GB 显存验证。
- 移动目标直接加载官方 `locomotion_bs1_linear.smart_primitive.json`，保留作者选择的帧、朝向与 hips_constrained 设置，并调用官方 `SOMATargetPoseBlender` 混合 Idle/Walk/Jog/Run。
- 对齐官方 Forward 预设：默认走路 2.3 m/s、Shift 跑步 4.5 m/s，velocity_scale=0.97，目标提前 1 秒，提前 10 帧衔接，允许 8–14 tokens。
- 复用官方 `MovementControl` 的加减速和转向平滑，重新生成阈值对齐官方 `LocomotionState`。参数适配位于 `bridge/locomotion_profile.py`，无需导入 Newton 查看器。
- 控制包/姿态包仅经 `127.0.0.1:27841` UDP 传递。每包包含完整姿态，可独立恢复；过期包丢弃。
- 官方运行时是 Z-up；桥接只将根变换还原至模型的 Y-up，子关节保持父级局部坐标。
- glTF 中不启用骨架重定向。按名字映射每个原始关节，完整应用位置和四元数。
- Gym 使用官方待机循环、坐姿循环 BVH，进入/退出坐姿、跨越及躲避由模型按官方目标序列生成。平地模式闲置时保持生成动作末姿态。
- 交互判定复用官方 probe box 与交互盒重叠、最近物体选择、一次接近触发一次的逻辑。场景没有导航、多人角色或通用刚体碰撞。
- 推理失败时界面显示错误。界面中的目标骨架来自真实模型输入。

## 来源与许可

[MotionBricks](https://github.com/NVlabs/motionbricks) 源码 Apache-2.0，人物资产按上游资产条款 CC-BY-4.0，
署名和转换说明见 `assets/soma/ATTRIBUTION.md` 与 `assets/gym/ATTRIBUTION.md`。
[模型权重](https://huggingface.co/nvidia/MotionBricks) 使用 NVIDIA Open Model Agreement。
官方运动样本使用单独的 NVIDIA Sample Data Evaluation License，仅用于本次内部评估。
发布产品或分发样本衍生物前需要重新核实相应权利；当前项目没有包含训练管线。

## 步态对比检查

固定方向输入、60 Hz 更新，丢弃前三秒起步阶段后，原版两脚前后张开距离 P95 约 0.50 m；
官方配置版本约 0.79 m。默认请求速度也由 1.4 改为 2.3 m/s，不能把整个差异仅归因于目标帧。
原版、仅换目标帧、继续对齐目标距离/衔接参数、最终配置的原始姿态与统计均保存在 `logs/gait/`。
`baseline.png` / `official.png` 是这些真实姿态在 Godot 中以相同侧面机位绘制的六帧图。

```powershell
.runtime/motionbricks/.venv/Scripts/python.exe tools/gait_probe.py --label check
.runtime/tools/godot/Godot_v4.7.2-stable_win64_console.exe --path . --script tools/gait_preview.gd -- --label=check
```

检查中的 0.60 m 阈值是当前 SOMA 固定输入场景的步幅代理指标，不是通用动作质量评分。
参数出处为固定上游版本的 `app/runtime/soma/presets.py`、`app/runtime/common/motion.py`、
`app/runtime/common/target_pose_blender.py` 及上述 Smart Primitive。
