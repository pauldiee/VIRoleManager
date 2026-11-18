#Requires -Version 5.1

<#
.SYNOPSIS
    Builds, shows or removes a throwaway set of test roles in a LAB vCenter
    for Invoke-VIRoleManager.ps1.

.DESCRIPTION
    Lab use only. Every role it creates is named VIRM-T*, and Remove only
    deletes VIRM-T* roles that no permission uses.

    Create builds five roles, each a case an export/import has to handle:
        VIRM-T-Operator            a few VM power and console privileges
        VIRM-T-Legacy              Datastore.Browse plus the privileges that
                                   exist on vCenter 8.0.3 but not on 9.1.1
                                   (whichever of them this vCenter has); an
                                   import into 9.x has to skip and report them
        VIRM-T-Empty               no privileges beyond the System ones
        VIRM-T-AllVM               every VirtualMachine.* privilege
        VIRM-T Ops & Support (L2)  spaces, an ampersand and brackets in the name

    Show lists every VIRM-T* role with its privilege count (System.* left out)
    and, for VIRM-T-Legacy, which of the 8.0.3-only privileges it holds, so an
    import can be compared with the source.

.PARAMETER vCenterServer
    FQDN or IP of the LAB vCenter Server.

.PARAMETER Mode
    Create, Show or Remove.

.PARAMETER CredentialPath
    Saved credential file. Defaults to <vCenterServer>.cred in the repo root
    (the same file Invoke-VIRoleManager.ps1 uses).

.PARAMETER SkipCertificateValidation
    Skip TLS certificate validation (self-signed lab certificates).

.NOTES
    Script   : New-VIRoleTestSet.ps1
    Version  : 1.0.1
    Author   : Paul van Dieen
    Blog     : https://www.hollebollevsan.nl
    Requires : VCF.PowerCLI 9.0+ or VMware.PowerCLI 13+
    Tested   : vCenter 8.0.3 (build 25600417) and 9.1.1 (lab), 2026-11-16
#>

<# CHANGELOG
    v1.0.1  2026-11-18  Paul van Dieen
        - Get-Help shows the full help again: the changelog moved out of the
          help block into its own comment block (the unknown .CHANGELOG
          keyword made Get-Help ignore the whole help block)
        - Blank line between #Requires and the help block, for the same reason

    v1.0.0  2026-11-16  Paul van Dieen
        - Initial release: Create / Show / Remove of a role test set
#>

