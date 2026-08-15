# Managing Kaspersky settings from the CLI (`avp.com`)

Consumer Kaspersky ships a CLI at:

```
C:\Program Files (x86)\Kaspersky Lab\Kaspersky <version>\avp.com
```

`avp.com HELP` lists the commands. There is **no** command to add a single exclusion.
The only way to change settings programmatically is `EXPORT` → edit → `IMPORT`.

## Getting `EXPORT` to work

```
Usage: EXPORT [/login=<login> /password=<password>] <filename>
       IMPORT <filename> </login=<login> </password=<password>>
```

Two gotchas, both of which produce misleading errors.

**Without credentials:**

```
Login required:
Parameters /login=<login> /password=<password> are required for this action.
Export failed with error, rc = 0x00000002
```

**With the wrong credentials** — for example your My Kaspersky account e-mail:

```
Error: Command unavailable due to password protection disabled
Export failed with error, rc = 0x00000002
```

That message is a false lead. It does not mean password protection is off. It means
the credentials you supplied are not the ones this command wants.

The correct credential is the **local settings-protection account**, not the My
Kaspersky cloud account. The default username is **`KLAdmin`**, and the password is
the one set under *Settings → Interface → Password protection*. Password protection
must be **enabled** for the CLI to accept it at all.

```powershell
$avp = "C:\Program Files (x86)\Kaspersky Lab\Kaspersky 21.26\avp.com"
& $avp EXPORT "/login=KLAdmin" "/password=$pass" "C:\temp\kav"
# writes C:\temp\kav.cfg  (the extension is appended for you)
```

Pull the password from a secret manager rather than typing it into a shell — command
lines land in history, transcripts and process listings:

```powershell
$pass = (op read "op://<vault>/<item>/password").Trim()   # 1Password CLI
```

## The file format

The `.cfg` is XML with a hex-encoded binary blob plus large plain-text sections:

```xml
<root>
  <pragueSettings data="4B4C7377...">   <!-- hex blob, "KLsw" magic, opaque -->
  <ekaSettings>
    <services> ... </services>          <!-- plain XML, editable -->
  </ekaSettings>
  <persistentData>...</persistentData>
  <Registry>...</Registry>
</root>
```

Everything useful lives in the plain-text part. Do not attempt to decode the blob.

### Where the settings you want actually live

| What | XPath |
|---|---|
| File/folder exclusions | `//exclusionSettings/fileRules` |
| Trusted applications | `services/item[@name="exclude.application_manager"]/actual_config/settings/rules` |
| TCP traffic exclusions | `...TcpInterceptor/actual_config/settings/tcpControlSettings/applicationExcludes` |

Note the inconsistency: some services are elements named after the service, others
are `<item name="service.name">`. Anchor your string search on
`name="exclude.application_manager"`, not on `<exclude.application_manager>`.

Also: every service appears twice, as `actual_config` and `default_config`. **Edit
`actual_config`.** Writing to `default_config` changes nothing.

### File exclusion entry

```xml
<item_0002 unique_id="679391196" triggers="1" scope="0" verdict_mask="" verdict_path=""
           detect_type="0" detect_danger="0" description="" userTag="" enabled="1">
  <object unique_id="2898656857" mask="C:\Windows\WinSxS\" recurse="1" />
  <task_list />
  <fileHash unique_id="636138305" hashType="0" hashData="" />
</item_0002>
```

- `recurse="1"` covers the whole subtree — no need to list subfolders or individual
  executables.
- `<task_list />` empty with `triggers="1"` = all protection components.
- Spaces in `mask` are escaped as `&#x20;` by the product. A literal space parses
  fine, but matching the product's convention is safer.

### Trusted application entry

```xml
<item_0006 unique_id="2847463670" enabled="1"
           path="C:\Program Files\Git\usr\bin\bash.exe"
           controlTriggersMask="12785" description="" userTag=""
           imageHash_initialized="0" appCheckMode="0" ruleUsageTriggersMask="1" />
```

`controlTriggersMask` is an undocumented bitmask of the per-app options ("do not scan
opened files", "do not monitor application activity", "do not scan network traffic",
…). **Do not invent a value.** Configure one application through the GUI with the
options you want, export, and copy the resulting number. Observed examples:

| Value | Hex | Notes |
|---|---|---|
| 12593 | 0x3131 | fewer options enabled |
| 12657 | 0x3171 | + one more bit |
| 12785 | 0x31F1 | most permissive of the three |

`path` matches **exactly** — no wildcards guaranteed, no name matching.

## Editing safely

Item elements are positional: `item_0000`, `item_0001`, … Adding an entry means
appending *and renumbering*, or the product may reject or silently drop entries.

Sketch of a safe patch:

```powershell
# 1. export, and keep an untouched copy as the rollback
Copy-Item $exported $backup

# 2. isolate the block
$a = $raw.IndexOf('<fileRules>'); $b = $raw.IndexOf('</fileRules>')
$frag = [xml]("<w>" + $raw.Substring($a, $b - $a + 12) + "</w>")

# 3. collect existing nodes verbatim, append new ones, renumber all of them
#    (preserving existing entries byte-for-byte avoids losing hashes and flags)

# 4. validate before writing anything
$null = [xml]$patched          # throws on malformed XML

# 5. import, then EXPORT AGAIN and assert the state you expect
```

Three rules that keep this from going wrong:

1. **Keep the original export.** `IMPORT` replaces the *entire* configuration, not
   just the section you touched. The untouched export is your only rollback.
2. **Validate the XML** before importing.
3. **Verify by re-exporting.** `IMPORT` returns `exit=0` even when your edit did not
   land the way you expected. Read the state back from the product and assert it.

Make the script **idempotent** — skip paths already present — so re-running after a
tool update is safe.

## Confirming the product is still healthy

`IMPORT` rewrites everything. Always check afterwards:

```powershell
& $avp STATUS | Select-String "^\s+(Protection|File_Monitoring|Firewall|Hips|ids|AMSI|NetWatch)\s"
```

All should read `running`. If a component is missing or stopped, restore the backup:

```powershell
& $avp IMPORT $backup "/login=KLAdmin" "/password=$pass"
```

## Cleaning up

The exported `.cfg` contains your complete security configuration — exclusion paths,
network rules, everything. Delete the copies when done, and never commit one to a
repository.
