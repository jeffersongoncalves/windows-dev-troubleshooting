# WHEA-Logger Event 17 — PCIe correctable errors behind "random freezes"

## Symptom

The whole system stalls for a few seconds. Mouse stutters or stops, audio glitches,
everything resumes. No blue screen, no reboot, nothing in the application logs. It
happens several times a day with no obvious trigger.

Disk checks come back clean. Memory tests pass. You start to suspect software.

## Diagnostic

```powershell
# Count and date every hardware error the firmware reported
$evts = Get-WinEvent -FilterHashtable @{
    LogName      = "System"
    ProviderName = "Microsoft-Windows-WHEA-Logger"
    StartTime    = (Get-Date).AddDays(-30)
} -EA SilentlyContinue

"total: $($evts.Count)"

$evts | Group-Object { $_.TimeCreated.ToString("yyyy-MM-dd") } |
    Select-Object Count, Name | Sort-Object Name | Format-Table -AutoSize
```

Event IDs worth knowing:

| ID | Meaning |
|---|---|
| 17 | Corrected hardware error — recovered, but it happened |
| 18 | Fatal uncorrected error (usually precedes a bugcheck) |
| 19 | Corrected machine check |
| 47 | Corrected memory error, page offlined |

A handful of ID 17 over a month is background noise. **Dozens per day is a finding.**

### Identify the failing device

```powershell
$evts | Where-Object Id -eq 17 | Select-Object -First 1 | ForEach-Object {
    $x = [xml]$_.ToXml()
    $x.Event.EventData.Data |
        Where-Object Name -in "ErrorSource","Bus","Device","Function","VendorID","DeviceID","PrimaryDeviceName" |
        ForEach-Object { "{0} = {1}" -f $_.Name, $_."#text" }
}
```

Example output:

```
ErrorSource       = 4
Bus               = 0x0
Device            = 0x1
Function          = 0x0
VendorID          = 0x8086
DeviceID          = 0x7ecc
PrimaryDeviceName = PCI\VEN_8086&DEV_7ECC&SUBSYS_...&REV_10
```

`ErrorSource = 4` is **AER — Advanced Error Reporting (PCI Express)**. The message
body confirms `Component: PCI Express Root Port`.

That bus/device/function is the **root port**, not the device causing trouble. The
device sits on its *secondary* bus. Map it:

```powershell
Get-PnpDevice -PresentOnly -Class Display,SCSIAdapter,Net,System |
    Where-Object InstanceId -like "PCI*" |
    ForEach-Object {
        $loc = (Get-PnpDeviceProperty -InstanceId $_.InstanceId `
                    -KeyName "DEVPKEY_Device_LocationInfo" -EA SilentlyContinue).Data
        "{0,-14} | {1,-45} | {2}" -f $_.Class, $_.FriendlyName, $loc
    }
```

Root port at bus 0 / device 1 / function 0 hands off to **PCI bus 1**. Whatever
reports `PCI bus 1, device 0, function 0` is your culprit — on most desktops and
gaming laptops, the discrete GPU:

```
Display  | NVIDIA GeForce RTX xxxx      | PCI bus 1, device 0, function 0
System   | High Definition Audio ...    | PCI bus 1, device 0, function 1
```

## Why this freezes the machine

A *correctable* PCIe error is recovered by the link layer, so nothing crashes. But
recovery means the link retrains. While a x16 link to the GPU retrains, nothing
crosses that bus — no frames, no display updates, no GPU compute. From the desk it is
indistinguishable from a system-wide freeze of a few seconds.

Correctable errors are also a leading indicator. A link degrading toward uncorrectable
errors will show a rising count of ID 17 first.

## Rule out the cheaper explanations first

Before touching hardware, confirm the freeze is not simple I/O saturation.

```powershell
# Storage stack complaints — should be empty
Get-WinEvent -FilterHashtable @{
    LogName="System"
    ProviderName="disk","storahci","stornvme","Ntfs","volmgr"
    StartTime=(Get-Date).AddDays(-7)
} -EA SilentlyContinue | Group-Object ProviderName, Id | Select-Object Count, Name

# Drive health
Get-PhysicalDisk | Select-Object FriendlyName, MediaType, BusType, HealthStatus, OperationalStatus
Get-PhysicalDisk | Get-StorageReliabilityCounter |
    Select-Object Temperature, Wear, ReadErrorsUncorrected, WriteErrorsUncorrected
```

If those are clean and WHEA is loud, the PCIe link is the better hypothesis.

**Correlate before concluding.** A WHEA count is not proof that a *specific* freeze
came from PCIe. Log a timestamped sample every 30 s and compare the gaps against the
WHEA timestamps:

```powershell
# minimal freeze logger — a gap in the timestamps is the freeze window
while ($true) {
    "{0:HH:mm:ss} cpu={1}%" -f (Get-Date),
        (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average |
        Add-Content C:\freeze.log
    Start-Sleep 30
}
```

Run it as a scheduled task — and read
[A PowerShell window opens at every logon](powershell-window-at-logon.md) first, or
you will close the window and kill your own logger without realising it.

## Fixes, cheapest first

1. **Clean GPU driver reinstall.** Display drivers are the most common source of
   correctable AER storms. Use DDU in safe mode, then install the current driver.
2. **Update BIOS/UEFI.** PCIe link-training fixes appear in almost every release.
   On laptops this is often the only knob you get.
3. **Disable ASPM** (`L0s`/`L1`) or **force the link to Gen3** in firmware setup.
   Aggressive link power management is a frequent cause; many laptop BIOSes hide
   these settings.
4. **Reseat the card / clean the slot** on desktops. On a riser, replace the riser
   cable — they are a common failure point.
5. **Check PSU headroom** if errors cluster under load.

If a current driver, current firmware and ASPM disabled still leave the count high,
the link itself is degrading — that is a warranty conversation.

## What "corrected" does and does not mean

It means no data was lost *this time*. It does not mean the machine is healthy. Track
the daily count over weeks: a flat low number is tolerable, a rising trend is a
component on its way out.
