<#
.SYNOPSIS
  Builds a redistributable legible-coder installer package for Windows.

.DESCRIPTION
  Produces a single folder (and optionally a zip) that can be copied to a fresh Windows
  machine and installed offline:

    legible-coder-setup/
      install.cmd            - double-clickable bootstrap
      install.ps1
      uninstall.cmd
      uninstall.ps1
      make-package.ps1
      app/                   - coder.lbl + every module it uses + docs
      runtime/legible.exe    - the interpreter, when -LegibleExe is given

  Without -LegibleExe the package has no runtime\legible.exe, and install.ps1 on the
  target machine will look for legible on PATH or build it from source with cargo.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File make-package.ps1 -LegibleExe C:\Users\me\.cargo\bin\legible.exe -Zip

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File make-package.ps1 -Out C:\dist\lc
#>

[CmdletBinding()]
param(
  [string]$Out = '',
  [string]$Name = 'legible-coder-setup',
  [string]$LegibleExe = '',
  [string]$SourceDir = '',
  [switch]$Zip,
  [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Warnings = New-Object System.Collections.Generic.List[string]

function Write-Step([string]$msg) { Write-Host ''; Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg) { Write-Host "    [ok] $msg" -ForegroundColor Green }
function Write-Info([string]$msg) { Write-Host "    $msg" }
function Write-Warn2([string]$msg) { Write-Host "    [warn] $msg" -ForegroundColor Yellow; $script:Warnings.Add($msg) | Out-Null }
function Stop-Package([string]$msg) { Write-Host "    [error] $msg" -ForegroundColor Red; exit 1 }

function Get-RequiredModules([string]$root) {
  $names = New-Object System.Collections.Generic.List[string]
  $names.Add('coder') | Out-Null
  $entry = Join-Path $root 'coder.lbl'
  if (Test-Path $entry) {
    Get-Content $entry | ForEach-Object {
      if ($_ -match '^\s*use\s+([A-Za-z_][A-Za-z0-9_]*)\s*$') {
        $m = $Matches[1]
        if (-not $names.Contains($m)) { $names.Add($m) | Out-Null }
      }
    }
  }
  return $names
}

function Find-RepoRoot {
  if ($SourceDir -ne '') {
    if (Test-Path (Join-Path $SourceDir 'coder.lbl')) { return (Resolve-Path $SourceDir).Path }
    Stop-Package "-SourceDir does not contain coder.lbl: $SourceDir"
  }
  $parent = Split-Path $PSScriptRoot -Parent
  if (Test-Path (Join-Path $parent 'coder.lbl')) { return $parent }
  if (Test-Path (Join-Path $PSScriptRoot 'coder.lbl')) { return $PSScriptRoot }
  Stop-Package 'Could not find coder.lbl. Run make-package.ps1 from the legible-coder repository.'
  return $null
}

function Find-LocalInterpreter {
  if ($LegibleExe -ne '') {
    if (-not (Test-Path $LegibleExe)) { Stop-Package "-LegibleExe does not exist: $LegibleExe" }
    return (Resolve-Path $LegibleExe).Path
  }
  $cmd = Get-Command legible.exe -ErrorAction SilentlyContinue
  if ($null -ne $cmd) { return $cmd.Source }
  $guess = Join-Path $env:USERPROFILE '.cargo\bin\legible.exe'
  if (Test-Path $guess) { return $guess }
  return $null
}

function main {
  Write-Host ''
  Write-Host '  legible-coder package builder' -ForegroundColor White
  Write-Host '  ----------------------------'

  $repo = Find-RepoRoot
  Write-Host ''
  Write-Info "Repo      : $repo"

  if ($Out -eq '') { $Out = Join-Path $env:TEMP $Name }
  $Out = [Environment]::ExpandEnvironmentVariables($Out)
  if (-not [IO.Path]::IsPathRooted($Out)) { $Out = Join-Path (Get-Location).Path $Out }
  Write-Info "Package   : $Out"

  if ((Test-Path $Out) -and -not $Force) {
    Stop-Package "$Out already exists. Pass -Force to overwrite it."
  }
  if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }

  Write-Step 'Copying the installer scripts'
  New-Item -ItemType Directory -Path $Out -Force | Out-Null
  $scripts = @('install.ps1', 'install.cmd', 'uninstall.ps1', 'uninstall.cmd', 'make-package.ps1')
  foreach ($s in $scripts) {
    $src = Join-Path $PSScriptRoot $s
    if (Test-Path $src) { Copy-Item -Path $src -Destination (Join-Path $Out $s) -Force }
    else { Write-Warn2 "$s was not found and is missing from the package." }
  }
  Write-Ok ('Copied ' + (($scripts | Where-Object { Test-Path (Join-Path $Out $_) }) -join ', '))

  Write-Step 'Copying the application'
  $appDir = Join-Path $Out 'app'
  New-Item -ItemType Directory -Path $appDir -Force | Out-Null
  $modules = Get-RequiredModules $repo
  $copied = New-Object System.Collections.Generic.List[string]
  foreach ($m in $modules) {
    $src = Join-Path $repo "$m.lbl"
    if (-not (Test-Path $src)) { Write-Warn2 "Module '$m' is used by coder.lbl but $src was not found."; continue }
    Copy-Item -Path $src -Destination (Join-Path $appDir "$m.lbl") -Force
    $copied.Add("$m.lbl") | Out-Null
  }
  foreach ($extra in @('README.md', 'CLAUDE.md')) {
    $src = Join-Path $repo $extra
    if (Test-Path $src) { Copy-Item -Path $src -Destination (Join-Path $appDir $extra) -Force; $copied.Add($extra) | Out-Null }
  }
  Write-Ok ('Copied ' + ($copied -join ', '))

  Write-Step 'Bundling the interpreter'
  $exe = Find-LocalInterpreter
  if ($null -ne $exe) {
    $runtimeDir = Join-Path $Out 'runtime'
    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    Copy-Item -Path $exe -Destination (Join-Path $runtimeDir 'legible.exe') -Force
    $size = [Math]::Round((Get-Item (Join-Path $runtimeDir 'legible.exe')).Length / 1MB, 1)
    Write-Ok "Bundled $exe ($size MB) - the package installs offline"
    Write-Info 'The target machine still needs the VC++ 2015-2022 x64 runtime and Git for Windows;'
    Write-Info 'install.ps1 installs both via winget, or falls back to a direct download for the runtime.'
  } else {
    Write-Warn2 'No legible.exe found. The package has no bundled interpreter.'
    Write-Info 'On the target machine install.ps1 will use legible from PATH or build it from source with cargo.'
    Write-Info 'To bundle one, re-run with -LegibleExe <path to legible.exe>.'
  }

  $totalMB = [Math]::Round(((Get-ChildItem -Recurse -File $Out | Measure-Object -Property Length -Sum).Sum) / 1MB, 1)
  Write-Ok "Package ready: $Out ($totalMB MB)"

  if ($Zip) {
    Write-Step 'Creating the zip archive'
    $zipPath = "$Out.zip"
    if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
    Compress-Archive -Path (Join-Path $Out '*') -DestinationPath $zipPath -CompressionLevel Optimal
    $zipMB = [Math]::Round((Get-Item $zipPath).Length / 1MB, 1)
    Write-Ok "Wrote $zipPath ($zipMB MB)"
  }

  Write-Host ''
  Write-Host '  On the target machine' -ForegroundColor Green
  Write-Host '  ---------------------'
  Write-Host '    1. Copy the folder (or unzip it) anywhere, e.g. C:\Users\me\Downloads'
  Write-Host '    2. Double-click install.cmd, or run:'
  Write-Host '         powershell -ExecutionPolicy Bypass -File install.ps1'
  Write-Host '    3. Open a NEW terminal and run: legible-coder'
  Write-Host ''

  if ($script:Warnings.Count -gt 0) {
    Write-Host '  Warnings:' -ForegroundColor Yellow
    foreach ($w in $script:Warnings) { Write-Host "    - $w" -ForegroundColor Yellow }
    Write-Host ''
  }
}

main
