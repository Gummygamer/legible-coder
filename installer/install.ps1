<#
.SYNOPSIS
  Installs legible-coder on a Windows machine.

.DESCRIPTION
  legible-coder is a single Legible program (coder.lbl) plus its modules, executed by the
  Legible interpreter (legible.exe). A fresh Windows box needs four things:

    1. legible.exe            - the interpreter. No GitHub releases exist for
                                Gummygamer/legible-lang, so it is either bundled inside the
                                installer package (runtime\legible.exe) or built from
                                source with cargo.
    2. VC++ 2015-2022 x64 CRT - legible.exe imports VCRUNTIME140.dll and the UCRT.
    3. Git for Windows        - the interpreter's shell_exec builtin runs "sh -c ...", and
                                coder.lbl's grep / read_dir_recursive / diff / base64 tools
                                need the GNU coreutils that ship in Git\usr\bin.
    4. A folder on PATH       - holds the .lbl files, legible.exe and the launcher.

  SDL2 is NOT required: the Windows build of legible.exe has no SDL2.dll import.

  The interpreter is installed next to the .lbl files so the install is self-contained and
  removable by deleting one folder (see uninstall.ps1).

.PARAMETER InstallDir
  Target folder. Defaults to %LOCALAPPDATA%\Programs\legible-coder.

.PARAMETER LegibleExe
  Path to a prebuilt legible.exe to use instead of the bundled or source-built one.

.PARAMETER Runtime
  How to obtain legible.exe:
    auto    - bundled runtime\legible.exe, then PATH, then a source build (default)
    bundled - only use runtime\legible.exe from the installer package (offline friendly)
    build   - clone Gummygamer/legible-lang and cargo install it
    skip    - do not install an interpreter (assume it is already on PATH)

.PARAMETER InstallToolchain
  Allow installing rustup and the MSVC C++ build tools via winget when a source build is
  requested and cargo is missing.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1 -Runtime build -InstallToolchain

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1 -ApiKey sk-your-qwen-key
#>

[CmdletBinding()]
param(
  [string]$InstallDir = '',
  [string]$LegibleExe = '',
  [string]$SourceDir = '',
  [string]$RepoUrl = 'https://github.com/Gummygamer/legible-coder.git',
  [string]$LangRepoUrl = 'https://github.com/Gummygamer/legible-lang.git',
  [string]$LangRepoRef = 'master',
  [ValidateSet('auto', 'bundled', 'build', 'skip')][string]$Runtime = 'auto',
  [switch]$InstallToolchain,
  [switch]$SkipVcRedist,
  [switch]$SkipGit,
  [switch]$SkipSmokeTest,
  [switch]$NoPath,
  [switch]$Force,
  [string]$ApiKey = '',
  [string]$GeminiApiKey = '',
  [string]$OpenRouterApiKey = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$script:App = 'legible-coder'
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:Notes = New-Object System.Collections.Generic.List[string]

# --------------------------------------------------------------------------- output

function Write-Step([string]$msg) { Write-Host ''; Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg) { Write-Host "    [ok] $msg" -ForegroundColor Green }
function Write-Info([string]$msg) { Write-Host "    $msg" }
function Write-Warn2([string]$msg) {
  Write-Host "    [warn] $msg" -ForegroundColor Yellow
  $script:Warnings.Add($msg) | Out-Null
}
function Write-Note([string]$msg) { $script:Notes.Add($msg) | Out-Null }
function Write-Err2([string]$msg) { Write-Host "    [error] $msg" -ForegroundColor Red }

function Stop-Install([string]$msg) {
  Write-Err2 $msg
  Write-Host ''
  Write-Host 'Installation did not complete.' -ForegroundColor Red
  exit 1
}

# ------------------------------------------------------------------- environment

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Winget {
  $w = Get-Command winget -ErrorAction SilentlyContinue
  if ($null -eq $w) { return $null }
  return $w.Source
}

function Invoke-WingetInstall([string]$id, [string]$override) {
  $winget = Get-Winget
  if ($null -eq $winget) { return $false }
  $argList = @('install', '--id', $id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements')
  if ($override -ne '') { $argList += @('--override', $override) }
  Write-Info "winget install $id"
  $p = Start-Process -FilePath $winget -ArgumentList $argList -NoNewWindow -Wait -PassThru
  # 0x8A15002B (-1978335189) means the package is already installed
  return ($p.ExitCode -eq 0 -or $p.ExitCode -eq -1978335189)
}

function Update-SessionPath {
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = "$machine;$user"
}

function Broadcast-PathChange {
  try {
    Add-Type -Namespace Win32 -Name Native -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)] public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);'
    $result = [UIntPtr]::Zero
    [Win32.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result) | Out-Null
  } catch { Write-Info 'Could not broadcast the environment change; new terminals will still pick it up.' }
}

