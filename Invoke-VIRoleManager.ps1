<#
.SYNOPSIS
    Export or import vCenter roles and their privilege assignments.

.DESCRIPTION
    Connects to a vCenter Server and either exports a role's privilege IDs to a
    JSON file, or creates a new role from a previously exported JSON file.

    Credentials are encrypted and saved as <hostname>.cred next to the script
    using Export-Clixml (DPAPI-protected, tied to the current Windows user).

.PARAMETER vCenterServer
    FQDN or IP of the vCenter Server.

.PARAMETER Mode
    'Export' to save a role to file, or 'Import' to create a role from file.

.PARAMETER RoleName
    Name of the role to export. Required for Export mode.

.PARAMETER FilePath
    Path to the JSON file.
    - Export: output file path. Defaults to <RoleName>.json next to the script.
    - Import: input file path. Required for Import mode.

.PARAMETER NewRoleName
    Name for the imported role. Defaults to the role name stored in the export
    file. Use this to rename the role on import.

.PARAMETER CredentialPath
    Path to the encrypted credential file. Defaults to <vCenterServer>.cred
    next to the script.

.PARAMETER SkipCertificateValidation
    Skip TLS certificate validation. For lab use with self-signed certificates.

.PARAMETER ResetCredentials
    Force a new credential prompt even if a saved credential file exists.

.EXAMPLE
    # Export a role to JSON
    .\Invoke-VIRoleManager.ps1 -vCenterServer vc01.lab.local -Mode Export -RoleName "Custom Ops Role"

.EXAMPLE
    # Import a role from JSON (keep original name)
    .\Invoke-VIRoleManager.ps1 -vCenterServer vc02.lab.local -Mode Import -FilePath .\Custom_Ops_Role.json

.EXAMPLE
    # Import and rename the role
    .\Invoke-VIRoleManager.ps1 -vCenterServer vc02.lab.local -Mode Import -FilePath .\Custom_Ops_Role.json -NewRoleName "Ops Role v2"

.EXAMPLE
    # Lab environment with self-signed certificate
    .\Invoke-VIRoleManager.ps1 -vCenterServer vc01.lab.local -Mode Export -RoleName "Custom Ops Role" -SkipCertificateValidation

.NOTES
    Author   : Paul van Dieen
    Blog     : https://www.hollebollevsan.nl
    Version  : 1.0.0
    Requires : VCF.PowerCLI 9.0+ (recommended) or VMware.PowerCLI 13+
    Tested   : vSphere 9

.CHANGELOG
    v1.0.0  2026-03-31  Paul van Dieen
        - Initial structured release
        - Export mode: writes role name, description, privilege IDs and metadata
          to a JSON file for portability
        - Import mode: creates role from JSON, skips privileges not present in
          the target vCenter and reports them by name
        - Credential caching via Export-Clixml (DPAPI, Windows-only)
        - Supports VCF.PowerCLI 9.0+ and VMware.PowerCLI 13+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$vCenterServer,
    [Parameter(Mandatory)][ValidateSet('Export','Import')][string]$Mode,
    [string]$RoleName,
    [string]$FilePath,
    [string]$NewRoleName,
    [string]$CredentialPath,
    [switch]$SkipCertificateValidation,
    [switch]$ResetCredentials
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptVersion = '1.0.0'
$scriptAuthor  = 'Paul van Dieen'
$scriptBlogUrl = 'https://www.hollebollevsan.nl'
$scriptDir     = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# --- Console Banner -----------------------------------------------------------
Write-Host ('=' * 62) -ForegroundColor DarkCyan
Write-Host ("  Invoke-VIRoleManager.ps1" + (' ' * 21) + "v$scriptVersion") -ForegroundColor Cyan
Write-Host "  Author : $scriptAuthor"  -ForegroundColor Cyan
Write-Host "  Blog   : $scriptBlogUrl" -ForegroundColor DarkGray
Write-Host ('=' * 62) -ForegroundColor DarkCyan

# --- Validate mode-specific required parameters --------------------------------
if ($Mode -eq 'Export' -and -not $RoleName) {
    Write-Host "  [ERROR] -RoleName is required for Export mode." -ForegroundColor Red
    exit 1
}
if ($Mode -eq 'Import' -and -not $FilePath) {
    Write-Host "  [ERROR] -FilePath is required for Import mode." -ForegroundColor Red
    exit 1
}

# --- PowerCLI Module Check ----------------------------------------------------
$vcfModule    = Get-Module -Name VCF.PowerCLI              -ListAvailable
$legacyModule = Get-Module -Name VMware.VimAutomation.Core -ListAvailable

if (-not $vcfModule -and -not $legacyModule) {
    Write-Host "  [ERROR] No compatible PowerCLI module found." -ForegroundColor Red
    Write-Host "          Install-Module -Name VCF.PowerCLI -Scope CurrentUser" -ForegroundColor Yellow
    exit 1
}

if ($vcfModule) {
    if (-not (Get-Module -Name VCF.PowerCLI)) {
        Write-Host "  [INFO] Loading VCF.PowerCLI..." -ForegroundColor Cyan
        Import-Module VCF.PowerCLI -ErrorAction Stop
    }
} else {
    if (-not (Get-Module -Name VMware.VimAutomation.Core)) {
        Write-Host "  [INFO] Loading VMware.PowerCLI..." -ForegroundColor Cyan
        Import-Module VMware.VimAutomation.Core -ErrorAction Stop
    }
}

# --- Credential Management ----------------------------------------------------
$safeVc = $vCenterServer -replace '[^\w\-.]', '_'
if (-not $CredentialPath) { $CredentialPath = Join-Path $scriptDir "$safeVc.cred" }

