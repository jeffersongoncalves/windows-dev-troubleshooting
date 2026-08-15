<#
.SYNOPSIS
    Read-only diagnostic collector for the windows-dev-troubleshooting catalog.

.DESCRIPTION
    Gathers the signals every guide in docs/ keys off, in one pass, and emits them as
    a single object. Changes nothing: no services stopped, no repairs started, no
    configuration written.

    Designed to be consumed by an AI agent. Field names match the `signal` paths in
    catalog.json.

.PARAMETER AsJson
    Emit JSON instead of a human-readable summary.

.PARAMETER Days
    Lookback window for event log queries. Default 30.

.EXAMPLE
    pwsh -File scripts/Get-WindowsHealthReport.ps1 -AsJson

.NOTES
    Some queries read the System event log and require an elevated session for
    complete results. The script degrades gracefully when not elevated: affected
    fields come back null and `elevated` is false. Report that rather than treating
    a null as a zero.
#>
[CmdletBinding()]
param(
    [switch] $AsJson,
    [int]    $Days = 30
)

$ErrorActionPreference = 'SilentlyContinue'
$since = (Get-Date).AddDays(-$Days)

function Get-EventsSafe {
    param([hashtable] $Filter, [int] $Max = 0)
    try {
        if ($Max -gt 0) { Get-WinEvent -FilterHashtable $Filter -MaxEvents $Max -EA Stop }
        else            { Get-WinEvent -FilterHashtable $Filter -EA Stop }
    } catch { @() }
}

# ---------------------------------------------------------------- context
$id       = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)

$osKey = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

# ---------------------------------------------------------------- crashes
$k41  = @(Get-EventsSafe @{ LogName='System'; Id=41;   StartTime=$since })
$bc   = @(Get-EventsSafe @{ LogName='System'; Id=1001; ProviderName='Microsoft-Windows-WER-SystemErrorReporting'; StartTime=$since })
$u608 = @(Get-EventsSafe @{ LogName='System'; Id=6008; StartTime=$since })

$crashes = [ordered]@{
    kernelPower41  = $k41.Count
    bugCheck1001   = $bc.Count
    unexpected6008 = $u608.Count
    lastKernelPower41 = if ($k41.Count) { $k41[0].TimeCreated.ToString('s') } else { $null }
}

# ---------------------------------------------------------------- windows update
$setup = @(Get-EventsSafe @{ LogName='Setup'; StartTime=$since })
$setupFail = @($setup | Where-Object { $_.Message -match '0x800f|failed to be changed' })

$reboots = @(Get-EventsSafe @{ LogName='System'; Id=1074; StartTime=$since } |
             Where-Object { $_.Message -match 'TrustedInstaller|MoUsoCoreWorker' })

$wuFail = @(Get-EventsSafe @{ LogName='System'; ProviderName='Microsoft-Windows-WindowsUpdateClient'; Id=20; StartTime=$since })

$lastCode = $null
if ($setupFail.Count) {
    $m = [regex]::Match(($setupFail[0].Message), '0x[0-9a-fA-F]{8}')
    if ($m.Success) { $lastCode = $m.Value }
}

$windowsUpdate = [ordered]@{
    setupFailures            = $setupFail.Count
    trustedInstallerReboots  = $reboots.Count
    wuClientInstallFailures  = $wuFail.Count
    lastFailureCode          = $lastCode
    lastFailureTime          = if ($setupFail.Count) { $setupFail[0].TimeCreated.ToString('s') } else { $null }
    rebootPendingCbs         = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    build                    = "$($osKey.CurrentBuild).$($osKey.UBR)"
    displayVersion           = $osKey.DisplayVersion
}

# ---------------------------------------------------------------- CBS log
$cbsHits = 0
$cbsSample = $null
Get-ChildItem 'C:\Windows\Logs\CBS\*.log' | Sort-Object LastWriteTime -Descending |
    Select-Object -First 4 |
    Select-String -Pattern 'CBS_E_SOURCE_MODIFIED|payload-modified|0x800f0911' |
    ForEach-Object { $cbsHits++; if (-not $cbsSample) { $cbsSample = $_.Line.Trim() } }

