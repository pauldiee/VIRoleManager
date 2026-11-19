#Requires -Version 7.4

<#
.SYNOPSIS
    Builds or removes a large throwaway set of roles in a LAB vCenter, to
    test Invoke-VIRoleManager.ps1 at scale (progress, duration).

.DESCRIPTION
    Lab use only. Every role it creates is named VIRM-S-<nnn>, and Remove
    only deletes VIRM-S-* roles that no permission uses.

    Create  -RoleCount roles (default 200), VIRM-S-001 and up, each with a
            fixed pseudo-random set of privileges from this vCenter's own
            privilege list: from 50 up to 400 privileges, spread evenly over
            the roles. The same vCenter version gives the same sets on every
            run. Created with AuthorizationManager.AddAuthorizationRole, one
            call per role. Running Create again adds what is missing.
    Remove  Deletes every VIRM-S-* role that no permission uses. With
            -Force it also deletes a role whose only permissions are its
            own VSPHERE.LOCAL\vcf_reserved_<roleId> ones (see below); a role
            with any other permission is always kept.

    On VCF 9.1.1 vCenter gives every new role a permission on the root
    folder for VSPHERE.LOCAL\vcf_reserved_<roleId> (Managing VCF Roles: do
    not modify these permissions). Lab-verified 2026-11-19 on 9.1.1:
    RemoveAuthorizationRole(roleId, failIfUsed = $false) removes the role
    and that permission, and neither came back (checked after 5 minutes).
    The local group vcf_reserved_<roleId> was gone too (vSphere Client). A 9.0.x vCenter has no such permissions.

.PARAMETER vCenterServer
    FQDN or IP of the LAB vCenter Server.

.PARAMETER Mode
    Create or Remove.

.PARAMETER RoleCount
    Number of roles (Create). Default 200.

.PARAMETER Force
    Remove mode: also delete VIRM-S-* roles whose only permissions are
    their own vcf_reserved_<roleId> ones (VCF 9.1.1).

.PARAMETER CredentialPath
    Saved credential file. Defaults to <vCenterServer>.cred in the repo root
    (where Invoke-VIRoleManager.ps1 keeps it).

.PARAMETER SkipCertificateValidation
    Skip TLS certificate validation (self-signed lab certificates).

.EXAMPLE
    .\New-VIRoleScaleSet.ps1 -vCenterServer vc-lab.lab.local -Mode Create

.EXAMPLE
    .\New-VIRoleScaleSet.ps1 -vCenterServer vc-lab.lab.local -Mode Remove

.NOTES
    Script   : New-VIRoleScaleSet.ps1
    Version  : 0.2.0
    Author   : Paul van Dieen
    Blog     : https://www.hollebollevsan.nl
    Requires : PowerShell 7.4+, VCF.PowerCLI 9.0+ or VMware.PowerCLI 13+
    Tested   : Lab, 2026-11-19: VCF 9.1.1 (Holodeck lab A), 200 roles
#>

