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
    Name of the role to export. Optional for Export mode — if omitted the script
    lists all custom roles and prompts for interactive selection.

.PARAMETER FilePath
    Path to a JSON file or directory.
    - Export: output directory or file path. When exporting multiple roles,
      must be a directory. Defaults to the script directory.
    - Import: specific JSON file, or a directory to scan for JSON files.
      If omitted, the script directory is scanned. When multiple files are
      found an interactive picker is shown.

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
    # Interactive export — lists all custom roles, prompts for selection
    .\Invoke-VIRoleManager.ps1 -vCenterServer vc01.lab.local -Mode Export

.EXAMPLE
    # Non-interactive export — export a specific role directly
    .\Invoke-VIRoleManager.ps1 -vCenterServer vc01.lab.local -Mode Export -RoleName "Custom Ops Role"

.EXAMPLE
    # Import a role from JSON (keep original name)
    .\Invoke-VIRoleManager.ps1 -vCenterServer vc02.lab.local -Mode Import -FilePath .\Custom_Ops_Role.json

.EXAMPLE
    # Import and rename the role
    .\Invoke-VIRoleManager.ps1 -vCenterServer vc02.lab.local -Mode Import -FilePath .\Custom_Ops_Role.json -NewRoleName "Ops Role v2"

.EXAMPLE
    # Lab environment with self-signed certificate
    .\Invoke-VIRoleManager.ps1 -vCenterServer vc01.lab.local -Mode Export -SkipCertificateValidation

.NOTES
    Author   : Paul van Dieen
    Blog     : https://www.hollebollevsan.nl
    Version  : 1.2.0
    Requires : VCF.PowerCLI 9.0+ (recommended) or VMware.PowerCLI 13+
    Tested   : vSphere 9

.CHANGELOG
    v1.2.0  2026-03-31  Paul van Dieen
        - Import mode: interactive JSON file picker — scans script directory
          (or -FilePath directory) for JSON files, shows role name and privilege
          count from each file, accepts comma-separated selection or 'all'
        - -FilePath no longer required for Import; single-file and directory
          paths both accepted; existing-role conflict downgrades to warning
          and continues with remaining files

    v1.1.2  2026-03-31  Paul van Dieen
        - Bug fix: all PowerCLI cmdlets now scoped with -Server $viConn to
          prevent reading/writing across linked vCenter instances

    v1.1.1  2026-03-31  Paul van Dieen
        - Bug fix: removed Set-VIRole -Description call — parameter does not
          exist in VCF.PowerCLI 9; description is preserved in the JSON export
          but not applied on import

    v1.1.0  2026-03-31  Paul van Dieen
        - Export mode: interactive role picker when -RoleName is omitted —
          lists all custom (non-system) roles with privilege counts, accepts
          comma-separated numbers or 'all'; each role exported to its own JSON
        - -RoleName is now optional for Export; still accepted for scripted use

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

$scriptVersion = '1.2.0'
$scriptAuthor  = 'Paul van Dieen'
$scriptBlogUrl = 'https://www.hollebollevsan.nl'
$scriptDir     = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# --- Console Banner -----------------------------------------------------------
Write-Host ('=' * 62) -ForegroundColor DarkCyan
Write-Host ("  Invoke-VIRoleManager.ps1" + (' ' * 21) + "v$scriptVersion") -ForegroundColor Cyan
Write-Host "  Author : $scriptAuthor"  -ForegroundColor Cyan
Write-Host "  Blog   : $scriptBlogUrl" -ForegroundColor DarkGray
Write-Host ('=' * 62) -ForegroundColor DarkCyan