$cbs = [ordered]@{ sourceModifiedHits = $cbsHits; sample = $cbsSample }

# ---------------------------------------------------------------- WHEA
$whea = @(Get-EventsSafe @{ LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$since })
$w17  = @($whea | Where-Object Id -eq 17)

$byDay = $w17 | Group-Object { $_.TimeCreated.ToString('yyyy-MM-dd') }
$topDevice = $null
if ($w17.Count) {
    $topDevice = ($w17 | ForEach-Object {
        ([xml]$_.ToXml()).Event.EventData.Data |
            Where-Object Name -eq 'PrimaryDeviceName' | Select-Object -ExpandProperty '#text'
    } | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
}

$wheaOut = [ordered]@{
    # count over the -Days window; see report.lookbackDays for the window size
    id17                  = $w17.Count
    fatal18               = @($whea | Where-Object Id -eq 18).Count
    maxPerDay             = if ($byDay) { ($byDay | Measure-Object Count -Maximum).Maximum } else { 0 }
    lastEvent             = if ($w17.Count) { $w17[0].TimeCreated.ToString('s') } else { $null }
    topDevice             = $topDevice
}

# ---------------------------------------------------------------- storage
$storageEvents = @(Get-EventsSafe @{
    LogName='System'
    ProviderName='disk','storahci','stornvme','Ntfs','volmgr'
    StartTime=$since
})

$disks = @(Get-PhysicalDisk | ForEach-Object {
    [ordered]@{
        friendlyName      = $_.FriendlyName
        mediaType         = "$($_.MediaType)"
        busType           = "$($_.BusType)"
        healthStatus      = "$($_.HealthStatus)"
        operationalStatus = "$($_.OperationalStatus)"
    }
})

$storage = [ordered]@{ errorEvents = $storageEvents.Count; disks = $disks }

# ---------------------------------------------------------------- volumes
$sysRes = Get-Volume | Where-Object { $_.FileSystemLabel -eq 'SYSTEM' } | Select-Object -First 1
$volumes = [ordered]@{
    systemReservedFreeMB = if ($sysRes) { [math]::Round($sysRes.SizeRemaining / 1MB) } else { $null }
    osFreeGB             = [math]::Round((Get-Volume -DriveLetter C).SizeRemaining / 1GB, 1)
}

# ---------------------------------------------------------------- logon tasks running shells
$logonShellTasks = @()
Get-ScheduledTask | Where-Object {
    $_.State -ne 'Disabled' -and ($_.Triggers | Where-Object {
        $_.CimClass.CimClassName -in 'MSFT_TaskLogonTrigger','MSFT_TaskBootTrigger' })
} | ForEach-Object {
    $t = $_
    foreach ($a in $t.Actions) {
        if ($a.Execute -match 'powershell|pwsh|cmd\.exe|wt\.exe|conhost') {
            $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath
            $logonShellTasks += [ordered]@{
                task           = "$($t.TaskPath)$($t.TaskName)"
                execute        = $a.Execute
                arguments      = $a.Arguments
                logonType      = "$($t.Principal.LogonType)"
                runLevel       = "$($t.Principal.RunLevel)"
                userId         = if ($t.Principal.UserId -match 'SYSTEM|SISTEMA') { $t.Principal.UserId } else { '<user>' }
                lastTaskResult = $info.LastTaskResult
                killedByConsoleClose = ($info.LastTaskResult -eq 3221225786)
            }
        }
    }
}

# ---------------------------------------------------------------- run keys
$runKeys = @()
foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
               'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
               'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
    if (Test-Path $k) {
        foreach ($n in (Get-Item $k).Property) {
            $runKeys += [ordered]@{ hive = $k; name = $n; value = (Get-ItemPropertyValue $k $n) }
        }
    }
}

# ---------------------------------------------------------------- antivirus
$avProducts = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct |
                Select-Object -ExpandProperty displayName -Unique)
$thirdParty = @($avProducts | Where-Object { $_ -notmatch 'Windows Defender|Microsoft Defender' })

