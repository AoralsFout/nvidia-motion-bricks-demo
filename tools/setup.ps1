param([switch]$SkipBenchmark)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $projectRoot
$runtimeRoot = Join-Path $projectRoot '.runtime'
$repo = Join-Path $runtimeRoot 'motionbricks'
$revision = '54fc563aeaaf819a753d72cc9fdc6713989cdd43'
New-Item -ItemType Directory -Force (Join-Path $runtimeRoot 'tools') | Out-Null
Set-Content -LiteralPath (Join-Path $runtimeRoot '.gdignore') -Value ''
New-Item -ItemType Directory -Force (Join-Path $projectRoot 'logs') | Out-Null
Set-Content -LiteralPath (Join-Path $projectRoot 'logs/.gdignore') -Value ''
if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
    git clone --no-checkout https://github.com/NVlabs/motionbricks.git $repo
    if ($LASTEXITCODE) { throw 'Could not clone MotionBricks' }
}
git -C $repo fetch --depth 1 origin $revision
if ($LASTEXITCODE) { throw 'Could not fetch pinned MotionBricks revision' }
# Disable external filters here. Materialize only the files used by this demo below.
git -C $repo -c filter.lfs.process= -c filter.lfs.smudge= -c filter.lfs.required=false restore --source=$revision --staged --worktree -- .
if ($LASTEXITCODE) { throw 'Could not restore MotionBricks files' }
$paths = @(
    'motionbricks/assets/human/soma_base_skel_minimal_no_root.usd',
    'motionbricks/assets/onnx/soma/mmm_v6_soma_fp16.onnx',
    'assets/motions/soma/locomotion/bs_1d_linear/neutral_walk_ff_180_R_002__A536_M.bvh',
    'assets/motions/soma/locomotion/bs_1d_linear/neutral_jog_ff_180_R_001__A534.bvh',
    'assets/motions/soma/locomotion/bs_1d_linear/run_loop_180_R_003__A326.bvh',
    'assets/motions/soma/locomotion/idle/idle_loop_001__A268.bvh'
)
foreach ($relative in $paths) {
    $target = Join-Path $repo $relative
    $pointer = Get-Content -LiteralPath $target -Raw
    if ($pointer -notmatch 'oid sha256:([a-f0-9]{64})') { throw "Expected LFS pointer: $relative" }
    $oid = $Matches[1]
    $cache = Join-Path $runtimeRoot "downloads/$oid"
    New-Item -ItemType Directory -Force (Split-Path -Parent $cache) | Out-Null
    $lfsCache = Join-Path $repo ('.git/lfs/objects/' + $oid.Substring(0,2) + '/' + $oid.Substring(2,2) + '/' + $oid)
    if (Test-Path -LiteralPath $lfsCache) { Copy-Item -LiteralPath $lfsCache -Destination $cache }
    if (-not (Test-Path -LiteralPath $cache)) {
        Write-Host "Downloading $relative"
        curl.exe --fail --location --retry 3 --output "$cache.partial" "https://media.githubusercontent.com/media/NVlabs/motionbricks/$revision/$relative"
        if ($LASTEXITCODE) { throw "Download failed: $relative" }
        Move-Item -LiteralPath "$cache.partial" -Destination $cache -Force
    }
    if ((Get-FileHash -LiteralPath $cache -Algorithm SHA256).Hash.ToLowerInvariant() -ne $oid) { throw "SHA256 mismatch: $relative" }
    Copy-Item -LiteralPath $cache -Destination $target
}
$uv = Join-Path $runtimeRoot 'tools/uv.exe'
if (-not (Test-Path -LiteralPath $uv)) {
    $archive = Join-Path $runtimeRoot 'tools/uv.zip'
    Invoke-WebRequest 'https://github.com/astral-sh/uv/releases/download/0.13.6/uv-x86_64-pc-windows-msvc.zip' -OutFile $archive
    Expand-Archive -LiteralPath $archive -DestinationPath (Split-Path -Parent $uv) -Force
}
$env:UV_CACHE_DIR = Join-Path $runtimeRoot 'uv-cache'
$env:UV_PYTHON_INSTALL_DIR = Join-Path $runtimeRoot 'python'
$env:UV_PYTHON_BIN_DIR = Join-Path $runtimeRoot 'python-bin'
$env:UV_LINK_MODE = 'copy'
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
$env:NVIDIA_TENSORRT_DISABLE_INTERNAL_PIP = '1'
$python = Join-Path $repo '.venv/Scripts/python.exe'
if (-not (Test-Path -LiteralPath $python)) {
    & $uv venv (Join-Path $repo '.venv') --python 3.12
    if ($LASTEXITCODE) { throw 'Could not create local Python environment' }
}
& $uv pip install --python $python --extra-index-url https://pypi.nvidia.com --index-strategy unsafe-best-match -r bridge/requirements.txt
if ($LASTEXITCODE) { throw 'Dependency installation failed' }
& $python bridge/export_soma.py
if ($LASTEXITCODE) { throw 'SOMA conversion failed' }
& $python tools/prepare_gym.py
if ($LASTEXITCODE) { throw 'Official Gym asset preparation failed' }
& $python bridge/gym_scene.py
if ($LASTEXITCODE) { throw 'Official Gym scene conversion failed' }
if (-not $SkipBenchmark) {
    & $python bridge/server.py --benchmark
    if ($LASTEXITCODE) { throw 'MotionBricks benchmark failed; see logs/bridge.log' }
}
Write-Host 'Setup complete. Run tools/run.ps1 or open project.godot.'
