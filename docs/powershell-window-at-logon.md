# A PowerShell window opens at every logon

## Symptom

Every time you log in, a console window appears. Sometimes it flashes and vanishes,
sometimes it stays. You close it. Next logon, it is back.

Worse, if that window is running something you care about — a monitor, a sync script,
a watcher — **closing the window kills the script**, and you never notice.

## Diagnostic

Three places can start a program at logon. Check all three; the registry `Run` keys
are the ones people check first and are usually *not* the culprit for a bare console.

```powershell
# 1. Startup folders
Get-ChildItem ([Environment]::GetFolderPath('Startup')),
              ([Environment]::GetFolderPath('CommonStartup')) -Force

# 2. Registry Run keys
"HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
"HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce",
"HKLM:\Software\Microsoft\Windows\CurrentVersion\Run",
"HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run" |
ForEach-Object {
    if (Test-Path $_) {
        Write-Output "=== $_"
        Get-Item $_ | Select-Object -ExpandProperty Property |
            ForEach-Object { "$_ => " + (Get-ItemPropertyValue $args[0] $_) } -ArgumentList $_
    }
}

# 3. Scheduled tasks with a logon/boot trigger that run a shell  <-- usually this one
Get-ScheduledTask | Where-Object {
    $_.State -ne "Disabled" -and ($_.Triggers | Where-Object {
        $_.CimClass.CimClassName -in "MSFT_TaskLogonTrigger","MSFT_TaskBootTrigger" })
} | ForEach-Object {
    $t = $_
    $t.Actions | Where-Object { $_.Execute -match "powershell|pwsh|cmd|wt\.exe|conhost" } |
        ForEach-Object { "$($t.TaskPath)$($t.TaskName) | $($_.Execute) $($_.Arguments)" }
}
```

Then inspect the suspect task:

```powershell
$t = Get-ScheduledTask -TaskName "YourTask"
"Hidden={0} RunLevel={1} LogonType={2} UserId={3}" -f `
    $t.Settings.Hidden, $t.Principal.RunLevel, $t.Principal.LogonType, $t.Principal.UserId
Get-ScheduledTaskInfo -TaskName "YourTask" | Select-Object LastRunTime, LastTaskResult
```

### Reading the evidence

```
Hidden=False  RunLevel=Limited  LogonType=Interactive  UserId=<user>
LastRunTime=... LastTaskResult=3221225786
```

Two things to notice.

`LogonType=Interactive` is the cause. **`-WindowStyle Hidden` does not prevent the
window.** Task Scheduler creates the `conhost` window before PowerShell ever parses
that argument, so an interactive task always paints a console — briefly at minimum.

The `Hidden` setting on the task is a red herring: it hides the task from the Task
Scheduler *list*, not the window.

`LastTaskResult=3221225786` is `0xC000013A` — `STATUS_CONTROL_C_EXIT`. That is the
process being terminated by a console close or Ctrl+C. In plain terms: **someone
closed the window, and the script died with it.** If your task is a monitor, this is
why its log always stops seconds after logon.

## Fix

Run the task outside the interactive session with **S4U** (*"Run whether user is
logged on or not"*, without storing a password):

```powershell
$p = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$env:USERNAME" `
                                -LogonType S4U -RunLevel Limited
Set-ScheduledTask -TaskName "YourTask" -Principal $p
```

S4U runs in session 0, which has no desktop — no window can appear, and no user
action can accidentally kill it.

Verify:

```powershell
Start-ScheduledTask -TaskName "YourTask"
Start-Sleep 5
Get-Process powershell | Select-Object Id, MainWindowHandle, StartTime
```

`MainWindowHandle = 0` means no window. That is what you want.

### Trade-offs of S4U

Not free. An S4U task:

- has **no access to mapped network drives** or the interactive desktop
- **cannot show UI** — no message boxes, no prompts, no GUI automation
- still runs under your user account and your profile paths, so `$env:USERPROFILE`
  and per-user config keep working

For a logging or monitoring script it is ideal. For anything that must draw on screen
or reach a mapped drive, use a different approach.

### Alternatives

If the task genuinely needs the interactive session, wrap the command in a headless
console host instead:

```
conhost.exe --headless powershell.exe -NoProfile -File "C:\path\to\script.ps1"
```

And if you simply don't need the task any more:

```powershell
Disable-ScheduledTask -TaskName "YourTask"
```

## Related trap

If the window you're seeing is a full terminal application rather than a bare blue
console — Windows Terminal, Warp, Hyper — it is probably a registry `Run` entry for
that app, not a scheduled task. Those legitimately open a shell, and the fix is to
remove the `Run` entry or turn off the app's "launch at startup" setting.

Check what a running console actually belongs to:

```powershell
Get-CimInstance Win32_Process |
    Where-Object { $_.Name -eq "powershell.exe" } |
    Select-Object ProcessId, ParentProcessId, CommandLine | Format-List
```

The parent process tells you who spawned it.
