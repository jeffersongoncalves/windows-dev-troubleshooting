# Antivirus exclusions that silently do nothing

## Symptom

You added the folder to your antivirus exclusions. Builds are still slow, the update
still fails, the file is still locked. The exclusion is right there in the UI, spelled
correctly.

## The trap

Most antivirus products do not have *one* exclusion. They have a list of exclusions
where **each entry names which protection components it applies to** — and the
default is frequently *not* "all of them".

An exclusion scoped only to behaviour analysis leaves the real-time **file scanner**
fully active on that path. The file scanner is the component that opens, locks and
delays every file. So the exclusion looks correct and changes nothing that matters.

This is easy to miss because the UI shows the path prominently and the component
scope as a secondary field, often collapsed or displaying a vague default.

## Diagnostic

Do not trust the UI summary. Read the components column for every rule.

**Kaspersky** — export the configuration and inspect it (see
[Kaspersky settings via CLI](kaspersky-avp-cli-settings.md)). Each rule carries a
`task_list`:

```xml
<item_0003 triggers="5" enabled="1">
  <object mask="C:\Windows\SoftwareDistribution\" recurse="1" />
  <task_list item_0000="behavior_detection" />   <!-- ONLY behaviour analysis -->
</item_0003>
```

versus one that applies to everything:

```xml
<item_0002 triggers="1" enabled="1">
  <object mask="C:\Program Files\Herd\" recurse="1" />
  <task_list />                                   <!-- empty = ALL components -->
</item_0002>
```

An **empty `task_list` with `triggers="1"` means "any component"**. A populated
`task_list` restricts the rule to exactly those components. Both forms are produced
by the product itself, so you can use either as a template with confidence.

**Microsoft Defender** — exclusions are global, but check the *type*:

```powershell
Get-MpPreference | Select-Object -ExpandProperty ExclusionPath
Get-MpPreference | Select-Object -ExpandProperty ExclusionProcess
Get-MpPreference | Select-Object -ExpandProperty ExclusionExtension
```

`ExclusionPath` excludes files at that path. `ExclusionProcess` excludes files
*touched by* that process. They are not interchangeable, and a slow build usually
needs both.

## Fix

In the GUI, open each exclusion and set **Protection components** to *Any* (Kaspersky
calls it "Qualquer" in pt-BR builds), or explicitly tick the file antivirus alongside
behaviour detection.

## The second trap: path exclusions are not process exclusions

Excluding a folder stops the scanner from inspecting *files in that folder*. It does
not stop the behaviour engine from intercepting what a *process* does — writing to
protected locations, injecting, opening raw network sockets.

That is a separate list, usually called **Trusted applications**, and it matches on
**exact executable path**, not process name.

Consequence: when an application updates and moves its binary, the trusted-app rule
silently stops matching. The entry still shows in the UI, pointing at a path that no
longer exists, and the process is treated as unknown again.

Check every entry actually resolves:

```powershell
# after exporting the config, list the registered paths and test them
$paths | ForEach-Object { "{0}  exists={1}" -f $_, (Test-Path -LiteralPath $_) }
```

A real example: a local dev environment manager registers a helper that edits
`C:\Windows\System32\drivers\etc\hosts`. The trusted-app entry pointed at
`...\.config\<tool>\bin\Helper.exe`, but a later version shipped the binary at
`C:\Program Files\<Tool>\Helper.exe`. The rule never matched again, and the behaviour
engine started blocking hosts writes — which is exactly the kind of operation it is
designed to block. Symptom: local `.test` domains stopped resolving after a tool
update, with no error anywhere.

Also register the **elevation helper** if the tool uses one. Whitelisting the main
binary is useless if the process that actually acquires privilege is still
intercepted.

## The third trap: version-pinned paths

Some Windows binaries live in versioned directories that change with every update.
`TiWorker.exe` is the classic:

```
C:\Windows\WinSxS\amd64_microsoft-windows-servicingstack_<hash>_10.0.<build>_none_<hash>\TiWorker.exe
```

Hardcode that and it is stale after the next servicing stack update. Prefer a mask
(`C:\Windows\WinSxS\*\TiWorker.exe`) if your product supports one, or re-run your
configuration script after updates. Resolve the live path with:

```powershell
Get-Process TiWorker | Select-Object -ExpandProperty Path
```

## Verifying an exclusion actually works

Do not trust that saving the dialog applied it. Read the configuration back from the
product and confirm the stored state:

1. Export the settings.
2. Parse the exclusion list.
3. Assert path, `enabled`, and component scope for every rule you care about.

Then test behaviourally — trigger the operation that was failing and confirm it now
succeeds, checking the file's `LastWriteTime` or the tool's log rather than assuming.

## What not to exclude

Excluding your source tree (`vendor/`, `node_modules/`) is the single biggest speed
win and the single worst security decision on a dev box. Those directories are where
third-party dependencies land — precisely the supply-chain attack surface that
real-time scanning exists to catch.

If you exclude them anyway, do it knowingly and compensate: pinned lockfiles, review
of dependency updates, no auto-merge of bot PRs.
