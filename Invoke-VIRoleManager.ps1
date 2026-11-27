<#
.SYNOPSIS
    Export or import vCenter roles and their privilege assignments.

.DESCRIPTION
    Connects to a vCenter Server and either exports a role's privilege IDs to a
    JSON file, or creates a new role from a previously exported JSON file.

    Credentials are encrypted and saved as <hostname>.cred next to the script
    using Export-Clixml (DPAPI-protected, tied to the current Windows user).

.PARAMETER vCenterServer
    FQDN or IP of the vCenter Server. If omitted, the script asks for it and
    lists the vCenters with a saved credential (<host>.cred next to the
    script) as numbers.

.PARAMETER Mode
    'Export' to save roles to files, or 'Import' to create roles from files.
    If omitted, a menu is shown.

.PARAMETER RoleName
    Export mode: one or more role names or wildcards (e.g. 'Ops*') to export
    instead of the interactive picker. No match stops the script with the
    list of custom roles and exit code 1.

.PARAMETER FilePath
    Path to a JSON file, a wildcard, or a directory.
    - Export: output directory, or a file path when exporting one role.
      Defaults to the script directory.
    - Import: a JSON file, a wildcard (every matching file is imported), or a
      directory to pick files from.
    Without -FilePath an interactive run asks for the folder after the mode:
    Enter keeps the script directory, B opens the Windows folder browser, or
    type a path. No prompt for an export with -RoleName.

.PARAMETER LogDirectory
    Directory to write log files to. Defaults to a "Logs" subfolder next to
    the script.

.PARAMETER NewRoleName
    Name for the imported role. Defaults to the role name stored in the export
    file. Use this to rename the role on import.

.PARAMETER ExistingRole
    Import mode: what to do with a role whose name already exists on the
    target.
    - Ask (default): list the existing roles and ask: S skip them, U update
      them all, P pick the ones to update. Without console input (an
      unattended run) they are skipped, as before.
    - Skip: skip them without asking (the behaviour before 1.6.0).
    - Update: add the privileges of the export that the role misses and
      that this vCenter knows, for example plugin privileges left out at an
      earlier import because the plugin was not registered yet. Nothing is
      ever removed from an existing role.

.PARAMETER CredentialPath
    Path to the encrypted credential file. Defaults to <vCenterServer>.cred
    next to the script.

.PARAMETER SkipCertificateValidation
    Skip TLS certificate validation. For lab use with self-signed certificates.
    Without it, a vCenter whose certificate this machine doesn't trust is not
    connected silently any more: the script asks whether to go on without
    the check for this run (an unattended run stops with exit code 2).

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
    # Unattended export of every role whose name starts with Ops, into a folder
    .\Invoke-VIRoleManager.ps1 -vCenterServer vc01.lab.local -Mode Export -RoleName 'Ops*' -FilePath D:\migration\roles

.EXAMPLE
    # Import every role export in a folder without the picker
    .\Invoke-VIRoleManager.ps1 -vCenterServer vc02.lab.local -Mode Import -FilePath 'D:\migration\roles\*.json'

.EXAMPLE
    # Import again after registering a plugin: add the privileges existing roles miss
    .\Invoke-VIRoleManager.ps1 -vCenterServer vc02.lab.local -Mode Import -FilePath 'D:\migration\roles\*.json' -ExistingRole Update

.EXAMPLE
    # Lab environment with self-signed certificate
    .\Invoke-VIRoleManager.ps1 -vCenterServer vc01.lab.local -Mode Export -SkipCertificateValidation

.NOTES
    Author   : Paul van Dieen
    Blog     : https://www.hollebollevsan.nl
    Version  : 1.7.0
    Requires : PowerShell 7.4+, VCF.PowerCLI 9.0+ (or VMware.PowerCLI 13+)
    Tested   : vSphere 9
#>