<# CHANGELOG
    v0.2.0  2026-11-19  Paul van Dieen
        - Remove -Force: also deletes roles whose only permissions are their
          own vcf_reserved_<roleId> ones (VCF 9.1.1), lab-verified
    v0.1.0  2026-11-19  Paul van Dieen
        - Initial version: Create and Remove of a large role set for scale
          tests of Invoke-VIRoleManager.ps1 (#14)
#>

param(
    [Parameter(Mandatory = $true)][string]$vCenterServer,
    [Parameter(Mandatory = $true)][ValidateSet('Create', 'Remove')][string]$Mode,
    [ValidateRange(1, 2000)][int]$RoleCount = 200,
    [switch]$Force,
    [string]$CredentialPath = '',
    [switch]$SkipCertificateValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptVersion = '0.2.0'
$scriptAuthor  = 'Paul van Dieen'
$scriptBlogUrl = 'https://www.hollebollevsan.nl'
$repoRoot      = Split-Path $PSScriptRoot -Parent

Write-Host ('=' * 62) -ForegroundColor DarkCyan
Write-Host ('  New-VIRoleScaleSet.ps1' + (' ' * 23) + "v$scriptVersion") -ForegroundColor Cyan
Write-Host "  Author : $scriptAuthor"  -ForegroundColor Cyan
Write-Host "  Blog   : $scriptBlogUrl" -ForegroundColor DarkGray
Write-Host '  LAB USE ONLY - touches VIRM-S-* roles only' -ForegroundColor Yellow
Write-Host ('=' * 62) -ForegroundColor DarkCyan

$prefix  = 'VIRM-S-'
$minPriv = 50
$maxPriv = 400

function Say { param([string]$Text, [string]$Color = 'Cyan') Write-Host "  $Text" -ForegroundColor $Color }

$safeVc = $vCenterServer -replace '[^\w\-.]', '_'
if (-not $CredentialPath) { $CredentialPath = Join-Path $repoRoot "$safeVc.cred" }
$credential = if (Test-Path $CredentialPath) { Import-Clixml -Path $CredentialPath } else { Get-Credential -Message "Credentials for $vCenterServer" }
$null = Set-PowerCLIConfiguration -InvalidCertificateAction $(if ($SkipCertificateValidation) { 'Ignore' } else { 'Warn' }) `
    -Confirm:$false -Scope Session -WarningAction SilentlyContinue
$vi = Connect-VIServer -Server $vCenterServer -Credential $credential -WarningAction SilentlyContinue
Say "Connected to $vCenterServer ($($vi.Version), build $($vi.Build))" Green

try {
    $authMgr = Get-View -Server $vi -Id (Get-View -Server $vi ServiceInstance).Content.AuthorizationManager
    if ($Mode -eq 'Create') {
        $started = Get-Date
        # Assignable privileges: System.* come with every role anyway
        $privIds = @($authMgr.PrivilegeList | Where-Object { $_.PrivId -notlike 'System.*' } | ForEach-Object { $_.PrivId } | Sort-Object)
        Say "Privileges on this vCenter (without System.*): $($privIds.Count)"
        $top = [Math]::Min($maxPriv, $privIds.Count)
        $existing = @{}
        foreach ($r in @($authMgr.RoleList)) { $existing[$r.Name] = $r.RoleId }
        $made = 0; $had = 0; $totalPrivs = 0
        for ($i = 1; $i -le $RoleCount; $i++) {
            $name = '{0}{1:D3}' -f $prefix, $i
            # Size from $minPriv to $top, spread evenly; the set is a seeded shuffle
            $size = if ($RoleCount -eq 1) { $top } else { $minPriv + [int][Math]::Floor(($top - $minPriv) * ($i - 1) / ($RoleCount - 1)) }
            $rng  = [System.Random]::new($i)
            $pick = @($privIds | Sort-Object { $rng.Next() } | Select-Object -First $size)
            $totalPrivs += $pick.Count
            if ($existing.ContainsKey($name)) { $had++; continue }
            $null = $authMgr.AddAuthorizationRole($name, [string[]]$pick)
            $made++
            if ($i % 25 -eq 0) {
                Write-Progress -Activity 'Creating roles' -Status "$i of $RoleCount" -PercentComplete ([int](100 * $i / $RoleCount))
                Say "  $i of $RoleCount"
            }
        }
        Write-Progress -Activity 'Creating roles' -Completed
        Say ("Done in {0:mm\:ss}: {1} role(s) created, {2} already there, {3} privilege assignments in total." -f ((Get-Date) - $started), $made, $had, $totalPrivs) Green
    }
    else {
        $roles = @($authMgr.RoleList | Where-Object { $_.Name -like "$prefix*" })
        if ($roles.Count -eq 0) { Say "No $prefix* roles."; return }
        # Permissions per role ID, from every permission in one call
        $permsByRole = @{}
        foreach ($p in @($authMgr.RetrieveAllPermissions())) {
            if ($null -eq $p) { continue }
            $k = [int]$p.RoleId
            if (-not $permsByRole.ContainsKey($k)) { $permsByRole[$k] = New-Object System.Collections.Generic.List[object] }
            $permsByRole[$k].Add($p)
        }
        $removed = 0; $kept = 0; $reservedOnly = 0
        foreach ($r in $roles) {
            $perms = @(if ($permsByRole.ContainsKey([int]$r.RoleId)) { $permsByRole[[int]$r.RoleId].ToArray() })
            $own   = "vcf_reserved_$($r.RoleId)"
            if ($perms.Count -eq 0) {
                $authMgr.RemoveAuthorizationRole($r.RoleId, $true)
                $removed++
            }
            elseif (@($perms | Where-Object { ($_.Principal -split '\\')[-1] -ne $own }).Count -eq 0) {
                # Only the role's own vcf_reserved_<roleId> permission(s) (VCF 9.1.1)
                if ($Force) {
                    $authMgr.RemoveAuthorizationRole($r.RoleId, $false)
                    $removed++
                } else { $reservedOnly++ }
            }
            else { $kept++ }
            if (($removed + $kept + $reservedOnly) % 25 -eq 0) { Say "  $($removed + $kept + $reservedOnly) of $($roles.Count) checked" }
        }
        Say "Removed $removed role(s)." Yellow
        if ($reservedOnly -gt 0) {
            Say "Kept $reservedOnly role(s) that only their own vcf_reserved_<roleId> permission uses (VCF 9.1.1); run again with -Force to delete them too." Yellow
        }
        if ($kept -gt 0) {
            Say "Kept $kept role(s) that another permission uses." Red
        }
    }
}
finally {
    Disconnect-VIServer -Server $vi -Confirm:$false
}
