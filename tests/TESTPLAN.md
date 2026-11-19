# VIRoleManager test plan

How to test `Invoke-VIRoleManager.ps1` in a lab: which lab, which test set,
which cases, and what came out. Labs are named by code only; addresses live
outside this repository.

## Labs

| Code | What | Role in the tests |
|---|---|---|
| **L8** | vCenter 8.0 U3, no hosts | Export source for vSphere 8 |
| **LA** | VCF 9.1.1 management vCenter | Main target; scale tests |
| **LB** | VCF 9.0.2 management vCenter | Second source/target (no `vcf_reserved` permissions) |

## Test sets

| Script | What it builds | Cleanup |
|---|---|---|
| `New-VIRoleTestSet.ps1` | Functional set: `VIRM-T-Operator`, `VIRM-T-Legacy` (8.0.3-only privileges), `VIRM-T-Empty`, `VIRM-T-AllVM`, `VIRM-T Ops & Support (L2)` | `-Mode Remove` (only roles no permission uses) |
| `New-VIRoleScaleSet.ps1` | Scale set: `-RoleCount` roles (default 200), `VIRM-S-001` and up, 50 to 400 privileges each (seeded, same sets per vCenter version), one `AddAuthorizationRole` call per role | `-Mode Remove`; `-Force` also deletes roles whose only permission is their own `vcf_reserved_<roleId>` (VCF 9.1.1) |

## Test cases

### A. Functional (New-VIRoleTestSet.ps1)

| # | Lab | Steps | Expected | Result |
|---|---|---|---|---|
| F1 | L8 to LA | Create on L8, Export each role with `-RoleName`, Import on LA, Show on both, Remove | Five roles with the same privileges; the four 8.0.3-only privileges skipped with a message | 2026-11-16: **pass** |

### B. Scale (New-VIRoleScaleSet.ps1)

| # | Steps | Expected | Result (LA, 2026-11-19, 1.5.0) |
|---|---|---|---|
| S1 | Create 200 roles | 44901 privilege assignments | **pass**, 23 s |
| S2 | Export `-RoleName 'VIRM-S-*' -FilePath <folder>` | 200 files | **pass**, 2 s |
| S3 | Import the 200 files into the same vCenter | 200 skipped (already exists) | **pass**, 27 s |
| S4 | Import the largest role (403 privileges) with `-NewRoleName` | Created with 403 privileges, 0 left out | **pass**, 18 s for this one role: every privilege is looked up with its own `Get-VIPrivilege` call. 200 roles of about 225 privileges would take roughly half an hour (estimate, not measured) |
| S5 | Remove without `-Force` | 200 kept, message to use `-Force` | **pass** |
| S6 | Remove `-Force` | 200 roles removed; no `vcf_reserved` permission left pointing at a deleted role | **pass**, about 25 s |

### C. Removing a role on VCF 9.1.1 (vcf_reserved)

| # | Steps | Expected | Result (LA, 2026-11-19) |
|---|---|---|---|
| R1 | `RemoveAuthorizationRole(<roleId>, $false)` on a custom role whose only permission is `VSPHERE.LOCAL\vcf_reserved_<roleId>` on the root folder | Role and that permission gone | **pass** |
| R2 | Check again after 5 minutes | Neither came back | **pass** |
| R3 | Does the local group `vcf_reserved_<roleId>` stay behind? | Gone | **pass**: gone, checked in the vSphere Client (Administration, Single Sign On, Users and Groups, Groups). The `UserDirectory.RetrieveUserGroups` lookup can't be used for this: it finds none of these groups, also not for an existing role |

## Open points

- Whether VCF Operations notices a removed custom role.
- Import of many roles into a second vCenter (LA to LB) not run: needs a
  saved credential for LB.