# --- No mandatory pre-flight validation needed — both modes handle missing params interactively

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
        # Resolve output directory
        $outDir = if ($FilePath -and (Test-Path $FilePath -PathType Container)) {
            $FilePath
        } elseif ($FilePath -and -not [System.IO.Path]::GetExtension($FilePath)) {
            $FilePath   # treat as directory even if it doesn't exist yet
        } else {
            $scriptDir
        }

        # Get all custom (non-system) roles — scope to this vCenter only
        $allRoles = @(Get-VIRole -Server $viConn -ErrorAction Stop | Where-Object { -not $_.IsSystem } | Sort-Object Name)
        if ($allRoles.Count -eq 0) {
            Write-Host "  [WARN] No custom roles found on $vCenterServer." -ForegroundColor Yellow
        } else {
            # Determine which roles to export
            $rolesToExport = [System.Collections.Generic.List[object]]::new()

            if ($RoleName) {
                # Non-interactive: -RoleName supplied directly
                $match = $allRoles | Where-Object { $_.Name -eq $RoleName }
                if (-not $match) {
                    Write-Host "  [ERROR] Role '$RoleName' not found or is a system role." -ForegroundColor Red
                    exit 1
                }
                $rolesToExport.Add($match)
            } else {
                # Interactive picker
                Write-Host ""
                Write-Host "  Custom roles on $vCenterServer`:" -ForegroundColor Cyan
                Write-Host ""
                for ($i = 0; $i -lt $allRoles.Count; $i++) {
                    $privCount = $allRoles[$i].ExtensionData.Privilege.Count
                    $line = "   [{0,2}]  {1,-45} ({2} privileges)" -f ($i + 1), $allRoles[$i].Name, $privCount
                    Write-Host $line -ForegroundColor White
                }
                Write-Host ""
                $selection = Read-Host "  Enter number(s) to export (comma-separated, or 'all')"
                $selection = $selection.Trim()

                if ($selection -ieq 'all') {
                    foreach ($r in $allRoles) { $rolesToExport.Add($r) }
                } else {
                    foreach ($token in ($selection -split ',')) {
                        $token = $token.Trim()
                        $idx   = 0
                        if ([int]::TryParse($token, [ref]$idx) -and $idx -ge 1 -and $idx -le $allRoles.Count) {
                            $rolesToExport.Add($allRoles[$idx - 1])
                        } else {
                            Write-Host "  [WARN] '$token' is not a valid selection — skipped." -ForegroundColor Yellow
                        }
                    }
                }
            }

            if ($rolesToExport.Count -eq 0) {
                Write-Host "  [WARN] No roles selected." -ForegroundColor Yellow
            } else {
                Write-Host ""
                foreach ($role in $rolesToExport) {
                    try {
                        $privileges = @($role.ExtensionData.Privilege)
                        $export = [PSCustomObject]@{
                            ExportedFrom   = $vCenterServer
                            ExportedAt     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                            ScriptVersion  = $scriptVersion
                            RoleName       = $role.Name
                            Description    = if ($role.Description) { $role.Description } else { '' }
                            PrivilegeCount = $privileges.Count
                            Privileges     = $privileges
                        }

                        # If -FilePath points to a single file and only one role — honour it; else use directory
                        $outFile = if ($FilePath -and $rolesToExport.Count -eq 1 -and [System.IO.Path]::GetExtension($FilePath) -ne '') {
                            $FilePath
                        } else {
                            $safeName = $role.Name -replace '[^\w\-]', '_'
                            Join-Path $outDir "$safeName.json"
                        }

                        if (-not (Test-Path (Split-Path $outFile -Parent))) {
                            $null = New-Item -ItemType Directory -Path (Split-Path $outFile -Parent) -Force
                        }

                        $export | ConvertTo-Json -Depth 5 | Out-File -FilePath $outFile -Encoding UTF8
                        Write-Host "  [OK]   '$($role.Name)' — $($privileges.Count) privilege(s) — exported to: $outFile" -ForegroundColor Green
                    } catch {
                        Write-Host "  [ERROR] Failed to export '$($role.Name)': $_" -ForegroundColor Red
                    }
                }
            }
        }
    } catch {
        Write-Host "  [ERROR] Export failed: $_" -ForegroundColor Red
    }
}

