# Dev toolchain exclusion paths that actually matter

Antivirus real-time scanning on a developer machine costs the most in a handful of
specific directories. This is the list, with the reasoning, plus how to resolve each
path on *your* machine instead of trusting a hardcoded default.

Read [Antivirus exclusions that silently do nothing](antivirus-exclusions-that-do-nothing.md)
first — an exclusion scoped to the wrong protection component buys you nothing.

## Resolve paths from the tools, never from memory

Tools move their caches between versions and honour environment overrides. Ask them:

```powershell
pnpm store path                      # e.g. <LOCALAPPDATA>\pnpm\store\v11
npm config get cache                 # e.g. <LOCALAPPDATA>\npm-cache
composer config --global cache-dir
composer config --global home
go env GOMODCACHE GOCACHE
cargo --version; echo $env:CARGO_HOME
pip cache dir
```

Then exclude the **parent** of a versioned store (`...\pnpm\`, not
`...\pnpm\store\v11\`) so the rule survives the next store format bump.

## The list

### Package manager caches — biggest win

Thousands of small files, written and read constantly, all already-downloaded
artifacts.

```
<LOCALAPPDATA>\npm-cache\
<LOCALAPPDATA>\pnpm\
<LOCALAPPDATA>\Composer\          # composer cache-dir
<APPDATA>\Composer\               # composer home
<LOCALAPPDATA>\Yarn\
<USERPROFILE>\.cargo\
<USERPROFILE>\go\pkg\mod\
<LOCALAPPDATA>\pip\Cache\
```

### Language runtimes and CLIs

```
C:\Program Files\nodejs\
C:\Program Files\Git\              # covers git, bash, sh, git-lfs, the whole MSYS2 tree
C:\Program Files\GitHub CLI\
C:\ProgramData\ComposerSetup\
```

A single recursive rule on `C:\Program Files\Git\` covers `mingw64\bin`, `usr\bin`
and `cmd\` — roughly 50 executables and 80 DLLs. Listing them individually adds rules
the scanner must evaluate on every file access and changes nothing.

### Containers — the VHDX matters most

```
C:\Program Files\Docker\
C:\ProgramData\DockerDesktop\
<LOCALAPPDATA>\Docker\            # contains docker_data.vhdx and ext4.vhdx
<USERPROFILE>\.docker\
```

`<LOCALAPPDATA>\Docker\wsl\` holds multi-gigabyte virtual disks that change
constantly. Real-time scanning them is the classic cause of "Docker Desktop is slow
on Windows".

### IDEs — the indexes, and the install

JetBrains IDEs installed through Toolbox do **not** live under
`<LOCALAPPDATA>\JetBrains\`. That path holds caches, indexes and logs. The programs
are elsewhere:

```
<LOCALAPPDATA>\JetBrains\            # indexes and caches  <- the heavy one
<APPDATA>\JetBrains\                 # configuration
<LOCALAPPDATA>\Programs\<IdeName>\   # actual installation (Toolbox default)
C:\Program Files\JetBrains\
```

Excluding only the first two is a common half-fix. Discover the real install
directories from the Start Menu shortcuts, which is authoritative and avoids sweeping
in dozens of irrelevant helper binaries:

```powershell
$sh = New-Object -ComObject WScript.Shell
Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\JetBrains Toolbox" -Filter *.lnk |
    ForEach-Object {
        $target = $sh.CreateShortcut($_.FullName).TargetPath
        [pscustomobject]@{
            Launcher  = $target                                  # trusted application
            InstallDir = (Split-Path (Split-Path $target -Parent) -Parent) + '\'   # folder exclusion
        }
    }
```

VS Code equivalents:

```
<LOCALAPPDATA>\Programs\Microsoft VS Code\
<USERPROFILE>\.vscode\extensions\
```

### Local dev environment managers

Laravel Herd, XAMPP, Laragon and friends bundle PHP, nginx and node:

```
C:\Program Files\Herd\
<USERPROFILE>\.config\herd\
<APPDATA>\Herd\
```

The PHP binaries sit under `<USERPROFILE>\.config\herd\bin\php<version>\php.exe` —
one per installed version. Enumerate rather than hardcode:

```powershell
Get-ChildItem "$env:USERPROFILE\.config\herd\bin" -Filter php.exe -Recurse -Depth 2 |
    Select-Object -ExpandProperty FullName
```

### Windows servicing

Not a dev toolchain, but the same class of problem — see
[Windows Update 0x800f0922](windows-update-0x800f0922-cbs-source-modified.md):

```
C:\Windows\SoftwareDistribution\
C:\Windows\servicing\
C:\Windows\WinSxS\
C:\Windows\uus\
```

## Trusted applications, not just folders

Folder rules stop the file scanner. They do not stop the behaviour engine from
intercepting what a process *does*. Register the executables too:

```
C:\Program Files\Git\mingw64\bin\git.exe
C:\Program Files\Git\mingw64\bin\git-lfs.exe
C:\Program Files\Git\usr\bin\bash.exe
C:\Program Files\Git\usr\bin\sh.exe
C:\Program Files\GitHub CLI\gh.exe
C:\Program Files\nodejs\node.exe          # covers npm, npx, pnpm, corepack
<USERPROFILE>\.config\herd\bin\php*\php.exe
C:\Program Files\Docker\Docker\Docker Desktop.exe
C:\Program Files\Docker\Docker\resources\com.docker.backend.exe
C:\Program Files\Docker\Docker\resources\dockerd.exe
C:\Program Files\Docker\Docker\resources\bin\docker.exe
<LOCALAPPDATA>\Programs\<IdeName>\bin\<ide>64.exe
```

`node.exe` alone covers npm, npx, pnpm and corepack — they are all scripts executed
by that binary. Adding the `.cmd` and `.ps1` shims does nothing; they are not
processes.

Skip the long tail. Docker ships ~40 `cli-plugins` executables; the six core binaries
above account for the work.

## What to leave scanned

**Your source tree.** `vendor/`, `node_modules/` and friends are where third-party
code lands on your disk — exactly what real-time scanning is for. Excluding them is
the biggest speed win available and a genuine reduction in your defences.

If you decide the trade is worth it, make it deliberately and compensate elsewhere:
committed lockfiles, human review of dependency bumps, and no auto-merge for
dependency bot PRs.