<# CHANGELOG
    v1.7.0  2026-11-27  Paul van Dieen
        - Start without -vCenterServer (W38, as nsx-segment-migration and
          VITagManager 1.5.0): the script asks for the vCenter and lists the
          ones with a saved credential (<host>.cred next to the script) as
          numbers; 'q' quits
        - Untrusted vCenter certificate (#9, W20): no longer accepted
          silently (PowerCLI's Warn). Without -SkipCertificateValidation the
          connection fails on it and the script asks whether to go on without
          the check for this run; an unattended run stops with exit code 2
        - An unexpected error ends the run with one red [ERROR] line (also in
          the log) and exit code 1, instead of PowerShell's error record

    v1.6.0  2026-11-25  Paul van Dieen
        - Import can update roles that already exist (#17): new
          -ExistingRole Ask|Skip|Update. Ask (default) lists the existing
          roles and asks S skip, U update all or P pick; Update adds the
          privileges of the export that the role misses and the target
          knows (for example plugin privileges left out because the plugin
          was not registered yet). Nothing is removed. Without console input
          existing roles are skipped, as before. The log lists every added
          privilege; the summary counts created, updated and already
          complete roles
        - An existing role is matched on its exact name (Get-VIRole -Name
          also takes wildcards)
        - Lab-verified on vCenter 9.1.1 (build 25784172), 2026-11-25: S,
          P (one role), no console input (skipped, exit 0), Update twice
          (second run: nothing added), an unknown privilege reported as
          left out, a new role created next to the updated ones

    v1.5.0  2026-11-18  Paul van Dieen
        - Progress bar during long steps (#12): "n of N: item", the
          percentage and the time left, in the export and import per role,
          and a second bar while the privileges of a role are looked up on
          the target. Updated at most every 250 ms; the bar disappears when
          the step ends. The log file is unchanged

    v1.4.0  2026-11-18  Paul van Dieen
        - On par with VDSPortGroupManager 1.6.1 and VIFolderManager 1.3.0 (#10)
        - Log file: everything the console shows also goes to
          Logs\VIRoleManager_<timestamp>.log next to the script (new
          -LogDirectory)
        - -Mode is optional: without it a menu asks for Export or Import
        - Without -FilePath an interactive run asks for the folder after the
          mode: Enter keeps the script directory (the default, as before), B
          opens the Windows folder browser, or type a path; Import shows how
          many JSON files the folder holds. -FilePath works as before, and
          also takes a wildcard on Import (every match is imported)
        - -RoleName takes several names or wildcards (unattended export of
          a set of roles); no match stops with the list of custom roles
        - Pickers: numbers, ranges (2-6), combinations, 'all', a name filter
          (*text* or /text, renumbered), 'list'/'reset', long lists
          shortened; cancel with cancel, exit, quit or q
        - Failures stand out: a role that fails to export or import is a red
          FAILED line with the vCenter message; the summary is red with
          failures, yellow with only skips (role already exists, privileges
          left out), green otherwise, and lists every failure. A run with
          failures ends with exit code 1 (was always 0). Without console
          input every prompt stops with a clear message and exit code 2

    v1.3.1  2026-11-18  Paul van Dieen
        - Get-Help shows the full help again: the changelog moved out of the
          help block into its own comment block (the unknown .CHANGELOG
          keyword made Get-Help ignore the whole help block)

    v1.3.0  2026-11-16  Paul van Dieen
        - Minimum PowerShell is now 7.4: VCF.PowerCLI 9.x needs PowerShell 7
          (KB 409981); #Requires, .NOTES and README updated (#1)
        - PowerCLI loading imports only VMware.VimAutomation.Core instead of
          the whole VCF.PowerCLI bundle, with -ErrorAction Stop (#3)
        - Stops up front when PowerCLI modules of different versions are
          already loaded in the session
        - Load failures show the short error, the loaded VMware.* modules and
          a link to the jump-host guide (one PowerCLI version per host,
          completeness check, pitfalls); same text as VDSPortGroupManager

    v1.2.3  2026-03-31  Paul van Dieen
        - Bug fix: script re-saved with UTF-8 BOM so PowerShell 5.1 reads em
          dash characters correctly instead of misinterpreting them as string
          terminators (U+201D) when using the system default ANSI code page

    v1.2.2  2026-03-31  Paul van Dieen
        - Bug fix: -f format strings changed from double-quoted to single-quoted
          to prevent PS5 from misinterpreting {n} format tokens as script blocks

    v1.2.1  2026-03-31  Paul van Dieen
        - Added #Requires -Version 5.1 for explicit PS5 compatibility

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

#Requires -Version 7.4

[CmdletBinding()]
param(
    [string]$vCenterServer = '',
    [ValidateSet('Export','Import')][string]$Mode = '',
    [string[]]$RoleName = @(),
    [string]$FilePath,
    [string]$NewRoleName,
    [ValidateSet('Ask','Skip','Update')][string]$ExistingRole = 'Ask',
    [string]$LogDirectory = '',
    [string]$CredentialPath,
    [switch]$SkipCertificateValidation,
    [switch]$ResetCredentials
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptVersion = '1.7.0'
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
# The script needs only VMware.VimAutomation.Core (and what it requires), not
# the whole VCF.PowerCLI bundle. Loading problems almost always come from the
# jump host (several PowerCLI versions side by side, an old one already loaded
# in the session, an incomplete or blocked offline install); the fix belongs
# there, so the script only explains what it found and where to read on.
$jumpHostGuide = 'https://vcf-planning.hollebollevsan.nl/docs/42-jump-host-powershell/'

function Stop-ModuleLoadFailure {
    param([string]$Reason)
    Write-Host '  [ERROR] Could not load PowerCLI (VMware.VimAutomation.Core).' -ForegroundColor Red
    if ($Reason) { Write-Host "          $Reason" -ForegroundColor Red }
    Write-Host '          Start a clean session with "pwsh -NoProfile" and run the script first.' -ForegroundColor Yellow
    Write-Host '          Keep one complete, unblocked PowerCLI version on this host; see the jump-host' -ForegroundColor Yellow
    Write-Host "          guide, section 4 (completeness check) and 6 (pitfalls): $jumpHostGuide" -ForegroundColor Yellow
    $loaded = @(Get-Module -Name VMware.*, VCF.PowerCLI)
    if ($loaded.Count -gt 0) {
        Write-Host '          Loaded now:' -ForegroundColor Yellow
        $loaded | Sort-Object Name | ForEach-Object {
            Write-Host "            $($_.Name) $($_.Version)  ($($_.ModuleBase))" -ForegroundColor Yellow
        }
    }
    exit 1
}
function Get-ShortError {
    param($ErrorRecord)
    $m = "$($ErrorRecord.Exception.Message)"
    if ($m -match "`t") { $m = @($m -split "`t" | Where-Object { $_.Trim() })[-1].Trim() }
    return $m
}

if (-not (Get-Module -ListAvailable -Name VMware.VimAutomation.Core)) {
    Write-Host '  [ERROR] No PowerCLI found (VMware.VimAutomation.Core is not installed).' -ForegroundColor Red
    Write-Host '          Install-Module -Name VCF.PowerCLI -Scope CurrentUser' -ForegroundColor Yellow
    Write-Host "          Without internet access: $jumpHostGuide (section 3)" -ForegroundColor Yellow
    exit 1
}

# All VMware.VimAutomation.* modules of one PowerCLI release share one version
# (13.5.1.x for VCF.PowerCLI 9.1.1); StorageUtility is versioned on its own.
$loadedVersions = @(Get-Module -Name VMware.VimAutomation.* |
    Where-Object { $_.Name -ne 'VMware.VimAutomation.StorageUtility' } |
    ForEach-Object { "$($_.Version)" } | Select-Object -Unique)
if ($loadedVersions.Count -gt 1) {
    Stop-ModuleLoadFailure -Reason "PowerCLI modules of different versions are already loaded in this session ($($loadedVersions -join ', '))."
}

try {
    Import-Module -Name VMware.VimAutomation.Core -ErrorAction Stop -WarningAction SilentlyContinue 6>$null
}
catch {
    Stop-ModuleLoadFailure -Reason (Get-ShortError $_)
}
Write-Host "  [INFO] PowerCLI $(@(Get-Module -Name VMware.VimAutomation.Core)[0].Version) loaded." -ForegroundColor Cyan

# --- Logging Setup --------------------------------------------------------------
# (#10) Everything the console shows also goes to a timestamped log file.
$scriptDirLogs = if ($LogDirectory) { $LogDirectory } else { Join-Path $scriptDir 'Logs' }
if (-not (Test-Path -Path $scriptDirLogs)) { New-Item -ItemType Directory -Path $scriptDirLogs -Force | Out-Null }
$timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$LogFile   = Join-Path $scriptDirLogs "VIRoleManager_$timestamp.log"

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')]
        [string]$Level = 'INFO'
    )
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry
    switch ($Level) {
        'SUCCESS' { Write-Host "  $entry" -ForegroundColor Green  }
        'WARNING' { Write-Host "  $entry" -ForegroundColor Yellow }
        'ERROR'   { Write-Host "  $entry" -ForegroundColor Red    }
        default   { Write-Host "  $entry" -ForegroundColor Cyan   }
    }
}

# --- Run results (#10, as VDSPortGroupManager #20) --------------------------------
# Every role that fails to export or import is logged as an ERROR (red) and
# collected, so the summary names them with the reason and the
# run ends with exit code 1 (0 = no failures, 2 = stopped for lack of console
# input).
$script:RunFailures = [System.Collections.Generic.List[object]]::new()

function Get-FailReason {
    # The vCenter message without PowerShell's wrapper: 'Exception calling
    # "CreateDVPortgroup" with "1" argument(s): "..."', or PowerCLI's
    # tab-separated 'timestamp<TAB>cmdlet<TAB>detail'.
    param($ErrorRecord)
    $m = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { "$($ErrorRecord.Exception.Message)" } else { "$ErrorRecord" }
    if ($m -match "`t") { $m = @($m -split "`t" | Where-Object { $_.Trim() })[-1].Trim() }
    if ($m -match '^Exception calling "[^"]+" with "\d+" argument\(s\): "(.*)"$') { $m = $Matches[1] }
    return $m.Trim()
}

function Add-RunFailure {
    param([string]$Action, [string]$Name, [string]$Reason)
    $script:RunFailures.Add([pscustomobject]@{ Action = $Action; Name = $Name; Reason = $Reason })
    Write-Log "FAILED $($Action.ToLower()) '$Name': $Reason" -Level ERROR
}

function Write-RunSummary {
    # One summary line, coloured by outcome, then the failures of these actions.
    param([string]$Line, [int]$Failed, [int]$Skipped = 0, [string[]]$Actions = @())
    $level = if ($Failed -gt 0) { 'ERROR' } elseif ($Skipped -gt 0) { 'WARNING' } else { 'SUCCESS' }
    Write-Log $Line -Level $level
    $mine = @($script:RunFailures | Where-Object { $Actions -contains $_.Action })
    if ($mine.Count -gt 0) {
        Write-Log "  Failed ($($mine.Count)):" -Level ERROR
        foreach ($f in $mine) { Write-Log "    - $($f.Name): $($f.Reason)" -Level ERROR }
    }
}

# --- Progress (#12) -------------------------------------------------------------
# A progress bar per long step: "12 of 637: name", percentage and time left.
# Updated at most every 250 ms, so thousands of items don't slow the run down;
# Complete-Progress removes the bar. Id 1 is the outer step, Id 2 the items
# inside it. The log file is unchanged.
$script:ProgressState = @{}
function Show-Progress {
    param(
        [Parameter(Mandatory = $true)][string]$Activity,
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][int]$Total,
        [string]$Item = '',
        [int]$Id = 1,
        [int]$ParentId = -1
    )
    if ($Total -le 0) { return }
    $now = [DateTime]::UtcNow
    if (-not $script:ProgressState.ContainsKey($Id) -or $Index -le 1) {
        $script:ProgressState[$Id] = @{ Start = $now; Last = [DateTime]::MinValue }
    }
    $st = $script:ProgressState[$Id]
    if ($Index -gt 1 -and $Index -lt $Total -and ($now - $st.Last).TotalMilliseconds -lt 250) { return }
    $st.Last = $now
    $p = @{
        Id              = $Id
        Activity        = $Activity
        Status          = "$Index of $Total$(if ($Item) { ": $Item" })"
        PercentComplete = [Math]::Min(100, [int](100 * ($Index - 1) / $Total))
    }
    if ($Index -gt 1) {
        $perItem = ($now - $st.Start).TotalSeconds / ($Index - 1)
        $p.SecondsRemaining = [int]($perItem * ($Total - $Index + 1))
    }
    if ($ParentId -ge 0) { $p.ParentId = $ParentId }
    Write-Progress @p
}

function Complete-Progress {
    param([int]$Id = 1)
    $null = $script:ProgressState.Remove($Id)
    Write-Progress -Id $Id -Activity 'Done' -Completed
}

# --- Menu Functions -------------------------------------------------------------
# Long lists: above $PickerListMax items the picker shows a count and a few
# examples and asks for a filter first; above $PickerEchoMax selected items
# the confirmation shows the count plus the first and last few (#4).
$PickerListMax = 50
$PickerEchoMax = 20

# Words that abort a picker or prompt (#13); -in is case-insensitive.
$CancelWords = @('cancel', 'exit', 'quit', 'q')
function Test-CancelInput {
    param([string]$Text)
    return ($Text -in $CancelWords)
}

# Every prompt goes through Read-Input (#11): without console input (a
# scheduled task, CI, pwsh -NonInteractive, redirected stdin) Read-Host
# throws or returns $null; stop with a clear message instead of a
# null-valued-expression error.
function Stop-NoConsoleInput {
    param([string]$Prompt)
    Write-Host "`n  [ERROR] No console input available (unattended run?). The script asked: $($Prompt.Trim())" -ForegroundColor Red
    Write-Host '  Pass the choices as parameters instead: -Mode, -RoleName (Export) or -FilePath (Import), and' -ForegroundColor Yellow
    Write-Host '  -FilePath for the folder. Save the credential first with one interactive run.' -ForegroundColor Yellow
    $conn = Get-Variable -Name viConn -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($conn) { Disconnect-VIServer -Server $conn -Confirm:$false -ErrorAction SilentlyContinue }
    exit 2
}

function Read-Input {
    param([string]$Prompt, [switch]$AsSecureString)
    try {
        $value = if ($AsSecureString) { Read-Host $Prompt -AsSecureString } else { Read-Host $Prompt }
    }
    catch {
        $value = $null
    }
    if ($null -eq $value) { Stop-NoConsoleInput -Prompt $Prompt }
    if ($AsSecureString) { return $value }
    return $value.Trim()
}

function Write-ItemList {
    param([array]$Items, [string]$DisplayProperty, [switch]$Full)
    $width = "$($Items.Count)".Length
    $fmt   = '  [{0,' + $width + '}]  {1}'
    if ($Full -or $Items.Count -le $PickerListMax) {
        for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ($fmt -f ($i + 1), $Items[$i].$DisplayProperty) }
        return
    }
    for ($i = 0; $i -lt 5; $i++) { Write-Host ($fmt -f ($i + 1), $Items[$i].$DisplayProperty) }
    Write-Host ('  ' + (' ' * ($width + 2)) + "  ... $($Items.Count - 10) more ...") -ForegroundColor DarkGray
    for ($i = $Items.Count - 5; $i -lt $Items.Count; $i++) { Write-Host ($fmt -f ($i + 1), $Items[$i].$DisplayProperty) }
    Write-Host "`n  $($Items.Count) items: too many to list. Narrow the list with a filter, or type 'list' to show them all." -ForegroundColor Yellow
}

function Write-SelectionSummary {
    param([array]$Selected, [string]$DisplayProperty)
    Write-Host "`n  Selected $($Selected.Count) item(s):" -ForegroundColor Green
    if ($Selected.Count -le $PickerEchoMax) {
        $Selected | ForEach-Object { Write-Host "    - $($_.$DisplayProperty)" -ForegroundColor White }
    }
    else {
        $Selected[0..4] | ForEach-Object { Write-Host "    - $($_.$DisplayProperty)" -ForegroundColor White }
        Write-Host "    ... $($Selected.Count - 10) more ..." -ForegroundColor DarkGray
        $Selected[($Selected.Count - 5)..($Selected.Count - 1)] | ForEach-Object { Write-Host "    - $($_.$DisplayProperty)" -ForegroundColor White }
    }
    Write-Host ''
}

function Select-ItemsByName {
    # Non-interactive selection by name: every item
    # whose name matches one of the patterns (names or wildcards, -like).
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$NameProperty,
        [Parameter(Mandatory = $true)][string]$DisplayProperty,
        [Parameter(Mandatory = $true)][string[]]$Patterns,
        [string]$What = 'item'
    )
    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($pattern in $Patterns) {
        $hits = @($Items | Where-Object { $_.$NameProperty -like $pattern })
        if ($hits.Count -eq 0) {
            Write-Log "No $What matches '$pattern'." -Level WARNING
        }
        foreach ($hit in $hits) { if (-not $selected.Contains($hit)) { $selected.Add($hit) } }
    }
    if ($selected.Count -gt 0) {
        Write-Log "Selected $($selected.Count) $What(s) by name: $($Patterns -join ', ')"
        Write-SelectionSummary -Selected @($selected) -DisplayProperty $DisplayProperty
    }
    return @($selected)
}

function Select-MultipleItems {
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$DisplayProperty,
        [Parameter(Mandatory = $true)][string]$Title,
        # Property the filter matches on (defaults to the display text)
        [string]$NameProperty = ''
    )
    if ($Items.Count -eq 0) {
        Write-Host '  No items available to select.' -ForegroundColor Yellow
        return @()
    }
    if (-not $NameProperty) { $NameProperty = $DisplayProperty }
    $view   = $Items
    $filter = ''
    Write-Host "`n  $Title" -ForegroundColor Cyan
    Write-ItemList -Items $view -DisplayProperty $DisplayProperty
    Write-Host "`n  Enter numbers (e.g. 1,3,5), a range (e.g. 2-6), a combination (e.g. 1,3-5,8)," -ForegroundColor Gray
    Write-Host "  'all' to select every item shown, or 'cancel' (or exit, quit, q) to abort." -ForegroundColor Gray
    Write-Host "  Filter by name: a wildcard (e.g. *prod*) or /text for a substring; 'reset' clears" -ForegroundColor Gray
    Write-Host "  the filter, 'list' shows every item in the current list.`n" -ForegroundColor Gray
    while ($true) {
        $prompt    = if ($filter) { "  Your selection (filter: $filter, $($view.Count) shown)" } else { '  Your selection' }
        $userInput = Read-Input $prompt
        if (Test-CancelInput $userInput) {
            Write-Host '  Cancelled.' -ForegroundColor Yellow
            return @()
        }
        if ($userInput -eq 'list') {
            Write-ItemList -Items $view -DisplayProperty $DisplayProperty -Full
            continue
        }
        if ($userInput -eq 'reset' -or ($userInput -eq '' -and $filter)) {
            $view = $Items; $filter = ''
            Write-Host "`n  Filter cleared: $($view.Count) item(s)." -ForegroundColor Cyan
            Write-ItemList -Items $view -DisplayProperty $DisplayProperty
            continue
        }
        if ($userInput -match '[*?]' -or $userInput.StartsWith('/')) {
            $pattern = if ($userInput.StartsWith('/')) { '*' + [WildcardPattern]::Escape($userInput.Substring(1)) + '*' } else { $userInput }
            $hits    = @($Items | Where-Object { $_.$NameProperty -like $pattern })
            if ($hits.Count -eq 0) {
                Write-Host "  Nothing matches '$userInput'; the list is unchanged." -ForegroundColor Yellow
                continue
            }
            $view = $hits; $filter = $userInput
            Write-Host "`n  Filter '$filter': $($view.Count) of $($Items.Count) item(s), renumbered." -ForegroundColor Cyan
            Write-ItemList -Items $view -DisplayProperty $DisplayProperty
            continue
        }
        if ($userInput -eq '') { continue }
        if ($userInput -eq 'all') {
            if ($view.Count -gt $PickerListMax -and -not $filter) {
                Write-Host "  'all' selects all $($view.Count) item(s)." -ForegroundColor Yellow
            }
            Write-SelectionSummary -Selected $view -DisplayProperty $DisplayProperty
            return $view
        }
        $selectedIndices = @()
        $parts           = $userInput -split ','
        $parseError      = $false
        foreach ($part in $parts) {
            $part = $part.Trim()
            if ($part -match '^\d+$') {
                $selectedIndices += [int]$part
            }
            elseif ($part -match '^(\d+)-(\d+)$') {
                $start = [int]$Matches[1]
                $end   = [int]$Matches[2]
                if ($start -gt $end) {
                    Write-Host "  Invalid range: $part (start must be equal to or less than end)." -ForegroundColor Red
                    $parseError = $true
                    break
                }
                $selectedIndices += $start..$end
            }
            else {
                Write-Host "  Unrecognised input: '$part'. Use numbers, ranges like 2-5, 'all', or a filter (*text* or /text)." -ForegroundColor Red
                $parseError = $true
                break
            }
        }
        if ($parseError) { continue }
        $selectedIndices = $selectedIndices | Sort-Object -Unique
        $invalid         = $selectedIndices | Where-Object { $_ -lt 1 -or $_ -gt $view.Count }
        if ($invalid) {
            Write-Host "  Out-of-range: $($invalid -join ', '). Valid range is 1-$($view.Count)." -ForegroundColor Red
            continue
        }
        $selected = @($selectedIndices | ForEach-Object { $view[$_ - 1] })
        Write-SelectionSummary -Selected $selected -DisplayProperty $DisplayProperty
        return $selected
    }
}

function Select-SingleItem {
    # One item. With -Filter the list can be narrowed like the multi picker
    # (wildcard or /text, 'reset', 'list'); used for the export file list,
    # which grows with every export (#10).
    param(
        [Parameter(Mandatory = $true)][array]$Items,
        [Parameter(Mandatory = $true)][string]$DisplayProperty,
        [Parameter(Mandatory = $true)][string]$Title,
        [switch]$Filter
    )
    if ($Items.Count -eq 0) {
        Write-Host '  No items available to select.' -ForegroundColor Yellow
        return $null
    }
    $view = $Items
    $flt  = ''
    Write-Host "`n  $Title" -ForegroundColor Cyan
    if ($Filter) { Write-ItemList -Items $view -DisplayProperty $DisplayProperty }
    else { Write-ItemList -Items $view -DisplayProperty $DisplayProperty -Full }
    Write-Host "`n  Enter a number to select one item, or 'cancel' (or exit, quit, q) to abort." -ForegroundColor Gray
    if ($Filter) {
        Write-Host "  Filter by name: a wildcard (e.g. *prod*) or /text for a substring; 'reset' clears" -ForegroundColor Gray
        Write-Host "  the filter, 'list' shows every item in the current list." -ForegroundColor Gray
    }
    Write-Host ''
    while ($true) {
        $prompt    = if ($flt) { "  Your selection (filter: $flt, $($view.Count) shown)" } else { '  Your selection' }
        $userInput = Read-Input $prompt
        if (Test-CancelInput $userInput) {
            Write-Host '  Cancelled.' -ForegroundColor Yellow
            return $null
        }
        if ($Filter -and $userInput -eq 'list') {
            Write-ItemList -Items $view -DisplayProperty $DisplayProperty -Full
            continue
        }
        if ($Filter -and ($userInput -eq 'reset' -or ($userInput -eq '' -and $flt))) {
            $view = $Items; $flt = ''
            Write-Host "`n  Filter cleared: $($view.Count) item(s)." -ForegroundColor Cyan
            Write-ItemList -Items $view -DisplayProperty $DisplayProperty
            continue
        }
        if ($Filter -and ($userInput -match '[*?]' -or $userInput.StartsWith('/'))) {
            $pattern = if ($userInput.StartsWith('/')) { '*' + [WildcardPattern]::Escape($userInput.Substring(1)) + '*' } else { $userInput }
            $hits    = @($Items | Where-Object { $_.$DisplayProperty -like $pattern })
            if ($hits.Count -eq 0) {
                Write-Host "  Nothing matches '$userInput'; the list is unchanged." -ForegroundColor Yellow
                continue
            }
            $view = $hits; $flt = $userInput
            Write-Host "`n  Filter '$flt': $($view.Count) of $($Items.Count) item(s), renumbered." -ForegroundColor Cyan
            Write-ItemList -Items $view -DisplayProperty $DisplayProperty
            continue
        }
        if ($userInput -match '^\d+$') {
            $index = [int]$userInput
            if ($index -ge 1 -and $index -le $view.Count) {
                $selected = $view[$index - 1]
                Write-Host "`n  Selected: $($selected.$DisplayProperty)`n" -ForegroundColor Green
                return $selected
            }
        }
        Write-Host "  Invalid selection. Enter a number between 1 and $($view.Count)." -ForegroundColor Red
    }
}

function Select-FolderTypes {
    param([string[]]$Available = @($folderTypeMap.Keys))
    $items = @($Available | ForEach-Object { [pscustomobject]@{ Label = "$_ folders"; Value = $_ } })
    $choice = Select-MultipleItems -Items $items -DisplayProperty 'Label' -Title 'Select folder types'
    return @($choice | ForEach-Object { $_.Value })
}

# --- vCenter (W38) -------------------------------------------------------------
# Without -vCenterServer: ask for it, with the vCenters that have a saved
# credential (<host>.cred next to the script; file names only) as numbers.
if (-not $vCenterServer) {
    $savedVc = @(Get-ChildItem -LiteralPath $scriptDir -Filter '*.cred' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | ForEach-Object { $_.BaseName })
    Write-Host "`n  vCenter Server" -ForegroundColor Cyan
    if ($savedVc.Count -gt 0) {
        Write-Host '  Saved credential for:' -ForegroundColor DarkGray
        for ($i = 0; $i -lt $savedVc.Count; $i++) { Write-Host ("    [{0}] {1}" -f ($i + 1), $savedVc[$i]) }
        Write-Host "  Type a number, or the FQDN or IP of another vCenter ('q' to quit)." -ForegroundColor DarkGray
    } else {
        Write-Host "  Type the FQDN or IP of the vCenter ('q' to quit)." -ForegroundColor DarkGray
    }
    while (-not $vCenterServer) {
        $answer = Read-Input '  vCenter'
        if (-not $answer) { continue }
        if (Test-CancelInput $answer) { Write-Host '  Cancelled.' -ForegroundColor Yellow; exit 0 }
        if ($answer -match '^\d+$' -and $savedVc.Count -gt 0) {
            $n = [int]$answer
            if ($n -ge 1 -and $n -le $savedVc.Count) { $vCenterServer = $savedVc[$n - 1]; Write-Host "  [OK]   $vCenterServer" -ForegroundColor Green }
            else { Write-Host "  Enter a number between 1 and $($savedVc.Count), or a name." -ForegroundColor Red }
            continue
        }
        $answer = $answer -replace '^https?://', '' -replace '/+$', ''
        if ($answer -match '\s') { Write-Host '  A name or IP has no spaces.' -ForegroundColor Red; continue }
        $vCenterServer = $answer
    }
}

# Errors nothing else catches end the run with one red line and exit code 1,
# instead of PowerShell's error record (W38)
trap {
    try { Write-Log "Stopped on an unexpected error at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)" -Level ERROR } catch { Write-Host "  [ERROR] $($_.Exception.Message)" -ForegroundColor Red }
    try { $script:LogWriter.Dispose() } catch { }
    exit 1
}
# --- Interactive Mode Menu ------------------------------------------------------
if (-not $Mode) {
    $modeOptions = @(
        [pscustomobject]@{ Label = 'Export  - save roles to JSON files'; Value = 'Export' }
        [pscustomobject]@{ Label = 'Import  - create roles from JSON files'; Value = 'Import' }
    )
    $modeChoice = Select-SingleItem -Items $modeOptions -DisplayProperty 'Label' -Title 'Select operation mode'
    if (-not $modeChoice) {
        Write-Host '  No mode selected. Exiting.' -ForegroundColor Yellow
        exit 0
    }
    $Mode = $modeChoice.Value
}
if ($RoleName.Count -gt 0 -and $Mode -ne 'Export') {
    Write-Host '  [WARN] -RoleName only applies in Export mode and will be ignored.' -ForegroundColor Yellow
}
if ($NewRoleName -and $Mode -ne 'Import') {
    Write-Host '  [WARN] -NewRoleName only applies in Import mode and will be ignored.' -ForegroundColor Yellow
}
if ($PSBoundParameters.ContainsKey('ExistingRole') -and $Mode -ne 'Import') {
    Write-Host '  [WARN] -ExistingRole only applies in Import mode and will be ignored.' -ForegroundColor Yellow
}

# --- Folder (#10, as VDSPortGroupManager #18) ---------------------------------------
# Without -FilePath an interactive run asks for the folder: Enter keeps the
# script folder (the default, as before), B opens the Windows folder browser,
# or type a path. No prompt with -FilePath, or for an export with -RoleName.
function Test-FolderDialogAvailable {
    if (-not $IsWindows) { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { return $false }
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop; return $true }
    catch { return $false }
}

function Select-FolderDialog {
    param([string]$Description, [string]$StartPath)
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = $Description
    $dialog.UseDescriptionForTitle = $true
    $dialog.ShowNewFolderButton = $true
    if ($StartPath -and (Test-Path -Path $StartPath -PathType Container)) { $dialog.SelectedPath = (Resolve-Path $StartPath).Path }
    # A hidden top-most owner keeps the dialog in front of the console window.
    $owner = [System.Windows.Forms.Form]::new()
    $owner.TopMost = $true
    $owner.ShowInTaskbar = $false
    $owner.WindowState = 'Minimized'
    try {
        if ($dialog.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
        return $null
    }
    finally {
        $dialog.Dispose()
        $owner.Dispose()
    }
}

function Get-BackupCount {
    param([string]$Path)
    return @(Get-ChildItem -Path $Path -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
}

function Get-BackupCount {
    param([string]$Path)
    return @(Get-ChildItem -Path $Path -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
}

if (-not $FilePath -and -not ($Mode -eq 'Export' -and $RoleName.Count -gt 0)) {
    $folder    = $scriptDir
    $canBrowse = Test-FolderDialogAvailable
    $purpose   = if ($Mode -eq 'Import') { 'to import from' } else { 'to export to' }
    while ($true) {
        Write-Host "`n  Folder ${purpose}:" -ForegroundColor Cyan
        Write-Host "    $folder"
        if ($Mode -eq 'Import' -and (Test-Path -Path $folder -PathType Container)) {
            Write-Host "    ($(Get-BackupCount $folder) JSON file(s) here)" -ForegroundColor DarkGray
        }
        $hint = if ($canBrowse) { "  [Enter] use it, [B] browse, or type a path ('q' to quit)" } else { "  [Enter] use it, or type a path ('q' to quit)" }
        $answer = Read-Input $hint
        if (Test-CancelInput $answer) {
            Write-Host '  Cancelled.' -ForegroundColor Yellow
            exit 0
        }
        $candidate = $folder
        if ($canBrowse -and $answer -match '^[Bb]$') {
            $picked = Select-FolderDialog -Description 'Select the folder with the role exports (.json)' -StartPath $folder
            if (-not $picked) { Write-Host '  No folder chosen.' -ForegroundColor Yellow; continue }
            $candidate = $picked
        }
        elseif ($answer) {
            $candidate = $answer.Trim('"', "'")
        }
        if ($Mode -eq 'Import') {
            if (-not (Test-Path -Path $candidate -PathType Container)) {
                Write-Host "  Folder not found: $candidate" -ForegroundColor Red
                continue
            }
            $count = Get-BackupCount $candidate
            if ($count -eq 0) {
                Write-Host "  No JSON files in $candidate. Choose another folder." -ForegroundColor Red
                $folder = $candidate
                continue
            }
            Write-Host "  [OK]   $count JSON file(s) in $candidate." -ForegroundColor Green
        }
        elseif (Test-Path -Path $candidate -PathType Leaf) {
            Write-Host "  That is a file, not a folder: $candidate" -ForegroundColor Red
            continue
        }
        $FilePath = $candidate
        break
    }
}

# --- Credential Management ----------------------------------------------------
$safeVc = $vCenterServer -replace '[^\w\-.]', '_'
if (-not $CredentialPath) { $CredentialPath = Join-Path $scriptDir "$safeVc.cred" }

if ($ResetCredentials -or -not (Test-Path $CredentialPath)) {
    if ($ResetCredentials) {
        Write-Host '  [WARN] -ResetCredentials specified - prompting for new credentials.' -ForegroundColor Yellow
    } else {
        Write-Host '  [INFO] No saved credentials found - prompting.' -ForegroundColor Cyan
    }
    $credUser   = Read-Input "  Username for $vCenterServer"
    $credPass   = Read-Input '  Password' -AsSecureString
    $credential = [System.Management.Automation.PSCredential]::new($credUser, $credPass)
    $credential | Export-Clixml -Path $CredentialPath
    Write-Host "  [OK]   Credentials saved to $CredentialPath." -ForegroundColor Green
} else {
    Write-Host "  [INFO] Loading saved credentials from $CredentialPath." -ForegroundColor Cyan
    $credential = Import-Clixml -Path $CredentialPath
}

# --- Connect to vCenter -------------------------------------------------------
Write-Log "===== VIRoleManager started (Mode: $Mode) ====="
Write-Log "vCenter:  $vCenterServer"
Write-Log "Folder:   $(if ($FilePath) { $FilePath } else { $scriptDir })"
Write-Log "Log File: $LogFile"
Write-Log "Connecting to $vCenterServer ..."
# An untrusted certificate is no longer accepted silently (#9, W20):
# without -SkipCertificateValidation PowerCLI fails on it, and the script asks
# whether to go on without the check for this run.
$certAction = if ($SkipCertificateValidation) { 'Ignore' } else { 'Fail' }
$viConn = $null
while (-not $viConn) {
    try {
        $null = Set-PowerCLIConfiguration -InvalidCertificateAction $certAction `
            -Confirm:$false -Scope Session -WarningAction SilentlyContinue
        $viConn = Connect-VIServer -Server $vCenterServer -Credential $credential -ErrorAction Stop -WarningAction SilentlyContinue
        Write-Log "Connected to $vCenterServer (version $($viConn.Version), build $($viConn.Build))." -Level SUCCESS
    } catch {
        $reason = Get-FailReason $_
        if ($certAction -eq 'Fail' -and $reason -match '(?i)certificate') {
            Write-Log "The certificate of $vCenterServer is not trusted by this machine (self-signed, or its CA is not imported)." -Level WARNING
            Write-Host '  Unattended runs: pass -SkipCertificateValidation, or trust the certificate.' -ForegroundColor DarkGray
            $answer = Read-Input '  Continue without checking the certificate for this run? (y/N)'
            if ($answer -match '^(y|yes|j|ja)$') {
                $certAction = 'Ignore'
                $SkipCertificateValidation = [switch]$true
                Write-Log 'Certificate check off for this run. Next time add -SkipCertificateValidation.' -Level WARNING
                continue
            }
        }
        Write-Log "Failed to connect to vCenter '$vCenterServer': $reason" -Level ERROR
        exit 1
    }
}
# =============================================================================
# EXPORT
# =============================================================================
if ($Mode -eq 'Export') {
    Write-Log '--- EXPORT MODE ---'
    # -FilePath: a folder (existing, or a path without extension), or one file
    # when a single role is exported; the script folder otherwise (as before)
    $outDir = if ($FilePath -and (Test-Path $FilePath -PathType Container)) {
        $FilePath
    } elseif ($FilePath -and -not [System.IO.Path]::GetExtension($FilePath)) {
        $FilePath
    } else {
        $scriptDir
    }
    $all = @(Get-VIRole -Server $viConn -ErrorAction Stop | Where-Object { -not $_.IsSystem } | Sort-Object Name)
    $items = @($all | ForEach-Object {
        [pscustomobject]@{ Label = ('{0,-45} ({1} privileges)' -f $_.Name, @($_.ExtensionData.Privilege).Count); Name = $_.Name; Item = $_ }
    })
    $choices = @()
    if ($items.Count -eq 0) {
        Write-Log "No custom roles found on $vCenterServer." -Level WARNING
    } elseif ($RoleName.Count -gt 0) {
        $choices = @(Select-ItemsByName -Items $items -NameProperty 'Name' -DisplayProperty 'Label' -Patterns $RoleName -What 'role')
        if ($choices.Count -eq 0) {
            Write-Log "No role matches -RoleName $($RoleName -join ', '). Roles on this vCenter: $(@($items | ForEach-Object { $_.Name }) -join ', ')" -Level ERROR
            Disconnect-VIServer -Server $viConn -Confirm:$false -ErrorAction SilentlyContinue
            exit 1
        }
    } else {
        $choices = @(Select-MultipleItems -Items $items -DisplayProperty 'Label' -NameProperty 'Name' -Title 'Roles on this vCenter: select the ones to EXPORT')
    }

    if ($choices.Count -gt 0) {
        if (-not (Test-Path -Path $outDir)) { $null = New-Item -ItemType Directory -Path $outDir -Force }
        $exportOk = 0
        $no = 0
        foreach ($choice in $choices) {
            $role = $choice.Item
            $no++
            Show-Progress -Activity 'Exporting roles' -Index $no -Total $choices.Count -Item $role.Name
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

                # -FilePath with an extension and one role: that file; otherwise the folder
                $outFile = if ($FilePath -and $choices.Count -eq 1 -and [System.IO.Path]::GetExtension($FilePath) -ne '') {
                    $FilePath
                } else {
                    $safeName = $role.Name -replace '[^\w\-]', '_'
                    Join-Path $outDir "$safeName.json"
                }

                if (-not (Test-Path (Split-Path $outFile -Parent))) {
                    $null = New-Item -ItemType Directory -Path (Split-Path $outFile -Parent) -Force
                }

                $export | ConvertTo-Json -Depth 5 | Out-File -FilePath $outFile -Encoding UTF8
                Write-Log "Exported '$($role.Name)', $($privileges.Count) privilege(s), to: $outFile" -Level SUCCESS
                $exportOk++
            } catch {
                Add-RunFailure -Action 'Export' -Name $role.Name -Reason (Get-FailReason $_)
            }
        }
        Complete-Progress
        $exportFail = @($script:RunFailures | Where-Object { $_.Action -eq 'Export' }).Count
        Write-RunSummary -Line "Export complete: $exportOk role(s) exported, $exportFail failed." -Failed $exportFail -Actions 'Export'
    } elseif ($items.Count -gt 0) {
        Write-Log 'Nothing selected. Skipping export.' -Level WARNING
    }
}

# =============================================================================
# IMPORT
# =============================================================================
if ($Mode -eq 'Import') {
    Write-Log '--- IMPORT MODE ---'
    # -FilePath: a file, a wildcard (every match is imported), or a folder to
    # pick from; the script folder when omitted (as before)
    $files = @()
    if ($FilePath -and (Test-Path $FilePath -PathType Container)) {
        $json = @(Get-ChildItem -Path $FilePath -Filter '*.json' -File | Sort-Object Name)
        if ($json.Count -eq 0) {
            Write-Log "No JSON files found in $FilePath." -Level WARNING
        } elseif ($json.Count -eq 1) {
            Write-Log "Found 1 file: $($json[0].Name)"
            $files = @($json[0])
        } else {
            $fileItems = @($json | ForEach-Object {
                $label = $_.Name
                try {
                    $peek = Get-Content $_.FullName -Raw | ConvertFrom-Json
                    $peekName = if ($peek.PSObject.Properties['RoleName']) { $peek.RoleName } else { '?' }
                    $peekInfo = if ($peek.PSObject.Properties['PrivilegeCount']) { "$($peek.PrivilegeCount) privileges" } else { '?' }
                    $label = '{0,-35} role: {1,-30} ({2})' -f $_.Name, $peekName, $peekInfo
                } catch { }
                [pscustomobject]@{ Label = $label; Name = $_.Name; Item = $_ }
            })
            $files = @(Select-MultipleItems -Items $fileItems -DisplayProperty 'Label' -NameProperty 'Name' -Title "JSON files in $FilePath`: select the ones to IMPORT" | ForEach-Object { $_.Item })
        }
    } else {
        $files = @(Get-ChildItem -Path $FilePath -File -ErrorAction SilentlyContinue | Sort-Object Name)
        if ($files.Count -eq 0) {
            Write-Log "-FilePath not found: $FilePath" -Level ERROR
            Disconnect-VIServer -Server $viConn -Confirm:$false -ErrorAction SilentlyContinue
            exit 1
        }
    }

    if ($files.Count -eq 0) {
        Write-Log 'No files selected. Skipping import.' -Level WARNING
    } else {
        # Roles that already exist on the target (#17): skip them (as before),
        # or add the privileges they miss compared with the export, for
        # example plugin privileges that were left out because the plugin was
        # not registered on the target yet at the first import.
        $existingNames = @(Get-VIRole -Server $viConn -ErrorAction Stop | ForEach-Object { $_.Name })
        $existingPlan  = @(foreach ($file in $files) {
            try {
                $peek = Get-Content -Path $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
                $peekTarget = if ($NewRoleName -and $files.Count -eq 1) { $NewRoleName } else { $peek.RoleName }
                if ($existingNames -contains $peekTarget) {
                    [pscustomobject]@{ Name = $peekTarget; Label = ('{0,-45} (from {1})' -f $peekTarget, $file.Name) }
                }
            } catch { }   # an unreadable file fails in the import loop, with its reason
        })
        $updateNames = @()
        if ($existingPlan.Count -gt 0) {
            if ($ExistingRole -eq 'Update') {
                $updateNames = @($existingPlan | ForEach-Object { $_.Name })
            } elseif ($ExistingRole -eq 'Ask') {
                Write-Host "`n  $($existingPlan.Count) role(s) already exist on ${vCenterServer}:" -ForegroundColor Cyan
                Write-ItemList -Items $existingPlan -DisplayProperty 'Label'
                Write-Host "`n  [S] skip them (default), [U] update them all: add the privileges they miss," -ForegroundColor Gray
                Write-Host "  [P] pick the roles to update, or 'cancel' (or exit, quit, q) to stop." -ForegroundColor Gray
                Write-Host '  Updating only adds privileges; it never removes any.' -ForegroundColor Gray
                while ($true) {
                    # No console input (unattended run): skip, as before; no exit 2 here.
                    $answer = $null
                    try { $answer = Read-Host '  Existing roles' } catch { }
                    if ($null -eq $answer) {
                        Write-Log 'No console input: existing roles are skipped. Pass -ExistingRole Update to add the privileges they miss.' -Level WARNING
                        break
                    }
                    $answer = $answer.Trim()
                    if (Test-CancelInput $answer) {
                        Write-Log 'Cancelled at the existing-roles question; nothing imported.' -Level WARNING
                        Disconnect-VIServer -Server $viConn -Confirm:$false -ErrorAction SilentlyContinue
                        exit 0
                    }
                    if ($answer -eq '' -or $answer -match '^[Ss]$') { break }
                    if ($answer -match '^[Uu]$') { $updateNames = @($existingPlan | ForEach-Object { $_.Name }); break }
                    if ($answer -match '^[Pp]$') {
                        $updateNames = @(Select-MultipleItems -Items $existingPlan -DisplayProperty 'Label' -NameProperty 'Name' -Title 'Existing roles: select the ones to UPDATE' | ForEach-Object { $_.Name })
                        break
                    }
                    Write-Host '  Type S, U or P.' -ForegroundColor Red
                }
            }
            if ($updateNames.Count -gt 0) {
                Write-Log "Existing role(s) to update (missing privileges added): $($updateNames -join ', ')"
            }
        }

        $created = 0; $skipped = 0; $partial = 0; $updated = 0; $current = 0
        $no = 0
        foreach ($file in $files) {
            $no++
            Show-Progress -Activity 'Importing roles' -Index $no -Total $files.Count -Item $file.Name
            try {
                Write-Log "Reading $($file.Name) ..."
                $import = Get-Content -Path $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
                # -NewRoleName only applies when importing a single file
                $targetName = if ($NewRoleName -and $files.Count -eq 1) { $NewRoleName } else { $import.RoleName }
                Write-Log "Importing '$($import.RoleName)' as '$targetName' ($(@($import.Privileges).Count) privilege(s), exported from $($import.ExportedFrom) on $($import.ExportedAt))."

                # Exact name only: -Name also takes wildcards
                $existing = Get-VIRole -Server $viConn -Name $targetName -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq $targetName } | Select-Object -First 1
                if ($existing -and $updateNames -notcontains $targetName) {
                    Write-Log "Role '$targetName' already exists: skipped. Use -ExistingRole Update to add the privileges it misses, or -NewRoleName to import it under another name." -Level WARNING
                    $skipped++
                    continue
                }

                # Resolve privileges, scoped to this vCenter only
                $privsToAdd  = [System.Collections.Generic.List[object]]::new()
                $skippedList = [System.Collections.Generic.List[string]]::new()
                $privList = @($import.Privileges)
                $privNo = 0
                foreach ($privId in $privList) {
                    $privNo++
                    Show-Progress -Id 2 -ParentId 1 -Activity "Resolving the privileges of '$targetName'" -Index $privNo -Total $privList.Count -Item $privId
                    $priv = Get-VIPrivilege -Server $viConn -Id $privId -ErrorAction SilentlyContinue
                    if ($priv) { $privsToAdd.Add($priv) } else { $skippedList.Add($privId) }
                }
                if ($skippedList.Count -gt 0) {
                    Write-Log "$($skippedList.Count) privilege(s) of '$targetName' not found on this vCenter and left out:" -Level WARNING
                    foreach ($sk in $skippedList) { Write-Log "    - $sk" -Level WARNING }
                    $partial++
                }

                # Existing role (#17): add only what it misses, never remove anything
                if ($existing) {
                    $have    = @($existing.PrivilegeList)
                    $missing = @($privsToAdd | Where-Object { $have -notcontains $_.Id })
                    if ($missing.Count -gt 0) {
                        $null = Set-VIRole -Server $viConn -Role $existing -AddPrivilege $missing -ErrorAction Stop
                        Write-Log "'$targetName' updated: $($missing.Count) privilege(s) added, $($skippedList.Count) left out:" -Level SUCCESS
                        foreach ($m in $missing) { Write-Log "    + $($m.Id)" -Level SUCCESS }
                        $updated++
                    } else {
                        Write-Log "'$targetName' already has every privilege of the export that this vCenter knows: nothing added." -Level SUCCESS
                        $current++
                    }
                    continue
                }

                # Create the role and apply all resolved privileges in a single call
                $newRole = New-VIRole -Server $viConn -Name $targetName -ErrorAction Stop
                if ($privsToAdd.Count -gt 0) {
                    $null = Set-VIRole -Server $viConn -Role $newRole -AddPrivilege $privsToAdd.ToArray() -ErrorAction Stop
                }
                Write-Log "'$targetName' created: $($privsToAdd.Count) privilege(s) applied, $($skippedList.Count) left out." -Level SUCCESS
                $created++
            } catch {
                Add-RunFailure -Action 'Import' -Name $file.Name -Reason (Get-FailReason $_)
            }
        }
        Complete-Progress -Id 2
        Complete-Progress
        $importFail = @($script:RunFailures | Where-Object { $_.Action -eq 'Import' }).Count
        Write-RunSummary -Line "Import complete: $created role(s) created, $updated updated, $current already complete ($partial with privileges left out), $skipped skipped (already exists), $importFail failed." `
            -Failed $importFail -Skipped ($skipped + $partial) -Actions 'Import'
    }
}

# --- Disconnect ---------------------------------------------------------------
Disconnect-VIServer -Server $viConn -Confirm:$false -ErrorAction SilentlyContinue
Write-Log "Disconnected from $vCenterServer."
if ($script:RunFailures.Count -gt 0) {
    Write-Log "===== Script finished with $($script:RunFailures.Count) failure(s); see the summary above =====" -Level ERROR
    Write-Host "`n  Log file: $LogFile`n" -ForegroundColor DarkGray
    exit 1
}
Write-Log '===== Script finished =====' -Level SUCCESS
Write-Host "`n  Log file: $LogFile`n" -ForegroundColor DarkGray
