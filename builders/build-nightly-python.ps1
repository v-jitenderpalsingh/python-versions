<#
.SYNOPSIS
Build a nightly Python artifact from the top commit of CPython.

.DESCRIPTION
Pilot-quality standalone builder that:
  1. Clones the given CPython ref (default: main) shallowly.
  2. Reads the in-progress Python version from Include/patchlevel.h.
  3. Runs configure + make + make install into a private prefix.
  4. Packages the install tree together with the nix installer template
     into a tar.gz artifact under $env:RUNNER_TEMP/artifact.

This script intentionally does NOT reuse the class-based builders in this
repo so the pilot stays isolated from the release-quality build path.
Only Linux (Ubuntu) x64 is supported for now.

.PARAMETER SourceRef
CPython git ref to build (branch, tag, or commit SHA). Defaults to main.

.PARAMETER Platform
Platform label used in the artifact name and manifest, e.g. "linux-24.04".

.PARAMETER Arch
Architecture label used in the artifact name. Pilot only supports "x64".
#>

param(
    [string] $SourceRef = "main",
    [string] $Platform  = "linux-24.04",
    [string] $Arch      = "x64"
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

if ($Arch -ne "x64") {
    throw "Pilot only supports Arch 'x64' (got '$Arch')."
}
if (-not $env:RUNNER_TEMP) {
    throw "RUNNER_TEMP env var is required."
}

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$ArtifactDir = Join-Path $env:RUNNER_TEMP "artifact"
$WorkDir     = Join-Path $env:RUNNER_TEMP "work"
$SrcDir      = Join-Path $env:RUNNER_TEMP "cpython"
$InstallDir  = Join-Path $env:RUNNER_TEMP "install"

foreach ($dir in @($ArtifactDir, $WorkDir)) {
    New-Item -Force -ItemType Directory -Path $dir | Out-Null
}
foreach ($dir in @($SrcDir, $InstallDir)) {
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
}

Write-Host "==> Cloning CPython (ref='$SourceRef') into $SrcDir"
# Blobless partial clone: full commit/tree/tag history (so `git describe`
# works) without downloading every historical file blob. Fast enough and
# avoids the tag-fetching pitfalls of `--depth 1` shallow clones.
git clone --filter=blob:none --branch $SourceRef https://github.com/python/cpython.git $SrcDir

Push-Location $SrcDir
try {
    $CommitSha  = (git rev-parse --short=12 HEAD).Trim()
    $CommitDate = (git show -s --format=%cs HEAD).Trim()   # YYYY-MM-DD
    # Describe against the nearest annotated tag, always emit something, and
    # include the commit count + short SHA so it is unique per nightly.
    $describeRaw = (git describe --tags --long --always HEAD).Trim()
} finally {
    Pop-Location
}

# CPython tags are prefixed with `v` (e.g. `v3.15.0a1`); strip it so the
# resulting identifier lines up with what patchlevel.h reports.
$Describe = $describeRaw -replace '^v', ''
Write-Host "==> git describe    : $Describe"

$patchLevel = Get-Content (Join-Path $SrcDir "Include/patchlevel.h") -Raw
$major = [regex]::Match($patchLevel, '#define\s+PY_MAJOR_VERSION\s+(\d+)').Groups[1].Value
$minor = [regex]::Match($patchLevel, '#define\s+PY_MINOR_VERSION\s+(\d+)').Groups[1].Value
$micro = [regex]::Match($patchLevel, '#define\s+PY_MICRO_VERSION\s+(\d+)').Groups[1].Value
# Note: the `\s+PY_RELEASE_LEVEL\s+PY_RELEASE_LEVEL_` boundary uniquely matches
# the definition line and not the constant declarations above it.
$releaseLevel  = [regex]::Match($patchLevel, '#define\s+PY_RELEASE_LEVEL\s+PY_RELEASE_LEVEL_(\w+)').Groups[1].Value
$releaseSerial = [regex]::Match($patchLevel, '#define\s+PY_RELEASE_SERIAL\s+(\d+)').Groups[1].Value

$suffixMap = @{ ALPHA = "a"; BETA = "b"; GAMMA = "rc"; FINAL = "" }
if (-not $suffixMap.ContainsKey($releaseLevel)) {
    throw "Unknown PY_RELEASE_LEVEL '$releaseLevel' in patchlevel.h"
}
$suffix = $suffixMap[$releaseLevel]
$pythonVersion = "$major.$minor.$micro$suffix"
if ($releaseLevel -ne "FINAL") { $pythonVersion += $releaseSerial }

# Use `git describe` as the canonical nightly identifier. It already carries
# the base Python version (from the nearest tag), commits-since-tag, and the
# short SHA, so it is unique per commit and human-readable.
$nightlyVersion = $Describe
$artifactBase   = "python-$nightlyVersion-$Platform-$Arch"
$outputTarball  = Join-Path $ArtifactDir "$artifactBase.tar.gz"

Write-Host "==> Python version : $pythonVersion"
Write-Host "==> Nightly version: $nightlyVersion"
Write-Host "==> Commit         : $CommitSha ($CommitDate)"
Write-Host "==> Artifact       : $outputTarball"

# --- Configure & build ------------------------------------------------------
# Enable-shared + rpath so the runtime can find libpython at the install prefix.
# We deliberately skip --enable-optimizations to keep pilot runs fast.
$env:LDFLAGS = "-Wl,--rpath=$InstallDir/lib"

Push-Location $SrcDir
try {
    Write-Host "==> configure"
    & ./configure `
        --prefix=$InstallDir `
        --enable-shared `
        --with-lto `
        --enable-loadable-sqlite-extensions

    $jobs = (& nproc).Trim()
    Write-Host "==> make -j$jobs"
    & make -j $jobs

    Write-Host "==> make install"
    & make install
} finally {
    Pop-Location
}

# --- Stage tarball contents -------------------------------------------------
$stageDir = Join-Path $WorkDir "stage"
if (Test-Path $stageDir) { Remove-Item -Recurse -Force $stageDir }
New-Item -Force -ItemType Directory -Path $stageDir | Out-Null

Write-Host "==> Staging install tree"
Copy-Item -Recurse -Force -Path (Join-Path $InstallDir "*") -Destination $stageDir

# Render the installer template. The runtime setup script only cares about
# MAJOR.MINOR from PYTHON_FULL_VERSION (it uses `cut -d.`), so passing the
# base Python version here keeps the on-runner install layout unchanged.
$installerTemplate = Get-Content (Join-Path $RepoRoot "installers/nix-setup-template.sh") -Raw
$installerText = $installerTemplate.
    Replace("{{__VERSION_FULL__}}", $pythonVersion).
    Replace("{{__ARCH__}}", $Arch)
Set-Content -NoNewline -Path (Join-Path $stageDir "setup.sh") -Value $installerText

# Small metadata blob so downstream consumers know what commit they got.
$metadata = [ordered]@{
    python_version  = $pythonVersion
    describe        = $Describe
    nightly_version = $nightlyVersion
    commit_sha      = $CommitSha
    commit_date     = $CommitDate
    platform        = $Platform
    arch            = $Arch
    artifact        = "$artifactBase.tar.gz"
    source_ref      = $SourceRef
}
$metadata | ConvertTo-Json | Set-Content -Path (Join-Path $stageDir "nightly-info.json")

# --- Archive ----------------------------------------------------------------
Write-Host "==> Creating $outputTarball"
Push-Location $stageDir
try {
    & tar -czf $outputTarball .
} finally {
    Pop-Location
}

# --- GitHub Actions step outputs -------------------------------------------
if ($env:GITHUB_OUTPUT) {
    @(
        "python_version=$pythonVersion"
        "nightly_version=$nightlyVersion"
        "commit_sha=$CommitSha"
        "commit_date=$CommitDate"
        "artifact_name=$artifactBase"
        "platform=$Platform"
        "arch=$Arch"
    ) | ForEach-Object { Add-Content -Path $env:GITHUB_OUTPUT -Value $_ }
}

Write-Host "==> Done."