param(
    [Parameter(Mandatory = $true)][string]$vCenterServer,
    [Parameter(Mandatory = $true)][ValidateSet('Create', 'Show', 'Remove')][string]$Mode,
    [string]$CredentialPath = '',
    [switch]$SkipCertificateValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptVersion = '1.0.1'
$scriptAuthor  = 'Paul van Dieen'
$scriptBlogUrl = 'https://www.hollebollevsan.nl'
$repoRoot      = Split-Path $PSScriptRoot -Parent

Write-Host ('=' * 62) -ForegroundColor DarkCyan
Write-Host ('  New-VIRoleTestSet.ps1' + (' ' * 24) + "v$scriptVersion") -ForegroundColor Cyan
Write-Host "  $scriptAuthor - $scriptBlogUrl" -ForegroundColor Gray
Write-Host '  LAB USE ONLY - touches VIRM-T* roles only' -ForegroundColor Yellow
Write-Host ('=' * 62) -ForegroundColor DarkCyan

# Privileges present on vCenter 8.0.3 (25600417) and gone on 9.1.1 (25784172),
# compared in the lab on 2026-11-16.
$legacyOnly = 'vSphereClient.UtilizeVerificationCode', 'IntercomNamespace.Read', 'IntercomNamespace.Write', 'Observability.Admin'

$safeVc = $vCenterServer -replace '[^\w\-.]', '_'
if (-not $CredentialPath) { $CredentialPath = Join-Path $repoRoot "$safeVc.cred" }
if (-not (Test-Path $CredentialPath)) { throw "No credential file at $CredentialPath." }
$credential = Import-Clixml -Path $CredentialPath

$null = Set-PowerCLIConfiguration -InvalidCertificateAction $(if ($SkipCertificateValidation) { 'Ignore' } else { 'Warn' }) `
    -DefaultVIServerMode Multiple -Confirm:$false -Scope Session -WarningAction SilentlyContinue
$vi = Connect-VIServer -Server $vCenterServer -Credential $credential -WarningAction SilentlyContinue
Write-Host "  Connected to $vCenterServer ($($vi.Version), build $($vi.Build))" -ForegroundColor Green

function Get-Priv { param([string[]]$Id) @(Get-VIPrivilege -Server $vi -PrivilegeItem | Where-Object { $Id -contains $_.Id }) }

try {
    switch ($Mode) {
        'Create' {
            $all = @(Get-VIPrivilege -Server $vi -PrivilegeItem)
            $plan = [ordered]@{
                'VIRM-T-Operator'           = @(Get-Priv 'VirtualMachine.Interact.PowerOn', 'VirtualMachine.Interact.PowerOff', 'VirtualMachine.Interact.Reset', 'VirtualMachine.Interact.ConsoleInteract')
                'VIRM-T-Legacy'             = @(Get-Priv (@('Datastore.Browse') + $legacyOnly))
                'VIRM-T-Empty'              = @()
                'VIRM-T-AllVM'              = @($all | Where-Object { $_.Id -like 'VirtualMachine.*' })
                'VIRM-T Ops & Support (L2)' = @(Get-Priv 'Datastore.Browse', 'Host.Config.Storage', 'Global.LogEvent')
            }
            foreach ($name in $plan.Keys) {
                if (Get-VIRole -Server $vi -Name $name -ErrorAction SilentlyContinue) { Write-Host "  $name exists" -ForegroundColor DarkGray; continue }
                $privs = $plan[$name]
                $role = if ($privs.Count) { New-VIRole -Server $vi -Name $name -Privilege $privs } else { New-VIRole -Server $vi -Name $name }
                Write-Host "  Created $name ($($privs.Count) privileges requested)" -ForegroundColor Green
            }
            $have = @(Get-Priv $legacyOnly).Id
            Write-Host ("  8.0.3-only privileges on this vCenter: " + $(if ($have) { $have -join ', ' } else { 'none (a 9.x vCenter)' }))
        }
        'Show' {
            $rows = foreach ($r in @(Get-VIRole -Server $vi | Where-Object { $_.Name -like 'VIRM-T*' } | Sort-Object Name)) {
                $ids = @($r.PrivilegeList)
                [pscustomobject]@{
                    Role       = $r.Name
                    Privileges = @($ids | Where-Object { $_ -notlike 'System.*' }).Count
                    Legacy     = (@($ids | Where-Object { $legacyOnly -contains $_ }) -join ',')
                    Sample     = (@($ids | Where-Object { $_ -notlike 'System.*' } | Sort-Object | Select-Object -First 3) -join ', ')
                }
            }
            if ($rows) { $rows | Format-Table -AutoSize | Out-String -Width 220 | Write-Host } else { Write-Host '  No VIRM-T* roles.' }
        }
        'Remove' {
            foreach ($r in @(Get-VIRole -Server $vi | Where-Object { $_.Name -like 'VIRM-T*' })) {
                $used = @(Get-VIPermission -Server $vi -ErrorAction SilentlyContinue | Where-Object { $_.Role -eq $r.Name })
                if ($used.Count) {
                    Write-Host "  Kept $($r.Name): used by $($used.Count) permission(s) (on VCF 9.1 possibly vcf_reserved_*, managed by VCF)" -ForegroundColor Red
                } else {
                    Remove-VIRole -Server $vi -Role $r -Confirm:$false
                    Write-Host "  Removed $($r.Name)" -ForegroundColor Yellow
                }
            }
        }
    }
}
finally {
    Disconnect-VIServer -Server $vi -Confirm:$false
}
