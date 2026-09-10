# Windows installer

Scripts that install `legible-coder` on a fresh Windows machine.

| File | Purpose |
|------|---------|
| `install.cmd` | Double-clickable bootstrap for `install.ps1` |
| `install.ps1` | Installs dependencies, the interpreter, the app files and the launcher |
| `uninstall.cmd` | Bootstrap for `uninstall.ps1` |
| `uninstall.ps1` | Removes the install folder and the user `PATH` entry |
| `make-package.ps1` | Builds a redistributable folder/zip, optionally bundling `legible.exe` |

## Quick start

```powershell
cd legible-coder\installer
powershell -ExecutionPolicy Bypass -File install.ps1
```

Then open a **new** terminal and run `legible-coder`.

## What the installer does

1. **VC++ 2015-2022 x64 runtime** — `legible.exe` imports `VCRUNTIME140.dll` and the
   UCRT. Installed with winget (`Microsoft.VCRedist.2015+.x64`), falling back to a
   direct download of `vc_redist.x64.exe` from `aka.ms`.
2. **Git for Windows** — the interpreter's `shell_exec` builtin runs `sh -c ...`, and
   `coder.lbl`'s `grep` / `read_dir_recursive` / `write_file` diff / `take_screenshot`
   base64 paths need the GNU coreutils in `Git\usr\bin`. Installed with winget
   (`Git.Git`). The launcher prepends that directory to `PATH` because
   `System32\find.exe` is a different program from `find(1)`.
3. **`legible.exe`** — `legible-lang` publishes no releases, so the interpreter comes
   from `runtime\legible.exe` in a package built by `make-package.ps1`, from `PATH`, or
   from a `cargo install` build of `Gummygamer/legible-lang` (branch `master`).
4. **App files** — `coder.lbl` plus every module named in its `use` lines
   (`kv_cache`, `turn_budget`), so `legible check coder.lbl` passes in the install
   directory. The interpreter is copied next to them, making the install
   self-contained.
5. **Launcher** — a generated `legible-coder.cmd` that resolves `APPDIR` from its own
   path, prefers the local `legible.exe`, and reports a clear error if either is
   missing.
6. **User PATH** — appended through the raw registry key so `REG_EXPAND_SZ` values are
   preserved, followed by a `WM_SETTINGCHANGE` broadcast.
7. **Smoke test** — runs `legible check coder.lbl` and a generated probe program that
   exercises `shell_exec`, `get_cwd`, `list_dir`, `is_dir`, `json_valid` and the
   coreutils. The probe avoids Legible's string pitfalls: there are no backslash
   escapes, `"{` starts an interpolation, and `shell_exec`'s `exit_code` is an integer
   that needs `to_text` before `++`.

SDL2 is not installed: the Windows build of `legible.exe` has no SDL2 import.

## Options

`install.ps1` accepts `-InstallDir`, `-LegibleExe`, `-SourceDir`, `-Runtime
auto|bundled|build|skip`, `-InstallToolchain`, `-SkipVcRedist`, `-SkipGit`,
`-SkipSmokeTest`, `-NoPath`, `-Force`, `-ApiKey`, `-GeminiApiKey`,
`-OpenRouterApiKey`, `-LangRepoUrl` and `-LangRepoRef`. Run
`Get-Help .\install.ps1 -Full` for details.

`uninstall.ps1` accepts `-InstallDir`, `-RemoveEnvVars`, `-RemoveDependencies` and
`-Force`.

## Building a package for a fresh machine

```powershell
powershell -ExecutionPolicy Bypass -File make-package.ps1 `
  -LegibleExe $env:USERPROFILE\.cargo\bin\legible.exe -Zip
```

Output layout:

```
legible-coder-setup/
  install.cmd  install.ps1  uninstall.cmd  uninstall.ps1  make-package.ps1
  app/           coder.lbl kv_cache.lbl turn_budget.lbl README.md CLAUDE.md
  runtime/       legible.exe          (only with -LegibleExe or a legible on PATH)
```

Copy it (or the zip) to the target machine and run `install.cmd`. Without a bundled
interpreter the target machine needs `legible` on `PATH`, or `-Runtime build` with
`-InstallToolchain` to build it from source.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1              # keeps API keys and dependencies
powershell -ExecutionPolicy Bypass -File uninstall.ps1 -RemoveEnvVars -RemoveDependencies
```
