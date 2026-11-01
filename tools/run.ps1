param([int]$SoakSeconds = 0, [switch]$Flat)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $projectRoot
$localEngine = Join-Path $projectRoot '.runtime/tools/godot/Godot_v4.7.2-stable_win64.exe'
if (-not (Test-Path -LiteralPath $localEngine)) {
    $archive = Join-Path $projectRoot '.runtime/tools/godot.zip'
    New-Item -ItemType Directory -Force (Split-Path -Parent $archive) | Out-Null
    Invoke-WebRequest 'https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_win64.exe.zip' -OutFile $archive
    Expand-Archive -LiteralPath $archive -DestinationPath (Split-Path -Parent $localEngine) -Force
}
$env:APPDATA = Join-Path $projectRoot '.runtime/appdata'
$consoleEngine = $localEngine -replace '\.exe$', '_console.exe'
$portableMarker = Join-Path (Split-Path -Parent $localEngine) '_sc_'
if (-not (Test-Path -LiteralPath $portableMarker)) { Set-Content -LiteralPath $portableMarker -Value '' }
# Import on a fresh checkout too; runtime exports alone do not create Godot's cache.
& $consoleEngine --headless --path $projectRoot --editor --import --quit --log-file (Join-Path $projectRoot '.runtime/import.log')
if ($LASTEXITCODE) { throw 'Godot asset import failed' }
& $consoleEngine --headless --path $projectRoot --script tools/verify_rig.gd --log-file (Join-Path $projectRoot '.runtime/rig-check.log')
if ($LASTEXITCODE) { throw 'Imported SOMA skeleton did not match the source rig' }
$logName = if ($SoakSeconds -gt 0) { '.runtime/soak.log' } else { '.runtime/game.log' }
$arguments = @('--path', $projectRoot, '--log-file', (Join-Path $projectRoot $logName))
$gameArguments = @()
if ($Flat) { $gameArguments += '--flat' }
if ($SoakSeconds -gt 0) { $gameArguments += "--soak=$SoakSeconds" }
if ($gameArguments.Count -gt 0) { $arguments += @('--') + $gameArguments }
& $consoleEngine @arguments
