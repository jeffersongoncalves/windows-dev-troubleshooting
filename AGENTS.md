# Instructions for AI agents

This repository is written to be used by an autonomous agent diagnosing a Windows
machine, not only by a human reading prose. This file is the operating protocol.
Read it fully before running anything.

Human contributors: everything here applies to you too. It is just written for the
party most likely to skip steps.

## The one rule

**Never apply a fix whose evidence you have not observed on this machine.**

Every guide in `docs/` is written as *symptom → diagnostic → evidence → cause → fix →
verification*. The evidence step is not decoration. Windows failure modes look alike
from the symptom alone: a machine that "won't boot" is usually an update loop, a
"freeze" is usually I/O saturation, and both have entirely different fixes that make
the other one worse.

If the diagnostic output does not match what the guide describes, **stop and report
the mismatch** rather than applying the closest-looking fix.

## Protocol

### 1. Collect

```powershell
pwsh -File scripts/Get-WindowsHealthReport.ps1 -AsJson
```

Read-only. Touches no configuration, starts no repair. Emits a JSON object with the
signals every guide keys off. Run it first, always.

### 2. Match

Load `catalog.json`. Each entry has:

| Field | Use |
|---|---|
| `id` | stable identifier |
| `symptoms` | natural-language phrases a user might report |
| `signal` | the field in the health report to inspect |
| `match` | the condition that confirms this diagnosis |
| `doc` | the guide to follow |
| `risk` | `low` / `medium` / `high` |
| `reversible` | whether the fix can be undone, and how |
| `requires_confirmation` | true = ask the human before applying |

Match on `signal` + `match`, not on the user's wording. Users misdescribe symptoms;
that is normal and not their fault.

### 3. Report before acting

State: what you observed, which diagnosis it matches, what you propose to change,
and how it is reversed. Then act according to `requires_confirmation`.

### 4. Verify by re-reading state

After any change, **read the state back from the system** and assert it. Do not infer
success from an exit code.

- Changed a scheduled task? `Get-ScheduledTask` and check the principal.
- Changed antivirus settings? Export the config again and parse it.
- Repaired the component store? `DISM /Online /Cleanup-Image /ScanHealth`.

A tool returning `0` means the tool ran. It does not mean your change landed the way
you intended. This has bitten every guide in this repo at least once.

## Hard constraints

**Back up before mutating opaque configuration.** Security products replace their
*entire* configuration on import. Keep the pre-change export and state the rollback
command in your report.

**Never disable protection to make a symptom disappear.** Narrow the exclusion to the
specific path or process that needs it. "Turn off the antivirus" is not a fix, and a
scoped exclusion you can justify is.

**Never exclude the user's source tree** (`vendor/`, `node_modules/`, project roots)
on your own initiative. It is the largest performance win available and a real
reduction in supply-chain defences. Surface the trade-off and let the human decide.

**Do not put secrets on a command line.** Passwords in arguments land in shell
history, process listings and transcripts. Read them from a secret manager into a
variable. Never echo a credential into output you will return.

**Do not delete. Rename.** `SoftwareDistribution`, `catroot2` and similar get renamed
to `.old`, never removed. Recovery costs one command instead of a reinstall.

**Long repairs are not hangs.** `DISM /RestoreHealth` and `sfc /scannow` can run 30+
minutes printing nothing while `TiWorker.exe` works. Poll
`Get-Process TiWorker | Select-Object CPU` — rising CPU means progress. Do not kill
and retry.

**Warn about the cost of your own repairs.** DISM and SFC saturate disk I/O and will
make the machine feel frozen. If the user reports a freeze *while your repair runs*,
that is probably you — say so instead of opening a hardware investigation.

## Distinguishing failure modes that look identical

| User says | Usually is | Confirm with |
|---|---|---|
| "it won't turn on" | update install loop | `Setup` log `0x800f0922`, repeated `1074` from TrustedInstaller, **no** `Kernel-Power 41` |
| "it froze" | I/O saturation, or PCIe AER | `TiWorker`/AV CPU at the timestamp, vs `WHEA-Logger` 17 count |
| "it crashed" | clean shutdown, or bugcheck | presence of `1001` / `41` |
| "the fix didn't work" | exclusion scoped to the wrong component | parse the exclusion's component list, not the UI |

`Kernel-Power 41` present means power loss or a hard crash. Absent means the machine
shut down cleanly, whatever the user experienced.

## Timestamp discipline

Correlate on time, always. A finding with a count but no timestamp correlation is a
hypothesis, not a diagnosis.

If the user reports a freeze at 16:45 and the last relevant hardware error was
yesterday at 19:54, **those are different problems**. Say that explicitly. Reporting a
real chronic issue as the cause of an unrelated acute one is the most common way an
agent produces a confident wrong answer here.

## Reporting

Give the human:

1. The **evidence** — actual log lines, with timestamps. Quote them.
2. The **reasoning** — why this evidence implies this cause.
3. What you **changed**, precisely.
4. What you **verified** afterwards, and how.
5. What you **did not** do, and why.

Point 5 matters most. Scope you declined — a fix you judged too risky, a path you
left scanned, a section of config you would not hand-edit — must be stated. Silently
narrowing the work reads as completion and is worse than not starting.
