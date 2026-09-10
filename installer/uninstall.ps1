<#
.SYNOPSIS
  Removes legible-coder from a Windows machine.

.DESCRIPTION
  Deletes the install folder, removes it from the user PATH, and optionally clears the
  provider API keys. Dependencies installed by install.ps1 (VC++ runtime, Git for Windows,
  Rust) are left alone unless -RemoveDependencies is passed.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File uninstall.ps1
#>

[CmdletBinding()]
param(
  [string]$InstallDir = '',
  [switch]$RemoveEnvVars,
  [switch]$RemoveDependencies,
  [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:App = 'legible-coder'

function Write-Step([string]$msg) { Write-Host ''; Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg) { Write-Host "    [ok] $msg" -ForegroundColor Green }
function Write-Info([string]$msg) { Write-Host "    $msg" }
function Write-Warn2([string]$msg) { Write-Host "    [warn] $msg" -ForegroundColor Yellow }

function Remove-FromUserPath([string]$dir) {
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
  if ($null -eq $key) { return $false }
  try {
    $raw = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($null -eq $raw) { return $false }
    $target = $dir.TrimEnd('\')
    $kept = @($raw -split ';' | Where-Object {
      $_ -ne '' -and
      ([Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -ine $target) -and
      ($_.TrimEnd('\') -ine $target)
    })
    $new = ($kept -join ';')
    if ($new -eq $raw) { return $false }
    $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
    try { $existing = $key.GetValueKind('Path'); if ($existing -eq [Microsoft.Win32.RegistryValueKind]::String) { $kind = [Microsoft.Win32.RegistryValueKind]::String } } catch { }
    if ($new -eq '') { $key.DeleteValue('Path', $false) } else { $key.SetValue('Path', $new, $kind) }
    return $true
  } finally { $key.Close() }
}

function main {
  Write-Host ''
  Write-Host '  legible-coder uninstaller' -ForegroundColor White
  Write-Host '  -------------------------'

  if ($InstallDir -eq '') { $InstallDir = Join-Path $env:LOCALAPPDATA "Programs\$script:App" }
  $InstallDir = [Environment]::ExpandEnvironmentVariables($InstallDir).TrimEnd('\')

  Write-Step "Removing $InstallDir"
  if (Test-Path $InstallDir) {
    if (-not $Force) {
      $answer = Read-Host "    Delete this folder and everything in it? [y/N]"
      if ($answer -notmatch '^[Yy]') { Write-Info 'Kept the folder.' }
      else {
        try { Remove-Item -Recurse -Force $InstallDir; Write-Ok 'Folder deleted' }
        catch { Write-Warn2 "Could not delete the folder: $($_.Exception.Message). Close any running legible-coder session and retry." }
      }
    } else {
      try { Remove-Item -Recurse -Force $InstallDir; Write-Ok 'Folder deleted' }
      catch { Write-Warn2 "Could not delete the folder: $($_.Exception.Message)" }
    }
  } else { Write-Info 'Folder was not present.' }

  Write-Step 'Cleaning the user PATH'
  if (Remove-FromUserPath $InstallDir) { Write-Ok "Removed $InstallDir from the user PATH" }
  else { Write-Info 'PATH entry was not present.' }

  if ($RemoveEnvVars) {
    Write-Step 'Removing API key environment variables'
    foreach ($n in @('OPENAI_API_KEY', 'DASHSCOPE_API_KEY', 'ALIBABA_TOKEN_PLAN_API_KEY', 'GEMINI_API_KEY', 'ORCAROUTER_API_KEY', 'NVIDIA_API_KEY', 'OPENROUTER_API_KEY', 'GROQ_API_KEY', 'LEGIBLE_CODER_API_KEY', 'LEGIBLE_CODER_BASE_URL', 'LEGIBLE_CODER_MODEL')) {
      $v = [Environment]::GetEnvironmentVariable($n, 'User')
      if ($null -ne $v) { [Environment]::SetEnvironmentVariable($n, $null, 'User'); Write-Ok "Cleared $n" }
    }
  } else { Write-Info 'API key environment variables were left in place (pass -RemoveEnvVars to clear them).' }

  if ($RemoveDependencies) {
    Write-Step 'Removing installed dependencies'
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($null -eq $winget) { Write-Warn2 'winget is not available; remove Git / VC++ runtime manually.' }
    else {
      foreach ($id in @('Git.Git', 'Microsoft.VCRedist.2015+.x64')) {
        Write-Info "winget uninstall $id"
        $p = Start-Process -FilePath $winget.Source -ArgumentList @('uninstall', '--id', $id, '--exact', '--silent') -NoNewWindow -Wait -PassThru
        if ($p.ExitCode -eq 0) { Write-Ok "Uninstalled $id" } else { Write-Info "$id was not installed by winget (exit $($p.ExitCode))." }
      }
    }
  } else { Write-Info 'Dependencies (Git, VC++ runtime, Rust) were left installed.' }

  Write-Host ''
  Write-Host '  Uninstall finished. Open a new terminal for the PATH change to apply.' -ForegroundColor Green
  Write-Host ''
}

main
