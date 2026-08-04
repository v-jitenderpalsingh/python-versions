[String] $Architecture = "{{__ARCHITECTURE__}}"
[String] $Version = "{{__VERSION__}}"

$ToolcacheRoot = $env:AGENT_TOOLSDIRECTORY
if ([string]::IsNullOrEmpty($ToolcacheRoot)) {
    $ToolcacheRoot = $env:RUNNER_TOOL_CACHE
}
if ([string]::IsNullOrEmpty($ToolcacheRoot)) {
    throw "AGENT_TOOLSDIRECTORY or RUNNER_TOOL_CACHE must be set"
}

$PythonVersionPath = Join-Path $ToolcacheRoot "Python/$Version"
$PythonArchPath = Join-Path $PythonVersionPath $Architecture

if (Test-Path $PythonArchPath) {
    Remove-Item -Path $PythonArchPath -Recurse -Force
}
New-Item -ItemType Directory -Path $PythonArchPath -Force | Out-Null

Get-ChildItem -Path $PSScriptRoot | Where-Object Name -ne "setup.ps1" | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $PythonArchPath -Recurse -Force
}

if (-not (Test-Path (Join-Path $PythonArchPath "python.exe"))) {
    throw "Portable layout does not contain python.exe"
}

$PythonExePath = Join-Path $PythonArchPath "python.exe"
& $PythonExePath -m ensurepip --upgrade --default-pip
if ($LASTEXITCODE -ne 0) {
    throw "Failed to install pip into the portable layout"
}

New-Item -ItemType File -Path $PythonVersionPath -Name "$Architecture.complete" -Force | Out-Null