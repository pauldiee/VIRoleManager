# VIRoleManager

A PowerShell utility to export and import vCenter roles and their privilege assignments — useful for migrating roles between vCenter instances or backing them up before upgrades.

| Script | Version | Purpose |
|---|---|---|
| `Invoke-VIRoleManager.ps1` | 1.6.0 | Export / import vCenter roles — **vSphere 9 only** |
| `tests/New-VIRoleTestSet.ps1` | 1.0.1 | Builds, shows and removes a set of test roles in a **lab** vCenter |
| `tests/New-VIRoleScaleSet.ps1` | 0.2.0 | Builds and removes 200 roles (50 to 400 privileges) in a **lab** vCenter |

---

## What it does

- **Export** — connects to a vCenter, lists all custom (non-system) roles with their privilege counts, and lets you select one or more to export. Each role is saved as a portable JSON file containing the role name, description, and full list of privilege IDs.
- **Import** — reads a previously exported JSON file and recreates the role on a target vCenter, applying all privileges found. Any privilege IDs that no longer exist on the target (e.g. removed in a newer vSphere release) are reported and skipped — the role is still created with the remaining privileges.

## Requirements

| Requirement | Notes |
|---|---|
| PowerShell 7.4+ | VCF.PowerCLI 9.x needs PowerShell 7 ([KB 409981](https://knowledge.broadcom.com/external/article/409981)); Windows ships 5.1, so start the script from `pwsh` |
| VCF.PowerCLI 9.0+ or VMware.PowerCLI 13+ | `Install-Module -Name VCF.PowerCLI -Scope CurrentUser` |
| Network access | HTTPS to vCenter Server |

Setting up PowerShell 7 and VCF.PowerCLI on a jump host, with or without internet access, and keeping one PowerCLI version per host: [Jump Host: PowerShell 7 and VCF PowerCLI](https://vcf-planning.hollebollevsan.nl/docs/42-jump-host-powershell/).

## Usage

```powershell
# Interactive export — lists all custom roles, prompts for selection
.\Invoke-VIRoleManager.ps1 -vCenterServer vc01.vcf.lab -Mode Export

# Fully interactive: mode menu, folder prompt, picker
.\Invoke-VIRoleManager.ps1 -vCenterServer vc01.vcf.lab

# Non-interactive export — one role, or several names and wildcards
.\Invoke-VIRoleManager.ps1 -vCenterServer vc01.vcf.lab -Mode Export -RoleName "TanzuUser"
.\Invoke-VIRoleManager.ps1 -vCenterServer vc01.vcf.lab -Mode Export -RoleName 'Ops*','TanzuUser' -FilePath C:\RoleBackups

# Import every role export in a folder, without the picker
.\Invoke-VIRoleManager.ps1 -vCenterServer vc02.vcf.lab -Mode Import -FilePath 'C:\RoleBackups\*.json'

# Export to a specific directory
.\Invoke-VIRoleManager.ps1 -vCenterServer vc01.vcf.lab -Mode Export -FilePath C:\RoleBackups

# Import a role (keep original name)
.\Invoke-VIRoleManager.ps1 -vCenterServer vc02.vcf.lab -Mode Import -FilePath .\TanzuUser.json

# Import and rename the role
.\Invoke-VIRoleManager.ps1 -vCenterServer vc02.vcf.lab -Mode Import -FilePath .\TanzuUser.json -NewRoleName "TanzuUser-v2"

# Import again after registering a plugin: add the privileges existing roles miss
.\Invoke-VIRoleManager.ps1 -vCenterServer vc02.vcf.lab -Mode Import -FilePath 'C:\RoleBackups\*.json' -ExistingRole Update

# Lab environment (self-signed certificate)
.\Invoke-VIRoleManager.ps1 -vCenterServer vc01.vcf.lab -Mode Export -SkipCertificateValidation

# Reset saved credentials
.\Invoke-VIRoleManager.ps1 -vCenterServer vc01.vcf.lab -Mode Export -ResetCredentials
```

Credentials are encrypted and saved as `<hostname>.cred` next to the script using `Export-Clixml` (DPAPI-protected, tied to the current Windows user).

## How a run goes

Without `-Mode` a menu asks for Export or Import. Without `-FilePath` the script then asks for the folder: **Enter** keeps the script directory (the default), **B** opens the Windows folder browser (only where a GUI is available), or type a path. Import shows how many JSON files the folder holds and asks again when it holds none. An export with `-RoleName` doesn't ask. Everything the console shows also goes to `Logs\VIRoleManager_<timestamp>.log` next to the script (`-LogDirectory` to change it). Long steps show a progress bar with "n of N: item", the percentage and the time left; it disappears when the step ends.

## Interactive picker

When running Export without `-RoleName`, the script presents a numbered list of all custom roles; Import shows the JSON files in the folder with the role name and privilege count inside each:

```
  Roles on this vCenter: select the ones to EXPORT
  [1]  TanzuUser                                     (6 privileges)
  [2]  VDI Admins                                    (28 privileges)
  [3]  Custom Read-Only                              (12 privileges)
```

The picker accepts single numbers, comma-separated lists, ranges (`2-6`), combinations (`1,3-5,8`), `all`, and `cancel` (or `exit`, `quit`, `q`). Each selected role is saved as its own JSON file.

### Filtering a picker

VCF vCenters carry dozens of custom service roles, so the picker filters by name. While a filter is on, the prompt shows it, for example `Your selection (filter: /cns, 4 shown)`.

| To | Type |
|---|---|
| Narrow the list | A wildcard (`*cns*`) or `/text` for a substring |
| Change the filter | The new filter straight away; it searches the full list again, not within the previous filter |
| Clear the filter | `reset`, or just Enter |
| See everything in the current list | `list` |

The list is renumbered after every filter and after clearing it, so pick the number from the list shown just above the prompt. `all` takes what the filter shows. A filter that matches nothing leaves the list as it was. Above 50 items the picker shows a few examples and asks for a filter instead of printing the whole list.

## Roles that already exist

On import, a role whose name already exists on the target is not created again. Without `-ExistingRole` the script lists those roles and asks:

| Answer | What happens |
|---|---|
| **S** or Enter | Skip them (the behaviour before 1.6.0) |
| **U** | Update them all: add the privileges of the export that the role misses |
| **P** | Pick the roles to update in the picker; the rest are skipped |

Updating only adds privileges, it never removes any. It adds those that this vCenter knows; the rest are listed as left out, as on a new role. The typical case: plugin privileges (NSX, a backup or DR product) were left out at the first import because the plugin was not registered on the target yet. Register the plugin, run the import again and answer **U**. The log lists every added privilege.

`-ExistingRole Skip` or `-ExistingRole Update` gives the answer up front. An unattended run without console input skips existing roles, as before, and does not stop with exit code 2.

## Failures and exit codes

A role that fails to export or import is logged in red as `FAILED …`, with vCenter's own message. The summary is red when something failed, yellow when something was only skipped (the role already exists, privileges left out because the target doesn't know them), green otherwise, and lists every failure.

| Code | Meaning |
|---|---|
| 0 | Finished without failures (skips are allowed) |
| 1 | Something failed: see the red `FAILED` lines and the summary, or the script could not start (PowerCLI, connection, no role matches `-RoleName`, `-FilePath` not found) |
| 2 | Stopped because a prompt needed console input in an unattended run; the message names the parameters to pass. Save the credential first with one interactive run |

From a scheduled task or another script, start it with `pwsh -Command` rather than `pwsh -File`: with `-File`, `-RoleName 'a','b'` arrives as one string.

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-vCenterServer` | `string` | *(required)* | FQDN or IP of the vCenter Server |
| `-Mode` | `Export\|Import` | *(menu)* | Operation mode; a menu asks when omitted |
| `-RoleName` | `string[]` | *(interactive)* | Export: role names or wildcards — omit to use the interactive picker |
| `-FilePath` | `string` | Next to script | Export: output directory, or a file when exporting one role. Import: a JSON file, a wildcard (every match is imported) or a folder to pick from. Asked after the mode when omitted |
| `-NewRoleName` | `string` | *(from file)* | Rename the role on import (single file only) |
| `-ExistingRole` | `Ask\|Skip\|Update` | `Ask` | Import: what to do with a role that already exists. Ask lists them and asks; Update adds the privileges it misses (never removes any); Skip skips them. Without console input Ask skips |
| `-LogDirectory` | `string` | `Logs\` next to script | Where the log file goes |
| `-CredentialPath` | `string` | Next to script | Path to the encrypted credential file |
| `-SkipCertificateValidation` | `switch` | — | Skip TLS validation — for lab use |
| `-ResetCredentials` | `switch` | — | Force a new credential prompt |

## Export file format

Each exported role is a JSON file with the following structure:

```json
{
  "ExportedFrom": "vc01.vcf.lab",
  "ExportedAt": "2026-03-31 14:57:00",
  "ScriptVersion": "1.1.1",
  "RoleName": "TanzuUser",
  "Description": "",
  "PrivilegeCount": 6,
  "Privileges": [
    "Namespaces.Configure",
    "Namespaces.Manage",
    "..."
  ]
}
```

---

## Testing in a lab

`tests/New-VIRoleTestSet.ps1` builds a set of test roles in a **lab** vCenter (`-Mode Create`), each a case an export/import has to handle: `VIRM-T-Operator` (a few VM privileges), `VIRM-T-Legacy` (privileges that exist on vCenter 8.0.3 but not on 9.1.1), `VIRM-T-Empty` (System privileges only), `VIRM-T-AllVM` (every `VirtualMachine.*` privilege) and `VIRM-T Ops & Support (L2)` (spaces, `&` and brackets in the name). `-Mode Show` lists them with their privilege counts; `-Mode Remove` deletes the ones no permission uses. It only touches `VIRM-T*` roles and reads the same `.cred` file as the main script.

Suggested run: Create on the source, Export each role with `-RoleName`, Import on the target, Show on both sides, Remove.

Lab findings (vCenter 8.0.3 build 25600417 to 9.1.1 build 25784172, 2026-11-16, clean `pwsh -NoProfile`):

- All five roles imported with the same privileges, the name with special characters included.
- vCenter 8.0.3 has four privileges that 9.1.1 doesn't: `vSphereClient.UtilizeVerificationCode`, `IntercomNamespace.Read`, `IntercomNamespace.Write`, `Observability.Admin`. The import skips them and says so (*"4 privilege(s) not found in target vCenter and will be skipped"*).
- On VCF 9.1.1 every custom role gets a permission on the vCenter root for a `VSPHERE.LOCAL\vcf_reserved_<n>` principal, so `-Mode Remove` of the test set keeps the roles there; the script leaves that permission alone.
- Removing such a role is possible (lab-verified on VCF 9.1.1, 2026-11-19): `RemoveAuthorizationRole(<roleId>, $false)`, which the vSphere Client's *Delete role* with *remove permissions* also does, deletes the role together with its own `vcf_reserved_<roleId>` permission. Neither came back (checked after 5 minutes), and no `vcf_reserved` permission was left pointing at a deleted role. Broadcom's *Managing VCF Roles* says not to modify these permissions on roles that stay; removing a custom role isn't covered there. The local group `vcf_reserved_<roleId>` was gone as well (checked in the vSphere Client, Administration, Single Sign On, Users and Groups).

`tests/New-VIRoleScaleSet.ps1` builds 200 roles (`VIRM-S-001` and up, 50 to 400 privileges each) for scale tests. `-Mode Remove` deletes the ones no permission uses; with `-Force` also those whose only permission is their own `vcf_reserved_<roleId>` (VCF 9.1.1). Test cases and results: `tests/TESTPLAN.md`.

## Author

Paul van Dieen — [hollebollevsan.nl](https://www.hollebollevsan.nl)
