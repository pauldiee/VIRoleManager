# VIRoleManager

A PowerShell utility to export and import vCenter roles and their privilege assignments — useful for migrating roles between vCenter instances or backing them up before upgrades.

| Script | Version | Purpose |
|---|---|---|
| `Invoke-VIRoleManager.ps1` | 1.3.0 | Export / import vCenter roles — **vSphere 9 only** |

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

# Non-interactive export — export a specific role directly
.\Invoke-VIRoleManager.ps1 -vCenterServer vc01.vcf.lab -Mode Export -RoleName "TanzuUser"

# Export to a specific directory
.\Invoke-VIRoleManager.ps1 -vCenterServer vc01.vcf.lab -Mode Export -FilePath C:\RoleBackups

# Import a role (keep original name)
.\Invoke-VIRoleManager.ps1 -vCenterServer vc02.vcf.lab -Mode Import -FilePath .\TanzuUser.json

# Import and rename the role
.\Invoke-VIRoleManager.ps1 -vCenterServer vc02.vcf.lab -Mode Import -FilePath .\TanzuUser.json -NewRoleName "TanzuUser-v2"

# Lab environment (self-signed certificate)
.\Invoke-VIRoleManager.ps1 -vCenterServer vc01.vcf.lab -Mode Export -SkipCertificateValidation

# Reset saved credentials
.\Invoke-VIRoleManager.ps1 -vCenterServer vc01.vcf.lab -Mode Export -ResetCredentials
```

Credentials are encrypted and saved as `<hostname>.cred` next to the script using `Export-Clixml` (DPAPI-protected, tied to the current Windows user).

## Interactive picker

When running Export without `-RoleName`, the script presents a numbered list of all custom roles:

```
  Custom roles on vc01.vcf.lab:

   [ 1]  TanzuUser                                     (6 privileges)
   [ 2]  VDI Admins                                    (28 privileges)
   [ 3]  Custom Read-Only                              (12 privileges)

  Enter number(s) to export (comma-separated, or 'all'):
```

Enter `1,3` to export two roles, or `all` to export every custom role. Each selected role is saved as its own JSON file.

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-vCenterServer` | `string` | *(required)* | FQDN or IP of the vCenter Server |
| `-Mode` | `Export\|Import` | *(required)* | Operation mode |
| `-RoleName` | `string` | *(interactive)* | Role to export — omit to use the interactive picker |
| `-FilePath` | `string` | Next to script | Export: output file or directory. Import: input JSON file |
| `-NewRoleName` | `string` | *(from file)* | Rename the role on import |
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
- On VCF 9.1.1 every custom role gets a permission on the vCenter root for a `VSPHERE.LOCAL\vcf_reserved_<n>` principal, so `-Mode Remove` keeps the roles there; the script leaves that permission alone.

## Author

Paul van Dieen — [hollebollevsan.nl](https://www.hollebollevsan.nl)