$antivirus = [ordered]@{
    products          = $avProducts
    thirdPartyPresent = ($thirdParty.Count -gt 0)
    thirdPartyNames   = $thirdParty
    # Reading exclusion scope requires a vendor-specific export (see docs). Null means
    # "not inspected", NOT "none found". Do not treat null as zero.
    exclusionsWithRestrictedScope = $null
    trustedAppsMissingOnDisk      = $null
}

# ---------------------------------------------------------------- current load
$tiWorker = Get-Process TiWorker | Select-Object -First 1
$topCpu = @(Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 |
            ForEach-Object { [ordered]@{ name = $_.ProcessName; cpuSeconds = [math]::Round($_.CPU) } })

$processes = [ordered]@{
    tiWorkerRunning     = [bool]$tiWorker
    tiWorkerCpuSeconds  = if ($tiWorker) { [math]::Round($tiWorker.CPU) } else { $null }
    tiWorkerPath        = if ($tiWorker) { $tiWorker.Path } else { $null }
    repairRunning       = [bool](Get-Process dism, sfc, DismHost)
    topCpu              = $topCpu
}

# ---------------------------------------------------------------- boot times
$boot = @(Get-EventsSafe @{ LogName='Microsoft-Windows-Diagnostics-Performance/Operational'; Id=100 } 8 |
    ForEach-Object {
        [ordered]@{
            time   = $_.TimeCreated.ToString('s')
            bootMs = [int](([xml]$_.ToXml()).Event.EventData.Data |
                        Where-Object Name -eq 'BootTime' | Select-Object -ExpandProperty '#text')
        }
    })

# ---------------------------------------------------------------- assemble
$report = [ordered]@{
    generatedAt   = (Get-Date).ToString('s')
    lookbackDays  = $Days
    elevated      = $elevated
    os            = [ordered]@{ product = $osKey.ProductName; displayVersion = $osKey.DisplayVersion
                                build = "$($osKey.CurrentBuild).$($osKey.UBR)" }
    crashes         = $crashes
    windowsUpdate   = $windowsUpdate
    cbs             = $cbs
    whea            = $wheaOut
    storage         = $storage
    volumes         = $volumes
    logonShellTasks = [ordered]@{ count = $logonShellTasks.Count; items = $logonShellTasks }
    runKeys         = $runKeys
    antivirus       = $antivirus
    processes       = $processes
    boot            = $boot
}

if ($AsJson) {
    $report | ConvertTo-Json -Depth 8
    return
}

# ---------------------------------------------------------------- human summary
"Windows health report  ($($report.os.product) $($report.os.displayVersion) build $($report.os.build))"
"generated $($report.generatedAt)   elevated=$elevated   lookback=${Days}d"
""
"crashes         : Kernel-Power41=$($crashes.kernelPower41)  BugCheck=$($crashes.bugCheck1001)  Unexpected=$($crashes.unexpected6008)"
"windows update  : setupFailures=$($windowsUpdate.setupFailures)  TIreboots=$($windowsUpdate.trustedInstallerReboots)  lastCode=$($windowsUpdate.lastFailureCode)"
"cbs             : sourceModified=$($cbs.sourceModifiedHits)"
"whea            : id17=$($wheaOut.id17)  fatal18=$($wheaOut.fatal18)  maxPerDay=$($wheaOut.maxPerDay)"
"                  device=$($wheaOut.topDevice)"
"storage         : errorEvents=$($storage.errorEvents)  disks=$(($storage.disks | ForEach-Object { $_.friendlyName + '=' + $_.healthStatus }) -join ', ')"
"volumes         : SYSTEM free=$($volumes.systemReservedFreeMB)MB  C: free=$($volumes.osFreeGB)GB"
"logon shells    : $($logonShellTasks.Count) task(s)"
$logonShellTasks | ForEach-Object {
    "                  $($_.task)  logonType=$($_.logonType)  lastResult=$($_.lastTaskResult)$(if($_.killedByConsoleClose){'  <-- killed by console close'})"
}
"antivirus       : $($avProducts -join ', ')"
"repair running  : $($processes.repairRunning)  TiWorker CPU=$($processes.tiWorkerCpuSeconds)s"
""
"Match these against catalog.json. Do not apply a fix without matching evidence."
