# Windows Update fails with 0x800f0922 — `CBS_E_SOURCE_MODIFIED`

## Symptom

You power the machine on. Instead of booting, it sits on **"Working on updates"**,
reboots by itself two or three times, and eventually lands on the desktop many
minutes later. Nothing in the UI says an update failed. It happens again on the next
boot.

It reads like a machine that won't turn on. It isn't — it is an update install that
fails and rolls back, retrying on every boot.

## Diagnostic

Run all of these. Together they separate "update loop" from "real boot failure".

```powershell
# 1. Was there actually a crash, or just reboots?
Get-WinEvent -FilterHashtable @{LogName="System"; Id=41,1001,6008} -MaxEvents 20 -EA SilentlyContinue |
    Select-Object TimeCreated, Id

# 2. Reboot / shutdown timeline
Get-WinEvent -FilterHashtable @{LogName="System"; Id=1074,6005,6006; StartTime=(Get-Date).AddDays(-3)} |
    Select-Object TimeCreated, Id, @{n="Msg";e={($_.Message -split "`n")[0]}} |
    Format-Table -AutoSize -Wrap

# 3. What the update actually reported
Get-WinEvent -FilterHashtable @{LogName="Setup"; StartTime=(Get-Date).AddDays(-2)} |
    Select-Object TimeCreated, Id, @{n="Msg";e={($_.Message -split "`n")[0]}}

# 4. Boot duration trend (is this boot abnormal?)
Get-WinEvent -FilterHashtable @{LogName="Microsoft-Windows-Diagnostics-Performance/Operational"; Id=100} -MaxEvents 8 |
    Select-Object TimeCreated,
        @{n="BootMs";e={([xml]$_.ToXml()).Event.EventData.Data |
            Where-Object Name -eq "BootTime" | Select-Object -ExpandProperty "#text"}}
```

### Evidence you are in this scenario

Query 1 returns **nothing** — no `Kernel-Power 41`, no `BugCheck 1001`, no `6008`.
That rules out crashes, power loss and dirty shutdowns.

Query 2 shows several reboots in minutes, all triggered by the system, not by you:

```
15:02:52  1074  TrustedInstaller.exe started restart ... reason: Operating System: upgrade (planned)
15:03:37  6005  Event log service started
15:08:37  1074  TrustedInstaller.exe started restart ... reason: Operating System: upgrade (planned)
15:09:42  6005  Event log service started
15:11:52  1074  TrustedInstaller.exe started restart ... reason: Operating System: upgrade (planned)
```

Query 3 gives the failure:

```
Package KB5xxxxxx failed to be changed to the Installed state. Status: 0x800f0922.
```

## Finding the real cause

`0x800f0922` is a generic wrapper. The useful error is in the CBS log:

```powershell
Get-ChildItem C:\Windows\Logs\CBS\*.log |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 4 |
    Select-String -Pattern "0x800f09|CBS_E_|Failed to (install|resolve|perform)" |
    Select-Object -Last 40 |
    ForEach-Object { $_.Filename + ": " + $_.Line }
```

The line that matters looked like this:

```
CBS  Exec: Added modified marker file: ...\Windows11.0-KB5xxxxxx-x64\payload-modified.cbs
CBS  Modified marker file present in source package folder: \\?\C:\Windows\servicing\packages\
     [HRESULT = 0x800f0911 - CBS_E_SOURCE_MODIFIED]