# =============================================================================
# IMPORT
# =============================================================================
if ($Mode -eq 'Import') {
    try {
        # Resolve search directory and build list of JSON files to pick from
        $searchDir = if ($FilePath -and (Test-Path $FilePath -PathType Container)) {
            $FilePath
        } elseif ($FilePath -and [System.IO.Path]::GetExtension($FilePath) -ne '') {
            $null   # specific file supplied — skip picker
        } else {
            $scriptDir
        }

        $filesToImport = [System.Collections.Generic.List[string]]::new()

        if ($null -eq $searchDir) {
            # Non-interactive: single file supplied directly
            $filesToImport.Add($FilePath)
        } else {
            $jsonFiles = @(Get-ChildItem -Path $searchDir -Filter '*.json' -File | Sort-Object Name)
            if ($jsonFiles.Count -eq 0) {
                Write-Host "  [WARN] No JSON files found in $searchDir." -ForegroundColor Yellow
            } elseif ($jsonFiles.Count -eq 1) {
                # Only one file — use it without prompting
                Write-Host "  [INFO] Found 1 file: $($jsonFiles[0].Name)" -ForegroundColor Cyan
                $filesToImport.Add($jsonFiles[0].FullName)
            } else {
                # Interactive picker
                Write-Host ""
                Write-Host "  JSON files in $searchDir`:" -ForegroundColor Cyan
                Write-Host ""
                for ($i = 0; $i -lt $jsonFiles.Count; $i++) {
                    # Peek at role name inside the file
                    try {
                        $peek     = Get-Content $jsonFiles[$i].FullName -Raw | ConvertFrom-Json
                        $roleName = if ($peek.PSObject.Properties['RoleName']) { $peek.RoleName } else { '?' }
                        $privCnt  = if ($peek.PSObject.Properties['PrivilegeCount']) { $peek.PrivilegeCount } else { '?' }
                        $line = "   [{0,2}]  {1,-35} role: {2,-30} ({3} privileges)" -f ($i + 1), $jsonFiles[$i].Name, $roleName, $privCnt
                    } catch {
                        $line = "   [{0,2}]  {1}" -f ($i + 1), $jsonFiles[$i].Name
                    }
                    Write-Host $line -ForegroundColor White
                }
                Write-Host ""
                $selection = Read-Host "  Enter number(s) to import (comma-separated, or 'all')"
                $selection = $selection.Trim()

                if ($selection -ieq 'all') {
                    foreach ($f in $jsonFiles) { $filesToImport.Add($f.FullName) }
                } else {
                    foreach ($token in ($selection -split ',')) {
                        $token = $token.Trim()
                        $idx   = 0
                        if ([int]::TryParse($token, [ref]$idx) -and $idx -ge 1 -and $idx -le $jsonFiles.Count) {
                            $filesToImport.Add($jsonFiles[$idx - 1].FullName)
                        } else {
                            Write-Host "  [WARN] '$token' is not a valid selection — skipped." -ForegroundColor Yellow
                        }
                    }
                }
            }
        }

        if ($filesToImport.Count -eq 0) {
            Write-Host "  [WARN] No files selected." -ForegroundColor Yellow
        } else {
            Write-Host ""
            foreach ($file in $filesToImport) {
                try {
                    Write-Host "  [INFO] Reading $file..." -ForegroundColor Cyan
                    $import = Get-Content -Path $file -Raw -ErrorAction Stop | ConvertFrom-Json

                    # -NewRoleName only applies when importing a single file
                    $targetName = if ($NewRoleName -and $filesToImport.Count -eq 1) { $NewRoleName } else { $import.RoleName }
                    Write-Host "  [INFO] Importing as '$targetName' ($($import.Privileges.Count) privilege(s), exported from $($import.ExportedFrom) on $($import.ExportedAt))." -ForegroundColor Cyan

                    # Check for existing role — scope to this vCenter only
                    $existing = Get-VIRole -Server $viConn -Name $targetName -ErrorAction SilentlyContinue
                    if ($existing) {
                        Write-Host "  [WARN] Role '$targetName' already exists — skipped. Use -NewRoleName to import under a different name." -ForegroundColor Yellow
                        continue
                    }

                    # Resolve privileges — scope to this vCenter only
                    $privsToAdd  = [System.Collections.Generic.List[object]]::new()
                    $skippedList = [System.Collections.Generic.List[string]]::new()

                    foreach ($privId in $import.Privileges) {
                        $priv = Get-VIPrivilege -Server $viConn -Id $privId -ErrorAction SilentlyContinue
                        if ($priv) { $privsToAdd.Add($priv) } else { $skippedList.Add($privId) }
                    }

                    if ($skippedList.Count -gt 0) {
                        Write-Host "  [WARN] $($skippedList.Count) privilege(s) not found in target vCenter and will be skipped:" -ForegroundColor Yellow
                        foreach ($s in $skippedList) { Write-Host "         - $s" -ForegroundColor Yellow }
                    }

                    # Create role and apply all resolved privileges in a single call
                    $newRole = New-VIRole -Server $viConn -Name $targetName -ErrorAction Stop
                    if ($privsToAdd.Count -gt 0) {
                        $null = Set-VIRole -Server $viConn -Role $newRole -AddPrivilege $privsToAdd.ToArray() -ErrorAction Stop
                    }

                    Write-Host "  [OK]   '$targetName' created: $($privsToAdd.Count) privilege(s) applied, $($skippedList.Count) skipped." -ForegroundColor Green
                } catch {
                    Write-Host "  [ERROR] Failed to import '$file': $_" -ForegroundColor Red
                }
            }
        }
    } catch {
        Write-Host "  [ERROR] Import failed: $_" -ForegroundColor Red
    }
}

# --- Disconnect ---------------------------------------------------------------
Disconnect-VIServer -Server $vCenterServer -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "  [INFO] Disconnected from $vCenterServer." -ForegroundColor Cyan
Write-Host ('=' * 62) -ForegroundColor DarkCyan