function Add-ToUserPath([string]$dir) {
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
  if ($null -eq $key) { return $false }
  try {
    $raw = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($null -eq $raw) { $raw = '' }
    $target = $dir.TrimEnd('\')
    $parts = @($raw -split ';' | Where-Object { $_ -ne '' })
    foreach ($p in $parts) {
      $expanded = [Environment]::ExpandEnvironmentVariables($p).TrimEnd('\')
      if ($expanded -ieq $target -or $p.TrimEnd('\') -ieq $target) { return $false }
    }
    $new = (($parts + $target) -join ';')
    $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
    try { $existing = $key.GetValueKind('Path'); if ($existing -eq [Microsoft.Win32.RegistryValueKind]::String) { $kind = [Microsoft.Win32.RegistryValueKind]::String } } catch { }
    $key.SetValue('Path', $new, $kind)
    return $true
  } finally { $key.Close() }
}

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

function Set-UserEnvVar([string]$name, [string]$value) {
  [Environment]::SetEnvironmentVariable($name, $value, 'User')
  Set-Item -Path "Env:$name" -Value $value
}

# ------------------------------------------------------------------ dependencies

function Find-GitPosixDir {
  $roots = @(
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    (Join-Path $env:LOCALAPPDATA 'Programs')
  )
  foreach ($root in $roots) {
    if (-not $root) { continue }
    foreach ($sub in @('Git\usr\bin', 'Git\bin')) {
      $c = Join-Path $root $sub
      if (Test-Path (Join-Path $c 'sh.exe')) { return $c }
    }
  }
  $cmd = Get-Command sh.exe -ErrorAction SilentlyContinue
  if ($null -ne $cmd) { return (Split-Path $cmd.Source -Parent) }
  return $null
}

function Test-VcRuntime {
  $sys32 = Join-Path $env:SystemRoot 'System32'
  $hasRuntime = (Test-Path (Join-Path $sys32 'vcruntime140.dll')) -and (Test-Path (Join-Path $sys32 'msvcp140.dll'))
  if ($hasRuntime) { return $true }
  # 64-bit DLLs are also reachable from SysWOW64 on some images
  $syswow = Join-Path $env:SystemRoot 'SysWOW64'
  if ((Test-Path (Join-Path $syswow 'vcruntime140.dll')) -and (Test-Path (Join-Path $syswow 'msvcp140.dll'))) { return $true }
  return $false
}

function Install-VcRedist {
  Write-Step 'Checking the Visual C++ runtime'
  if (Test-VcRuntime) { Write-Ok 'VC++ 2015-2022 x64 runtime already present'; return }
  Write-Info 'legible.exe imports VCRUNTIME140.dll and the UCRT, which are not on a clean Windows image.'
  if (Invoke-WingetInstall 'Microsoft.VCRedist.2015+.x64' '') {
    if (Test-VcRuntime) { Write-Ok 'Installed the VC++ redistributable via winget'; return }
  }
  $tmp = Join-Path $env:TEMP 'vc_redist.x64.exe'
  try {
    Write-Info 'Downloading vc_redist.x64.exe from Microsoft ...'
    Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile $tmp -UseBasicParsing
    $p = Start-Process -FilePath $tmp -ArgumentList @('/install', '/quiet', '/norestart') -Wait -PassThru
    if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) { Write-Ok 'Installed the VC++ redistributable'; return }
    Write-Warn2 "vc_redist exited with code $($p.ExitCode). Run it manually: $tmp"
  } catch {
    Write-Warn2 "Could not install the VC++ runtime automatically: $($_.Exception.Message)"
    Write-Note 'Install "Microsoft Visual C++ 2015-2022 Redistributable (x64)" manually, then re-run the installer.'
  }
}

function Install-Git {
  Write-Step 'Checking for Git for Windows (sh.exe and the GNU coreutils)'
  $posix = Find-GitPosixDir
  if ($null -ne $posix) { Write-Ok "Found POSIX tools at $posix"; return $posix }
  Write-Info 'The interpreter runs shell_exec through "sh -c", and coder.lbl uses grep/find/head/sort/diff/base64.'
  if (-not (Invoke-WingetInstall 'Git.Git' '')) {
    Write-Warn2 'Could not install Git for Windows via winget.'
    Write-Note 'Install Git for Windows (https://git-scm.com/download/win), then re-run the installer.'
    return $null
  }
  Update-SessionPath
  $posix = Find-GitPosixDir
  if ($null -ne $posix) { Write-Ok "Installed Git for Windows; POSIX tools at $posix" }
  else { Write-Warn2 'Git was installed but sh.exe was not found. Open a new terminal and re-run the installer.' }
  return $posix
}

# ------------------------------------------------------------------- interpreter

function Find-LegibleOnPath {
  $cmd = Get-Command legible.exe -ErrorAction SilentlyContinue
  if ($null -eq $cmd) { $cmd = Get-Command legible -ErrorAction SilentlyContinue }
  if ($null -eq $cmd) { return $null }
  return $cmd.Source
}

function Test-LegibleWorks([string]$exe) {
  if (-not (Test-Path $exe)) { return $false }
  $outFile = Join-Path $env:TEMP 'lc_ver.txt'
  $errFile = Join-Path $env:TEMP 'lc_ver_err.txt'
  try {
    $p = Start-Process -FilePath $exe -ArgumentList @('--version') -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    return ($p.ExitCode -eq 0)
  } catch { return $false }
}

function Install-RustToolchain {
  Write-Info 'Installing the Rust toolchain (rustup) ...'
  if (-not (Invoke-WingetInstall 'Rustlang.Rustup' '')) {
    Write-Warn2 'Could not install rustup via winget. Install it from https://rustup.rs.'
    return $false
  }
  Update-SessionPath
  if (-not (Test-Path (Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'))) {
    Write-Warn2 'rustup installed but cargo.exe was not found. Open a new terminal and re-run.'
    return $false
  }
  # rustup links with MSVC, which needs the VC toolset.
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  $hasVc = $false
  if (Test-Path $vswhere) {
    $found = & $vswhere -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if ($found) { $hasVc = $true }
  }
  if (-not $hasVc) {
    Write-Info 'Installing the MSVC C++ build tools (required to link legible.exe) ...'
    $null = Invoke-WingetInstall 'Microsoft.VisualStudio.2022.BuildTools' '--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
    Update-SessionPath
  }
  return $true
}

function Get-CargoExe {
  $cmd = Get-Command cargo -ErrorAction SilentlyContinue
  if ($null -ne $cmd) { return $cmd.Source }
  $guess = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
  if (Test-Path $guess) { return $guess }
  return $null
}

function Build-LegibleFromSource([string]$workRoot) {
  Write-Step 'Building the Legible interpreter from source'
  $cargoExe = Get-CargoExe
  if ($null -eq $cargoExe) {
    if (-not $InstallToolchain) {
      Write-Warn2 'cargo was not found. Pass -InstallToolchain to let the installer set up Rust, or -LegibleExe <path> to supply a prebuilt legible.exe.'
      return $null
    }
    if (-not (Install-RustToolchain)) { return $null }
    $cargoExe = Get-CargoExe
    if ($null -eq $cargoExe) { Write-Warn2 'Rust was installed but cargo is still not on PATH. Open a new terminal and re-run the installer.'; return $null }
  }
  Write-Ok "Using $cargoExe"

  $git = Get-Command git -ErrorAction SilentlyContinue
  if ($null -eq $git) { Write-Warn2 'git is required to clone the interpreter source. Install Git for Windows and re-run.'; return $null }

  $clone = Join-Path $workRoot 'legible-lang'
  if (Test-Path $clone) { Remove-Item -Recurse -Force $clone }
  Write-Info "Cloning $LangRepoUrl ($LangRepoRef) ..."
  & $git.Source clone --depth 1 --branch $LangRepoRef $LangRepoUrl $clone 2>&1 | ForEach-Object { Write-Info "    $_" }
  if (-not (Test-Path (Join-Path $clone 'Cargo.toml'))) { Write-Warn2 'Clone failed: Cargo.toml was not found.'; return $null }

  # The sdl2 crate links the SDL2 development libraries unless it is built bundled.
  # Try a plain build first, then a statically bundled SDL2 build.
  $attempts = @(
    @{ Name = 'default'; Extra = @(); Tag = 'default' },
    @{ Name = 'bundled SDL2'; Extra = @('--features', 'sdl2/bundled'); Tag = 'bundled' }
  )
  foreach ($a in $attempts) {
    Write-Info "cargo install --path . --locked ($($a.Name)) - this can take several minutes ..."
    $cargoArgs = @('install', '--path', $clone, '--locked', '--force') + $a.Extra
    $log = Join-Path $workRoot "cargo-$($a.Tag).log"
    $p = Start-Process -FilePath $cargoExe -ArgumentList $cargoArgs -NoNewWindow -Wait -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    if ($p.ExitCode -eq 0) {
      $built = Join-Path $env:USERPROFILE '.cargo\bin\legible.exe'
      if (Test-Path $built) { Write-Ok "Built $built"; return $built }
      Write-Warn2 'cargo install succeeded but legible.exe was not found in %USERPROFILE%\.cargo\bin.'
      return $null
    }
    Write-Info "Build attempt '$($a.Name)' failed (exit $($p.ExitCode)). Log: $log"
    if (Test-Path "$log.err") { Get-Content "$log.err" -Tail 12 | ForEach-Object { Write-Info "    $_" } }
  }
  Write-Warn2 'Could not build legible.exe from source.'
  Write-Note 'If the build failed on SDL2, install the SDL2 and SDL2_ttf development libraries (vcpkg install sdl2 sdl2-ttf), then re-run with -Runtime build.'
  return $null
}

function Resolve-Legible([string]$packageRoot, [string]$workRoot) {
  Write-Step 'Locating the Legible interpreter (legible.exe)'

  if ($LegibleExe -ne '') {
    if (-not (Test-Path $LegibleExe)) { Stop-Install "-LegibleExe path does not exist: $LegibleExe" }
    Write-Ok "Using the supplied interpreter: $LegibleExe"
    return (Resolve-Path $LegibleExe).Path
  }

  $bundled = Join-Path $packageRoot 'runtime\legible.exe'
  if ($Runtime -eq 'bundled' -or $Runtime -eq 'auto') {
    if (Test-Path $bundled) {
      Write-Ok "Using the interpreter bundled with this installer: $bundled"
      return $bundled
    }
    if ($Runtime -eq 'bundled') { Stop-Install "No bundled interpreter at $bundled. Re-run make-package.ps1, or use -Runtime build / -LegibleExe." }
  }

  if ($Runtime -eq 'auto' -or $Runtime -eq 'skip') {
    $onPath = Find-LegibleOnPath
    if ($null -ne $onPath -and (Test-LegibleWorks $onPath)) { Write-Ok "Using the interpreter already on PATH: $onPath"; return $onPath }
    $guess = Join-Path $env:USERPROFILE '.cargo\bin\legible.exe'
    if ((Test-Path $guess) -and (Test-LegibleWorks $guess)) { Write-Ok "Using $guess"; return $guess }
  }

  if ($Runtime -eq 'skip') {
    Write-Warn2 'No interpreter was found and -Runtime skip was requested. legible-coder will not start until legible.exe is on PATH.'
    return $null
  }

  return (Build-LegibleFromSource $workRoot)
}

# --------------------------------------------------------------------- app files

function Find-SourceRoot {
  if ($SourceDir -ne '') {
    if (Test-Path (Join-Path $SourceDir 'coder.lbl')) { return (Resolve-Path $SourceDir).Path }
    Stop-Install "-SourceDir does not contain coder.lbl: $SourceDir"
  }
  # Package layout: install.ps1 sits next to app\coder.lbl
  $packaged = Join-Path $PSScriptRoot 'app\coder.lbl'
  if (Test-Path $packaged) { return (Join-Path $PSScriptRoot 'app') }
  # Repo layout: install.ps1 sits in installer\, sources in the parent folder
  $repo = Join-Path (Split-Path $PSScriptRoot -Parent) 'coder.lbl'
  if (Test-Path $repo) { return (Split-Path $PSScriptRoot -Parent) }
  Stop-Install 'Could not find coder.lbl. Run this script from the installer package or the legible-coder repository.'
  return $null
}

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

function New-Launcher([string]$target) {
  $body = @'
@echo off
setlocal EnableExtensions

rem legible-coder launcher. Written by install.ps1 - do not edit by hand.
rem The Legible interpreter runs shell_exec through "sh -c", and coder.lbl uses
rem grep / find / head / sort / diff / base64, so Git's POSIX tools go first on
rem PATH. Order matters: System32\find.exe is a different program.

set "APPDIR=%~dp0"
if "%APPDIR:~-1%"=="\" set "APPDIR=%APPDIR:~0,-1%"

set "GITPOSIX="
if exist "%ProgramFiles%\Git\usr\bin\sh.exe" set "GITPOSIX=%ProgramFiles%\Git\usr\bin"
if not defined GITPOSIX if exist "%ProgramFiles(x86)%\Git\usr\bin\sh.exe" set "GITPOSIX=%ProgramFiles(x86)%\Git\usr\bin"
if not defined GITPOSIX if exist "%LOCALAPPDATA%\Programs\Git\usr\bin\sh.exe" set "GITPOSIX=%LOCALAPPDATA%\Programs\Git\usr\bin"
if not defined GITPOSIX if exist "%ProgramFiles%\Git\bin\sh.exe" set "GITPOSIX=%ProgramFiles%\Git\bin"
if not defined GITPOSIX if exist "%LOCALAPPDATA%\Programs\Git\bin\sh.exe" set "GITPOSIX=%LOCALAPPDATA%\Programs\Git\bin"
if defined GITPOSIX set "PATH=%GITPOSIX%;%PATH%"

if not exist "%APPDIR%\coder.lbl" (
  echo legible-coder: coder.lbl is missing from "%APPDIR%". 1>&2
  echo Re-run install.ps1 to repair the installation. 1>&2
  exit /b 1
)

set "LEGIBLE_EXE=%APPDIR%\legible.exe"
if not exist "%LEGIBLE_EXE%" (
  where legible >nul 2>nul
  if errorlevel 1 (
    echo legible-coder: legible.exe was not found in "%APPDIR%" or on PATH. 1>&2
    echo Re-run install.ps1, or pass -LegibleExe with the path to legible.exe. 1>&2
    exit /b 1
  )
  set "LEGIBLE_EXE=legible"
)

"%LEGIBLE_EXE%" run "%APPDIR%\coder.lbl" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
'@
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($target, ($body -replace "`r?`n", "`r`n"), $enc)
}

function Install-AppFiles([string]$root, [string]$target) {
  Write-Step 'Installing legible-coder'
  if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }

  $modules = Get-RequiredModules $root
  $copied = New-Object System.Collections.Generic.List[string]
  foreach ($m in $modules) {
    $src = Join-Path $root "$m.lbl"
    if (-not (Test-Path $src)) { Write-Warn2 "Module '$m' is used by coder.lbl but $src was not found."; continue }
    Copy-Item -Path $src -Destination (Join-Path $target "$m.lbl") -Force
    $copied.Add("$m.lbl") | Out-Null
  }
  foreach ($extra in @('README.md', 'CLAUDE.md')) {
    $src = Join-Path $root $extra
    if (Test-Path $src) { Copy-Item -Path $src -Destination (Join-Path $target $extra) -Force }
  }
  Write-Ok ("Copied " + ($copied -join ', ') + " to $target")

  New-Launcher (Join-Path $target 'legible-coder.cmd')
  Write-Ok 'Wrote the legible-coder.cmd launcher'
  return $copied
}

# -------------------------------------------------------------------- smoke test

function New-ProbeSource {
  # Legible has no backslash escapes and treats "{" as interpolation, so JSON in the
  # probe is built with json_encode instead of a literal, and shell_exec's exit_code
  # is an integer that needs to_text before concatenation.
  $lines = @(
    'function main(): nothing',
    '  intent: verify the interpreter builtins that legible coder needs',
    '  let out: a mapping from text to text = shell_exec("echo shell-exec-ok")',
    '  print("shell_exec: " ++ trim(get(out, "stdout")))',
    '  print("exit_code: " ++ to_text(get(out, "exit_code")))',
    '  print("cwd: " ++ get_cwd())',
    '  print("json: " ++ to_text(json_valid(json_encode({"a": "b"}))))',
    '  print("grep: " ++ trim(get(shell_exec("grep --version | head -1"), "stdout")))',
    '  print("find: " ++ trim(get(shell_exec("find . -maxdepth 1 -type f | sort | head -2"), "stdout")))',
    '  print("list_dir: " ++ to_text(length(list_dir("."))))',
    '  print("is_dir: " ++ to_text(is_dir(".")))',
    'end'
  )
  return ($lines -join "`r`n") + "`r`n"
}

function Invoke-SmokeTest([string]$target, [string]$legibleExe, [string]$posixDir) {
  Write-Step 'Running the install smoke test'
  $savedPath = $env:Path
  if ($posixDir -ne '' -and $null -ne $posixDir) { $env:Path = "$posixDir;$savedPath" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  $checkLog = Join-Path $env:TEMP 'lc_check.log'
  $probe = Join-Path $env:TEMP 'lc_probe.lbl'
  $probeLog = Join-Path $env:TEMP 'lc_probe.log'
  try {
    # 1. The assistant and its modules must type-check from the install directory, which
    #    also proves the "use kv_cache" / "use turn_budget" modules were installed.
    $p = Start-Process -FilePath $legibleExe -ArgumentList @('check', (Join-Path $target 'coder.lbl')) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $checkLog -RedirectStandardError "$checkLog.err"
    if ($p.ExitCode -ne 0) {
      $detail = ''
      if (Test-Path "$checkLog.err") { $detail = (Get-Content "$checkLog.err" -Raw) }
      Write-Warn2 "legible check coder.lbl exited with $($p.ExitCode). $detail"
    } else { Write-Ok 'legible check coder.lbl: no errors' }

    # 2. The builtins coder.lbl depends on must work. shell_exec succeeding proves
    #    sh.exe and the GNU coreutils are reachable.
    [IO.File]::WriteAllText($probe, (New-ProbeSource), $enc)
    $p2 = Start-Process -FilePath $legibleExe -ArgumentList @('run', $probe) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $probeLog -RedirectStandardError "$probeLog.err"
    $out = ''
    if (Test-Path $probeLog) { $out = (Get-Content $probeLog -Raw) }
    if ($p2.ExitCode -eq 0 -and $out -match 'shell-exec-ok' -and $out -match 'GNU grep') {
      Write-Ok 'shell_exec, grep, find, json and the filesystem builtins all work'
      ($out.Trim() -split "`r?`n") | ForEach-Object { if ($_.Trim() -ne '') { Write-Info "  $_" } }
    } else {
      $detail = ''
      if (Test-Path "$probeLog.err") { $detail = (Get-Content "$probeLog.err" -Raw) }
      Write-Warn2 "The builtin probe failed (exit $($p2.ExitCode)). $detail"
      Write-Note 'shell_exec needs sh.exe plus grep and find on PATH. Install Git for Windows and re-run the installer.'
    }
  } finally {
    $env:Path = $savedPath
    Remove-Item $probe, $probeLog, "$probeLog.err", $checkLog, "$checkLog.err" -Force -ErrorAction SilentlyContinue
  }
}

# -------------------------------------------------------------------------- main

function main {
  Write-Host ''
  Write-Host '  legible-coder installer for Windows' -ForegroundColor White
  Write-Host '  -----------------------------------'

  if ([Environment]::OSVersion.Platform -ne 'Win32NT') { Stop-Install 'This installer only supports Windows NT.' }
  if (-not [Environment]::Is64BitOperatingSystem) { Stop-Install 'legible.exe is a 64-bit binary; 64-bit Windows is required.' }

  Write-Host ''
  Write-Info ("Running as " + $(if (Test-Admin) { 'administrator' } else { 'standard user (per-user install)' }))

  if ($InstallDir -eq '') { $InstallDir = Join-Path $env:LOCALAPPDATA "Programs\$script:App" }
  $InstallDir = [Environment]::ExpandEnvironmentVariables($InstallDir)
  if (-not [IO.Path]::IsPathRooted($InstallDir)) { $InstallDir = Join-Path (Get-Location).Path $InstallDir }
  $InstallDir = $InstallDir.TrimEnd('\')
  if (Test-Path $InstallDir) { Write-Info "An installation already exists at $InstallDir. Files will be replaced." }

  $sourceRoot = Find-SourceRoot
  Write-Info "Source files : $sourceRoot"
  Write-Info "Install dir  : $InstallDir"
  if ($RepoUrl -ne '') { Write-Info "Assistant repo: $RepoUrl (not needed when installing from local sources)" }

  $workRoot = Join-Path $env:TEMP ("lc-install-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

  try {
    if (-not $SkipVcRedist) { Install-VcRedist } else { Write-Info 'Skipping the VC++ runtime check (-SkipVcRedist).' }

    $posixDir = $null
    if (-not $SkipGit) { $posixDir = Install-Git } else { $posixDir = Find-GitPosixDir; Write-Info 'Skipping the Git check (-SkipGit).' }

    $legibleExe = Resolve-Legible $PSScriptRoot $workRoot

    $null = Install-AppFiles $sourceRoot $InstallDir

    if ($null -ne $legibleExe -and (Test-Path $legibleExe)) {
      Write-Step 'Installing the interpreter'
      $dest = Join-Path $InstallDir 'legible.exe'
      try {
        Copy-Item -Path $legibleExe -Destination $dest -Force
        Write-Ok "Copied legible.exe into $InstallDir (self-contained install)"
        $legibleExe = $dest
      } catch {
        Write-Warn2 "Could not copy legible.exe ($($_.Exception.Message)). The launcher will fall back to legible.exe on PATH."
      }
    }

    if (-not $NoPath) {
      Write-Step 'Adding legible-coder to your PATH'
      if (Add-ToUserPath $InstallDir) {
        Write-Ok "Added $InstallDir to the user PATH"
        Broadcast-PathChange
      } else {
        Write-Ok "$InstallDir is already on the user PATH"
      }
      Update-SessionPath
    } else { Write-Info 'Skipping the PATH update (-NoPath).' }

    Write-Step 'Configuring API keys'
    if ($ApiKey -ne '') { Set-UserEnvVar 'OPENAI_API_KEY' $ApiKey; Write-Ok 'Stored OPENAI_API_KEY (user scope)' }
    if ($GeminiApiKey -ne '') { Set-UserEnvVar 'GEMINI_API_KEY' $GeminiApiKey; Write-Ok 'Stored GEMINI_API_KEY (user scope)' }
    if ($OpenRouterApiKey -ne '') { Set-UserEnvVar 'OPENROUTER_API_KEY' $OpenRouterApiKey; Write-Ok 'Stored OPENROUTER_API_KEY (user scope)' }
    if ($ApiKey -eq '' -and $GeminiApiKey -eq '' -and $OpenRouterApiKey -eq '') {
      $keyNames = @('DASHSCOPE_API_KEY', 'ALIBABA_TOKEN_PLAN_API_KEY', 'OPENAI_API_KEY', 'GEMINI_API_KEY', 'ORCAROUTER_API_KEY', 'NVIDIA_API_KEY', 'OPENROUTER_API_KEY', 'GROQ_API_KEY')
      $haveKey = $false
      foreach ($n in $keyNames) {
        if ([Environment]::GetEnvironmentVariable($n, 'User') -or [Environment]::GetEnvironmentVariable($n, 'Machine')) {
          $haveKey = $true
          Write-Ok "Found $n"
          break
        }
      }
      if (-not $haveKey) {
        Write-Warn2 'No provider API key was found. legible-coder cannot call a model without one.'
        Write-Note 'Set a key with: [Environment]::SetEnvironmentVariable("OPENAI_API_KEY", "sk-...", "User")'
      }
    }

    if (-not $SkipSmokeTest) {
      if ($null -ne $legibleExe -and (Test-Path $legibleExe)) { Invoke-SmokeTest $InstallDir $legibleExe $posixDir }
      else { Write-Info 'Skipping the smoke test: no interpreter was installed.' }
    }

    Write-Host ''
    Write-Host '  Installation complete' -ForegroundColor Green
    Write-Host '  ---------------------'
    Write-Host "  Folder  : $InstallDir"
    Write-Host '  Command : legible-coder'
    Write-Host '  Web GUI : legible-coder --web   (http://localhost:8723)'
    Write-Host ''
    Write-Host '  Open a NEW terminal so the updated PATH is loaded, then run:' -ForegroundColor White
    Write-Host '      legible-coder'
    Write-Host ''

    if ($script:Warnings.Count -gt 0) {
      Write-Host '  Warnings:' -ForegroundColor Yellow
      foreach ($w in $script:Warnings) { Write-Host "    - $w" -ForegroundColor Yellow }
      Write-Host ''
    }
    if ($script:Notes.Count -gt 0) {
      Write-Host '  Next steps:' -ForegroundColor Yellow
      foreach ($n in $script:Notes) { Write-Host "    - $n" -ForegroundColor Yellow }
      Write-Host ''
    }
  } finally {
    Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue
  }
}

main