```

`CBS_E_SOURCE_MODIFIED` means CBS detected that the update payload changed between
download and install. It refuses to install a package whose bytes no longer match
what it expects, then rolls back. Since the update stays pending, the next boot tries
again — that is the loop.

Two things cause it, and they are not mutually exclusive:

**1. Real-time antivirus touching the payload.** The scanner opens, locks, or
quarantines files inside `C:\Windows\SoftwareDistribution\Download\` while
`TiWorker.exe` is applying them. This is the most common cause on machines with
third-party AV.

**2. A dirty servicing state** left by an earlier interrupted install. Once the
`payload-modified` marker is written, every retry fails the same way, forever, with
no self-healing.

Supporting evidence for a broken update stack, if present:

```
Service "Update Orchestrator Service" terminated with error: %%2149884192   (0x80248020 — WU datastore corrupt)
Service "Windows Modules Installer" terminated with error: The file is already in use by another process.
```

## Fix

### Step 1 — reset the Windows Update caches

Renaming, not deleting, so it is reversible.

```powershell
$svc = "wuauserv","bits","cryptsvc","msiserver","usosvc"
$svc | ForEach-Object { Stop-Service $_ -Force -EA SilentlyContinue }

Rename-Item C:\Windows\SoftwareDistribution      SoftwareDistribution.old -Force
Rename-Item C:\Windows\System32\catroot2         catroot2.old             -Force

$svc | ForEach-Object { Start-Service $_ -EA SilentlyContinue }
```

To roll back: stop the same services, delete the newly created folders, rename the
`.old` ones back.

### Step 2 — repair the component store

```powershell
DISM /Online /Cleanup-Image /RestoreHealth /NoRestart
sfc /scannow
```

`DISM` is the one that matters for this failure — it rebuilds the servicing state
that holds the stale marker. Expect 10–40 minutes. `sfc` can take just as long again.

> While these run, the machine will be sluggish and may appear to freeze. `TiWorker.exe`
> saturates disk I/O, and if you have antivirus, it scans every file DISM touches.
> Check progress with `Get-Process TiWorker | Select-Object CPU` — rising CPU means it
> is still working, even when the console prints nothing.

### Step 3 — stop the antivirus from doing it again

See [Antivirus exclusions that silently do nothing](antivirus-exclusions-that-do-nothing.md).
The folders that matter:

```
C:\Windows\SoftwareDistribution\
C:\Windows\servicing\
C:\Windows\WinSxS\
C:\Windows\uus\
```

And these processes, as trusted applications:

```
C:\Windows\servicing\TrustedInstaller.exe
C:\Windows\System32\wuauclt.exe
C:\Windows\System32\UsoClient.exe
C:\Windows\uus\amd64\MoUsoCoreWorker.exe
C:\Windows\WinSxS\<servicingstack folder>\TiWorker.exe
```

`TiWorker.exe` lives in a **version-pinned** path that changes with every servicing
stack update. Find the live one instead of hardcoding it:

```powershell
Get-Process TiWorker | Select-Object -ExpandProperty Path
```

Note it is `servicingstack`, not `servicingcommon` — the `servicingcommon`,
`servicingstack-onecore`, `servicingstack-inetsrv` and `servicingstack-msg` folders
contain no executable.

### Step 4 — install the update manually

Rather than letting Windows Update retry on the next boot, download the `.msu` from
the [Microsoft Update Catalog](https://www.catalog.update.microsoft.com/) and install
it with the antivirus paused. A local installer does not depend on the WU cache that
already failed.

## Verifying the fix

```powershell
# Should report no corruption
DISM /Online /Cleanup-Image /ScanHealth

# Should be clean of new 0x800f errors after the next attempt
Get-WinEvent -FilterHashtable @{LogName="Setup"; StartTime=(Get-Date).AddHours(-1)} |
    Select-Object TimeCreated, Id, @{n="Msg";e={($_.Message -split "`n")[0]}}
```

The real confirmation is the build number moving:

```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" |
    Select-Object DisplayVersion, CurrentBuild, UBR
```

## What this is *not*

`0x800f0922` is also documented as "insufficient space in the System Reserved
partition". Check before assuming:

```powershell
Get-Volume | Select-Object DriveLetter, FileSystemLabel,
    @{n="FreeMB";e={[math]::Round($_.SizeRemaining/1MB)}}
```

If the `SYSTEM` volume has a few hundred MB free, that is not your problem. In the
case documented here it had 710 MB free and the OS volume had over 1 TB — space was
never the issue, and chasing it would have wasted the evening.