if ($ResetCredentials -or -not (Test-Path $CredentialPath)) {
    if ($ResetCredentials) {
        Write-Host "  [WARN] -ResetCredentials specified — prompting for new credentials." -ForegroundColor Yellow
    } else {
        Write-Host "  [INFO] No saved credentials found — prompting." -ForegroundColor Cyan
    }
    $credUser   = Read-Host "  Username for $vCenterServer"
    $credPass   = Read-Host "  Password" -AsSecureString
    $credential = [System.Management.Automation.PSCredential]::new($credUser, $credPass)
    $credential | Export-Clixml -Path $CredentialPath
    Write-Host "  [OK]   Credentials saved to $CredentialPath." -ForegroundColor Green
} else {
    Write-Host "  [INFO] Loading saved credentials from $CredentialPath." -ForegroundColor Cyan
    $credential = Import-Clixml -Path $CredentialPath
}

# --- Connect to vCenter -------------------------------------------------------
Write-Host "  [INFO] Connecting to $vCenterServer..." -ForegroundColor Cyan
try {
    $null = Set-PowerCLIConfiguration `
        -InvalidCertificateAction $(if ($SkipCertificateValidation) { 'Ignore' } else { 'Warn' }) `
        -Confirm:$false -Scope Session -WarningAction SilentlyContinue
    $viConn = Connect-VIServer -Server $vCenterServer -Credential $credential -ErrorAction Stop -WarningAction SilentlyContinue
    Write-Host "  [OK]   Connected to $vCenterServer (version $($viConn.Version), build $($viConn.Build))." -ForegroundColor Green
} catch {
    Write-Host "  [ERROR] Failed to connect to $vCenterServer`: $_" -ForegroundColor Red
    exit 1
}

# =============================================================================
# EXPORT
# =============================================================================
if ($Mode -eq 'Export') {
    try {
        Write-Host "  [INFO] Fetching role '$RoleName'..." -ForegroundColor Cyan
        $role = Get-VIRole -Name $RoleName -ErrorAction Stop

        $privileges = @($role.ExtensionData.Privilege)
        Write-Host "  [INFO] Found $($privileges.Count) privilege(s)." -ForegroundColor Cyan

        $export = [PSCustomObject]@{
            ExportedFrom  = $vCenterServer
            ExportedAt    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            ScriptVersion = $scriptVersion
            RoleName      = $role.Name
            Description   = if ($role.Description) { $role.Description } else { '' }
            PrivilegeCount= $privileges.Count
            Privileges    = $privileges
        }

        if (-not $FilePath) {
            $safeName = $RoleName -replace '[^\w\-]', '_'
            $FilePath = Join-Path $scriptDir "$safeName.json"
        }

        $export | ConvertTo-Json -Depth 5 | Out-File -FilePath $FilePath -Encoding UTF8
        Write-Host "  [OK]   Role '$RoleName' exported to: $FilePath" -ForegroundColor Green
    } catch {
        Write-Host "  [ERROR] Export failed: $_" -ForegroundColor Red
    }
}

# =============================================================================
# IMPORT
# =============================================================================
if ($Mode -eq 'Import') {
    try {
        Write-Host "  [INFO] Reading $FilePath..." -ForegroundColor Cyan
        $import = Get-Content -Path $FilePath -Raw -ErrorAction Stop | ConvertFrom-Json

        $targetName = if ($NewRoleName) { $NewRoleName } else { $import.RoleName }
        Write-Host "  [INFO] Importing as role '$targetName' ($($import.Privileges.Count) privilege(s) in source)." -ForegroundColor Cyan
        Write-Host "  [INFO] Originally exported from $($import.ExportedFrom) on $($import.ExportedAt)." -ForegroundColor Cyan

        # Check for existing role
        $existing = Get-VIRole -Name $targetName -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "  [ERROR] Role '$targetName' already exists. Use -NewRoleName to specify a different name." -ForegroundColor Red
            exit 1
        }

        # Resolve privileges — collect found and report missing
        $privsToAdd  = [System.Collections.Generic.List[object]]::new()
        $skippedList = [System.Collections.Generic.List[string]]::new()

        foreach ($privId in $import.Privileges) {
            $priv = Get-VIPrivilege -Id $privId -ErrorAction SilentlyContinue
            if ($priv) {
                $privsToAdd.Add($priv)
            } else {
                $skippedList.Add($privId)
            }
        }

        if ($skippedList.Count -gt 0) {
            Write-Host "  [WARN] $($skippedList.Count) privilege(s) not found in target vCenter and will be skipped:" -ForegroundColor Yellow
            foreach ($s in $skippedList) {
                Write-Host "         - $s" -ForegroundColor Yellow
            }
        }

        # Create role and apply all resolved privileges in a single call
        Write-Host "  [INFO] Creating role '$targetName'..." -ForegroundColor Cyan
        $newRole = New-VIRole -Name $targetName -ErrorAction Stop

        if ($import.Description) {
            $null = Set-VIRole -Role $newRole -Description $import.Description -ErrorAction SilentlyContinue
        }

        if ($privsToAdd.Count -gt 0) {
            $null = Set-VIRole -Role $newRole -AddPrivilege $privsToAdd.ToArray() -ErrorAction Stop
        }

        Write-Host "  [OK]   Role '$targetName' created: $($privsToAdd.Count) privilege(s) applied, $($skippedList.Count) skipped." -ForegroundColor Green
    } catch {
        Write-Host "  [ERROR] Import failed: $_" -ForegroundColor Red
    }
}

# --- Disconnect ---------------------------------------------------------------
Disconnect-VIServer -Server $vCenterServer -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "  [INFO] Disconnected from $vCenterServer." -ForegroundColor Cyan
Write-Host ('=' * 62) -ForegroundColor DarkCyan
