<#
.SYNOPSIS
    Diagnose and control Windows sleep behavior.

.DESCRIPTION
    WhySoSleepy is an interactive menu that helps figure out why a Windows PC
    goes to sleep and what is in control of that: the local power plan, Group
    Policy, Intune / MDM, or a management agent such as Configuration Manager or
    Tanium. It shows what is keeping the PC awake right now, can keep the PC
    awake for a while without changing any settings, changes sleep and display
    timeouts, manages power plans and generates powercfg reports.

    Settings are saved before WhySoSleepy first changes them, so the Undo menu
    can put them back.

    Several options need Administrator rights. When started without them, the
    script asks to relaunch itself elevated (UAC prompt). If that is declined
    it keeps running with limited functionality.

.PARAMETER NoElevate
    Do not ask to relaunch as Administrator. Options that need elevation will
    say so instead of running.

.EXAMPLE
    .\WhySoSleepy.ps1

.EXAMPLE
    .\WhySoSleepy.ps1 -NoElevate

.NOTES
    Requires Windows 10 or 11 with Windows PowerShell 5.1 or PowerShell 7.
    https://github.com/kksimp/WhySoSleepy
#>
[CmdletBinding()]
param(
    [switch]$NoElevate
)

$ScriptVersion = '3.2'
$AppTitle      = "WhySoSleepy v$ScriptVersion"
$Rule          = '=' * 60
$GuidPattern   = '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'

$BalancedSchemeGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'

# Built-in (hidden) scheme that "Ultimate Performance" plans are copied from,
# and the GUID WhySoSleepy gives its copy so it can find it again on any
# Windows display language.
$UltimateSchemeGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$UltimatePlanGuid   = 'e28c86af-35f3-4692-9b2d-b89202566d6f'

# "Allow applications to prevent automatic sleep". When a policy sets it to 0,
# Keep Awake (and any other app) cannot hold the PC awake.
$AllowSystemRequiredGuid = 'a4b195f5-8225-47d8-8012-9d41369786e2'

# Friendly names for power setting GUIDs that commonly show up in policies.
$PowerSettingNames = @{
    '29f6c1db-86da-48c5-9fdb-f2b67b1f44da' = 'Sleep after (seconds)'
    '9d7815a6-7ee4-497e-8888-515a05f02364' = 'Hibernate after (seconds)'
    '7bc4a2f9-d8fc-4469-b07b-33eb785aaca0' = 'Unattended sleep timeout (seconds)'
    '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e' = 'Turn off display after (seconds)'
    'abfc2519-3608-4c2a-94ea-171b0ed546ab' = 'Allow standby states S1-S3'
    '94ac6d29-73ce-41a6-809f-6363ba21b47e' = 'Hybrid sleep'
    'bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d' = 'Allow wake timers'
    'a4b195f5-8225-47d8-8012-9d41369786e2' = 'Allow apps to prevent automatic sleep'
    '5ca83367-6e45-459f-a27b-476b1d01c936' = 'Lid close action'
    '7648efa3-dd9c-4e3e-b566-50f929386280' = 'Power button action'
    '96996bc0-ad50-47ec-923b-6f41874dd9eb' = 'Sleep button action'
    '0e796bdb-100d-47d6-a2d5-f7d2daa51f51' = 'Require password on wake'
}

# What each "powercfg /requests" category means for sleep. PERFBOOST is left
# out because it does not affect sleep.
$RequestEffects = @{
    DISPLAY          = 'is keeping the display on'
    SYSTEM           = 'is keeping the PC awake'
    EXECUTION        = 'is keeping the PC awake'
    AWAYMODE         = 'is keeping the PC in away mode'
    ACTIVELOCKSCREEN = 'is keeping the lock screen on'
}

# Timeouts that WhySoSleepy changes, saved for Undo before the first change.
$TimeoutSettings = @(
    @{ Subgroup = 'SUB_SLEEP'; Setting = 'STANDBYIDLE' }
    @{ Subgroup = 'SUB_SLEEP'; Setting = 'HIBERNATEIDLE' }
    @{ Subgroup = 'SUB_VIDEO'; Setting = 'VIDEOIDLE' }
)

# Where Undo keeps the settings WhySoSleepy changed. Power settings apply to
# the whole PC, so this lives in ProgramData rather than the user profile.
$UndoPath = Join-Path $env:ProgramData 'WhySoSleepy\undo.json'

#region Console helpers

function Test-IsAdmin {
    if ($null -eq $script:IsAdminCache) {
        try {
            $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object Security.Principal.WindowsPrincipal($identity)
            $script:IsAdminCache = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        catch {
            # Constrained Language Mode blocks the types above. An elevated
            # token carries the High Mandatory Level SID instead.
            $script:IsAdminCache = [bool](whoami /groups 2>$null | Select-String -SimpleMatch 'S-1-16-12288')
        }
    }
    return $script:IsAdminCache
}

function Write-Header {
    param([string]$Title)

    Write-Host $Rule -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host $Rule -ForegroundColor Cyan
}

function Show-Screen {
    param([string]$Title)

    Clear-Host
    Write-Header $Title
    Write-Host ''
}

function Wait-ForEnter {
    Write-Host ''
    Read-Host 'Press Enter to continue' | Out-Null
}

function Write-InvalidOption {
    Write-Host 'Invalid option.' -ForegroundColor Red
    Start-Sleep -Seconds 1
}

function Read-MenuChoice {
    return "$(Read-Host 'Select option')".Trim()
}

function Confirm-Action {
    param([string]$Prompt)

    $answer = Read-Host "$Prompt [y/N]"
    return ($answer -match '^\s*y(es)?\s*$')
}

function Read-Number {
    # Prompts for a whole number in a range. Returns $null for invalid input.
    param(
        [string]$Prompt,
        [int]$Minimum,
        [int]$Maximum
    )

    $answer = Read-Host $Prompt
    $value  = 0
    if ([int]::TryParse("$answer".Trim(), [ref]$value) -and $value -ge $Minimum -and $value -le $Maximum) {
        return $value
    }

    Write-Host "Please enter a whole number from $Minimum to $Maximum." -ForegroundColor Red
    return $null
}

function Test-Elevation {
    # Returns $true when elevated; otherwise explains that the action needs it.
    param([string]$Action)

    if (Test-IsAdmin) { return $true }

    Write-Host "$Action requires Administrator rights." -ForegroundColor Red
    Write-Host 'Close WhySoSleepy and start it again as Administrator.' -ForegroundColor Red
    return $false
}

function Get-DesktopPath {
    # Honors OneDrive Known Folder Move and other Desktop redirection.
    $desktop = $null
    try { $desktop = [Environment]::GetFolderPath('Desktop') } catch { }
    if (-not $desktop) { $desktop = Join-Path $env:USERPROFILE 'Desktop' }
    return $desktop
}

function Open-Report {
    # Opens a report in Chrome when installed, otherwise in the default app.
    param([string]$Path)

    $chrome = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

    if ($chrome) {
        # Quote the path so profiles with spaces in the name work.
        Start-Process -FilePath $chrome -ArgumentList "`"$Path`""
    }
    else {
        Invoke-Item -LiteralPath $Path
    }
}

function Format-Duration {
    param([TimeSpan]$Duration)

    '{0:00}:{1:mm\:ss}' -f ($Duration.Days * 24 + $Duration.Hours), $Duration
}

#endregion

#region Power plan helpers

function Get-PowerPlan {
    # Parses "powercfg /list": "Power Scheme GUID: <guid>  (<name>) *".
    foreach ($line in @(powercfg /list 2>$null)) {
        if ($line -match "($GuidPattern)\s+\((.+)\)\s*(\*)?\s*$") {
            [pscustomobject]@{
                Guid   = $Matches[1]
                Name   = $Matches[2]
                Active = [bool]$Matches[3]
            }
        }
    }
}

function Get-PlanName {
    param(
        [string]$Guid,
        [object[]]$Plans
    )

    $plan = $Plans | Where-Object { $_.Guid -eq $Guid } | Select-Object -First 1
    if ($plan) { return $plan.Name }
    return "$Guid (no longer exists)"
}

function Get-ActiveSchemeGuid {
    $output = "$(powercfg /getactivescheme 2>$null)"
    if ($output -match $GuidPattern) { return $Matches[0] }
    return $null
}

function Get-PowerSettingValue {
    # Returns the plugged-in (AC) and battery (DC) values of a setting. They are
    # the last two hex numbers in "powercfg /query" output, which avoids relying
    # on the labels (those are translated on non-English Windows).
    param(
        [string]$Scheme,
        [string]$Subgroup,
        [string]$Setting
    )

    $output = @(powercfg /query $Scheme $Subgroup $Setting 2>$null)
    if ($LASTEXITCODE -ne 0) { return $null }

    $hex = @($output | Select-String -Pattern '0x[0-9a-fA-F]+' -AllMatches |
        ForEach-Object { $_.Matches } | ForEach-Object { $_.Value })
    if ($hex.Count -lt 2) { return $null }

    return @([long]$hex[-2], [long]$hex[-1])
}

function Test-HibernateEnabled {
    # $true / $false, or $null when it cannot be determined.
    $key = Get-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue
    if (-not $key) { return $null }

    $value = $key.GetValue('HibernateEnabled')
    if ($null -eq $value) { return $null }
    return ($value -eq 1)
}

#endregion

#region Undo state

function Get-UndoState {
    $undo = @{
        Saved            = $null
        ActiveScheme     = $null
        HibernateEnabled = $null
        CreatedPlan      = $null
        Timeouts         = @()
    }

    if (Test-Path -LiteralPath $UndoPath) {
        try {
            $data = Get-Content -LiteralPath $UndoPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            foreach ($name in @($undo.Keys)) {
                if ($null -ne $data.$name) { $undo[$name] = $data.$name }
            }
        }
        catch {
            Write-Host "Ignoring unreadable undo file ${UndoPath}: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    $undo.Timeouts = @($undo.Timeouts | Where-Object { $_ })
    return $undo
}

function Save-UndoState {
    # Writes the undo file, or deletes it once there is nothing left to undo.
    param([hashtable]$Undo)

    $empty = -not $Undo.ActiveScheme -and $null -eq $Undo.HibernateEnabled -and
             -not $Undo.CreatedPlan -and $Undo.Timeouts.Count -eq 0

    try {
        if ($empty) {
            if (Test-Path -LiteralPath $UndoPath) { Remove-Item -LiteralPath $UndoPath -ErrorAction Stop }
            return $true
        }

        $folder = Split-Path -Path $UndoPath -Parent
        if (-not (Test-Path -LiteralPath $folder)) {
            New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
        }
        $Undo | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $UndoPath -Encoding UTF8 -ErrorAction Stop
        return $true
    }
    catch {
        Write-Host "Could not update the undo file: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

function Update-UndoState {
    # Records what a change is about to overwrite. Each item is saved only the
    # first time, so Undo returns to the state before WhySoSleepy's first change.
    param(
        [switch]$ActiveScheme,
        [switch]$Timeouts,
        [switch]$Hibernation,
        [string]$CreatedPlan
    )

    $undo    = Get-UndoState
    $changed = $false

    if ($ActiveScheme -and -not $undo.ActiveScheme) {
        $undo.ActiveScheme = Get-ActiveSchemeGuid
        $changed = [bool]$undo.ActiveScheme
    }

    if ($Hibernation -and $null -eq $undo.HibernateEnabled) {
        $undo.HibernateEnabled = Test-HibernateEnabled
        if ($null -ne $undo.HibernateEnabled) { $changed = $true }
    }

    if ($CreatedPlan -and -not $undo.CreatedPlan) {
        $undo.CreatedPlan = $CreatedPlan
        $changed = $true
    }

    if ($Timeouts) {
        $scheme = Get-ActiveSchemeGuid
        if ($scheme -and -not ($undo.Timeouts | Where-Object { $_.Scheme -eq $scheme })) {
            foreach ($timeout in $TimeoutSettings) {
                $values = Get-PowerSettingValue -Scheme $scheme -Subgroup $timeout.Subgroup -Setting $timeout.Setting
                if (@($values).Count -eq 2) {
                    $undo.Timeouts += [pscustomobject]@{
                        Scheme   = $scheme
                        Subgroup = $timeout.Subgroup
                        Setting  = $timeout.Setting
                        AC       = $values[0]
                        DC       = $values[1]
                    }
                    $changed = $true
                }
            }
        }
    }

    if ($changed) {
        if (-not $undo.Saved) { $undo.Saved = Get-Date -Format 'yyyy-MM-dd HH:mm' }
        $null = Save-UndoState -Undo $undo
    }
}

#endregion

#region System state

function Get-AvailableSleepState {
    # "powercfg /a" lists the available states first, followed by a second
    # header and the states that are NOT available. Headers are the only lines
    # that are not indented, which keeps this working on non-English Windows.
    $headers = 0
    foreach ($line in @(powercfg /a 2>$null)) {
        if ($line -match '^\S') {
            $headers++
            if ($headers -gt 1) { break }
            continue
        }
        if ($headers -eq 1 -and $line.Trim()) { $line.Trim() }
    }
}

function Get-MdmEnrollment {
    # The Enrollments key exists even on unmanaged devices. Only subkeys with a
    # ProviderID are real MDM enrollments ("MS DM Server" is Intune).
    Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $provider = $_.GetValue('ProviderID')
            if ($provider) {
                [pscustomobject]@{
                    Provider = $provider
                    UPN      = $_.GetValue('UPN')
                }
            }
        }
}

function Get-PolicyPowerSetting {
    # Power settings enforced by Group Policy (or Intune ADMX-backed policies):
    # one subkey per setting GUID, holding plugged-in (AC) and battery (DC) values.
    Get-ChildItem -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $guid = $_.PSChildName -replace '[{}]', ''
            $ac   = $_.GetValue('ACSettingIndex')
            $dc   = $_.GetValue('DCSettingIndex')

            if ($null -ne $ac -or $null -ne $dc) {
                $name = $PowerSettingNames[$guid]
                if (-not $name) { $name = $guid }

                [pscustomobject]@{
                    Setting   = $name
                    PluggedIn = $ac
                    OnBattery = $dc
                    Guid      = $guid
                }
            }
        }
}

function Get-PolicyActivePlan {
    # GUID of the power plan forced by Group Policy, if any.
    $key = Get-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings' -ErrorAction SilentlyContinue
    if ($key) { $key.GetValue('ActivePowerScheme') }
}

function Get-MdmPowerPolicy {
    # Policies delivered through the Power / ADMX_Power Policy CSP (Intune / MDM).
    foreach ($area in 'Power', 'ADMX_Power') {
        $key = Get-Item -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\$area" -ErrorAction SilentlyContinue
        if (-not $key) { continue }

        foreach ($name in $key.GetValueNames()) {
            # Skip the bookkeeping values PolicyManager stores next to each policy.
            if (-not $name -or $name -match '_(ProviderSet|WinningProvider|LastWrite|ADMXInstanceData)$') { continue }

            [pscustomobject]@{
                Policy = "$area/$name"
                Value  = $key.GetValue($name)
            }
        }
    }
}

function Get-ManagementAgent {
    # Agents that can push their own power plans or settings.
    $known = @(
        @{ Name = 'Configuration Manager client'; Pattern = 'CcmExec' }
        @{ Name = 'Tanium Client';                Pattern = '*Tanium*' }
    )
    $services = @(Get-Service -ErrorAction SilentlyContinue)

    foreach ($agent in $known) {
        $service = $services |
            Where-Object { $_.Name -like $agent.Pattern -or $_.DisplayName -like $agent.Pattern } |
            Select-Object -First 1

        if ($service) {
            [pscustomobject]@{
                Agent   = $agent.Name
                Service = $service.Name
                Status  = $service.Status
            }
        }
    }
}

function Get-RequestSourceName {
    # Turns a power request source into a readable name, for example
    # "\Device\HarddiskVolume3\...\ms-teams.exe" -> "Microsoft Teams (ms-teams.exe)".
    param(
        [string]$Type,
        [string]$Source
    )

    if ($Type -eq 'SERVICE' -and $Source -match '\(([^()]+)\)$') {
        $serviceName = $Matches[1]
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($service) { return "$($service.DisplayName) service" }
        return "$serviceName service"
    }

    if ($Type -eq 'PROCESS' -or $Source -match '^\\Device\\') {
        $file    = ($Source -split '\\')[-1]
        $process = Get-Process -Name ($file -replace '\.exe$', '') -ErrorAction SilentlyContinue |
            Where-Object { $_.Description } | Select-Object -First 1
        if ($process) { return "$($process.Description) ($file)" }
        return $file
    }

    # Drivers: "Realtek High Definition Audio (HDAUDIO\FUNC_01&...)" -> drop the device ID.
    return ($Source -replace '\s+\([^()]*\\[^()]*\)$', '')
}

function ConvertFrom-PowerRequest {
    # Parses "powercfg /requests": a "CATEGORY:" header line, then one
    # "[TYPE] source" line per request, optionally followed by a reason line.
    param([string[]]$Lines)

    $requests = New-Object System.Collections.Generic.List[object]
    $category = $null
    $current  = $null

    foreach ($line in $Lines) {
        $text = "$line".Trim()

        if ($text -cmatch '^([A-Z]+):$') {
            $category = $Matches[1]
            $current  = $null
        }
        elseif ($text -match '^\[([^\]]+)\]\s*(.+)$') {
            $type    = $Matches[1]
            $source  = $Matches[2]
            $current = $null

            if ($category -and $RequestEffects.ContainsKey($category)) {
                $current = [pscustomobject]@{
                    Category = $category
                    Type     = $type
                    Source   = $source
                    Name     = Get-RequestSourceName -Type $type -Source $source
                    Effect   = $RequestEffects[$category]
                    Reason   = $null
                }
                $requests.Add($current)
            }
        }
        elseif ($text -and $current -and -not $current.Reason) {
            $current.Reason = $text
        }
    }

    return $requests
}

function Get-SystemState {
    # Every probe is best effort: anything that fails shows up as Unknown or empty.
    $cs = $null
    $os = $null
    try { $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop } catch { }
    try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { }

    $dsreg = @()
    try { $dsreg = @(dsregcmd /status 2>$null) } catch { }

    $availableStates = @(Get-AvailableSleepState)

    # "powercfg /requests" needs admin rights; without them the output is the
    # error message, which still goes into the diagnostics.
    $requestOutput = @(powercfg /requests 2>&1 | ForEach-Object { "$_" })
    $requests      = @()
    if (Test-IsAdmin) { $requests = @(ConvertFrom-PowerRequest -Lines $requestOutput) }

    [pscustomobject]@{
        ComputerName       = $env:COMPUTERNAME
        OperatingSystem    = if ($os) { "$($os.Caption) (build $($os.BuildNumber))" } else { 'Unknown' }
        IsAdmin            = Test-IsAdmin
        Domain             = if ($cs) { $cs.Domain } else { 'Unknown' }
        DomainJoined       = [bool]($cs -and $cs.PartOfDomain)
        EntraJoined        = [bool]($dsreg -match '^\s*AzureAdJoined\s*:\s*YES')
        JoinStatus         = @($dsreg -match '^\s*(AzureAdJoined|EnterpriseJoined|DomainJoined|WorkplaceJoined)\s*:' |
                               ForEach-Object { $_.Trim() })
        MdmEnrollments     = @(Get-MdmEnrollment)
        AvailableStates    = $availableStates
        ModernStandby      = [bool]($availableStates -match '\bS0\b')
        PolicySettings     = @(Get-PolicyPowerSetting)
        PolicyActivePlan   = Get-PolicyActivePlan
        MdmPowerPolicies   = @(Get-MdmPowerPolicy)
        ManagementAgents   = @(Get-ManagementAgent)
        PowerRequestOutput = $requestOutput
        PowerRequests      = $requests
    }
}

#endregion

#region Diagnostics and analysis

function New-Section {
    # Runs a script block and captures its output (errors included) as text.
    param(
        [string]$SectionTitle,
        [scriptblock]$SectionBody
    )

    try {
        $lines = @(& $SectionBody 2>&1 | ForEach-Object { "$_".TrimEnd() })
    }
    catch {
        $lines = @("ERROR: $($_.Exception.Message)")
    }

    # Drop leading and trailing blank lines to keep the output compact.
    $first = 0
    $last  = $lines.Count - 1
    while ($first -le $last -and -not $lines[$first]) { $first++ }
    while ($last -ge $first -and -not $lines[$last]) { $last-- }
    if ($first -le $last) { $lines = @($lines[$first..$last]) } else { $lines = @('(no output)') }

    [pscustomobject]@{
        Title = $SectionTitle
        Lines = $lines
    }
}

function ConvertTo-TableText {
    # Renders objects as a table of plain strings (avoids delayed table output
    # appearing out of order with Write-Host, and gives the report file text).
    $input | Format-Table -AutoSize | Out-String -Stream -Width 200 | Where-Object { $_.Trim() }
}

function Get-DiagnosticSection {
    # The section script blocks run in this function's scope chain, so they can
    # read $State directly.
    param($State)

    New-Section 'SYSTEM' {
        "Computer           : $($State.ComputerName)"
        "Operating system   : $($State.OperatingSystem)"
        "Domain             : $($State.Domain)"
        "Domain joined      : $($State.DomainJoined)"
        "Running as admin   : $($State.IsAdmin)"
        "WhySoSleepy        : v$ScriptVersion"
    }

    New-Section 'DEVICE JOIN STATUS (dsregcmd)' {
        if ($State.JoinStatus.Count) { $State.JoinStatus } else { 'dsregcmd did not report a join status.' }
    }

    New-Section 'MDM ENROLLMENT' {
        if ($State.MdmEnrollments.Count) { $State.MdmEnrollments | ConvertTo-TableText } else { 'No MDM enrollment found.' }
    }

    New-Section 'MANAGEMENT AGENTS' {
        if ($State.ManagementAgents.Count) {
            $State.ManagementAgents | ConvertTo-TableText
        }
        else {
            'No Configuration Manager or Tanium client found.'
        }
    }

    New-Section 'POWER POLICY (GROUP POLICY / ADMX)' {
        if ($State.PolicyActivePlan) { "Enforced power plan: $($State.PolicyActivePlan)"; '' }
        if ($State.PolicySettings.Count) {
            $State.PolicySettings | Select-Object Setting, PluggedIn, OnBattery | ConvertTo-TableText
        }
        elseif (-not $State.PolicyActivePlan) {
            'No power settings are enforced by Group Policy.'
        }
    }

    New-Section 'POWER POLICY (INTUNE / MDM CSP)' {
        if ($State.MdmPowerPolicies.Count) {
            $State.MdmPowerPolicies | Format-List | Out-String -Stream -Width 200
        }
        else {
            'No MDM power policies found.'
        }
    }

    New-Section 'ACTIVE POWER PLAN'   { powercfg /getactivescheme }
    New-Section 'SLEEP STATES'        { powercfg /a }
    New-Section 'SLEEP SETTINGS'      { powercfg /query SCHEME_CURRENT SUB_SLEEP }
    New-Section 'DISPLAY TIMEOUT'     { powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE }
    New-Section 'POWER REQUESTS'      { $State.PowerRequestOutput }
    New-Section 'WAKE TIMERS'         { powercfg /waketimers }
    New-Section 'LAST WAKE'           { powercfg /lastwake }
    New-Section 'WAKE-ARMED DEVICES'  { powercfg /devicequery wake_armed }
}

function New-Finding {
    param(
        [ValidateSet('Plain', 'Good', 'Info', 'Warn', 'Detail')]
        [string]$Level,
        [string[]]$Text
    )

    switch ($Level) {
        'Good'   { $prefix = '[+] ';     $color = 'Green' }
        'Info'   { $prefix = '[i] ';     $color = $null }
        'Warn'   { $prefix = '[!] ';     $color = 'Yellow' }
        'Detail' { $prefix = '      - '; $color = 'Gray' }
        default  { $prefix = '';         $color = $null }
    }

    # Continuation lines are indented to line up with the first line's text.
    $indent = ' ' * $prefix.Length
    for ($i = 0; $i -lt $Text.Count; $i++) {
        $lead = if ($i -eq 0) { $prefix } else { $indent }
        [pscustomobject]@{
            Text  = $lead + $Text[$i]
            Color = $color
        }
    }
}

function Get-Analysis {
    param($State)

    $yesNo = @{ $true = 'Yes'; $false = 'No' }

    $mdmSummary = 'No'
    if ($State.MdmEnrollments.Count) {
        $providers  = @($State.MdmEnrollments | ForEach-Object { $_.Provider } | Select-Object -Unique)
        $mdmSummary = "Yes ($($providers -join ', '))"
    }

    $agentSummary = 'None'
    if ($State.ManagementAgents.Count) {
        $agentSummary = (@($State.ManagementAgents | ForEach-Object { $_.Agent }) -join ', ')
    }

    $requestSummary = 'Unknown (needs Administrator)'
    if ($State.IsAdmin) {
        $requestSummary = if ($State.PowerRequests.Count) { "$($State.PowerRequests.Count) active" } else { 'None' }
    }

    New-Finding Plain "Domain joined      : $($yesNo[$State.DomainJoined])"
    New-Finding Plain "Entra ID joined    : $($yesNo[$State.EntraJoined])"
    New-Finding Plain "MDM enrolled       : $mdmSummary"
    New-Finding Plain "Modern Standby     : $($yesNo[$State.ModernStandby])"
    New-Finding Plain "Policy settings    : $($State.PolicySettings.Count) Group Policy / ADMX, $($State.MdmPowerPolicies.Count) MDM CSP"
    New-Finding Plain "Management agents  : $agentSummary"
    New-Finding Plain "Power requests     : $requestSummary"
    New-Finding Plain ''

    $controlled = $false

    if ($State.PolicySettings.Count -or $State.PolicyActivePlan) {
        $controlled = $true
        New-Finding Warn 'Power settings are enforced by policy (Group Policy, or Intune via ADMX).',
                         'Local changes to these settings will be overridden:'
        if ($State.PolicyActivePlan) {
            New-Finding Detail "Active power plan forced to $($State.PolicyActivePlan)"
        }
        foreach ($setting in $State.PolicySettings) {
            $ac = if ($null -eq $setting.PluggedIn) { 'not set' } else { $setting.PluggedIn }
            $dc = if ($null -eq $setting.OnBattery) { 'not set' } else { $setting.OnBattery }
            New-Finding Detail "$($setting.Setting): plugged in = $ac, on battery = $dc"
        }
    }

    if ($State.MdmPowerPolicies.Count) {
        $controlled = $true
        New-Finding Warn 'Intune / MDM power policies are applied and override local settings:'
        foreach ($policy in $State.MdmPowerPolicies) {
            New-Finding Detail $policy.Policy
        }
    }
    elseif ($State.MdmEnrollments.Count) {
        New-Finding Info "MDM enrolled ($(@($State.MdmEnrollments)[0].Provider)), but no MDM power policies were found."
    }

    if ($State.DomainJoined -and -not ($State.PolicySettings.Count -or $State.PolicyActivePlan)) {
        New-Finding Info "Domain joined ($($State.Domain)), but Group Policy does not enforce any power settings.",
                         "For full detail, run 'gpresult /h gpresult.html' as Administrator."
    }

    foreach ($agent in $State.ManagementAgents) {
        $controlled = $true
        New-Finding Warn "$($agent.Agent) is installed ($($agent.Status)) and can apply its own power settings."
    }

    if ($controlled) {
        New-Finding Info 'Settings not listed above come from the local power plan.',
                         'Keep Awake (option 2) still works, unless policy blocks apps from preventing sleep.'
    }
    else {
        New-Finding Good 'No power policy or management agent found: the local power plan controls sleep,',
                         'so changes made with WhySoSleepy should stick.'
    }

    if ($State.PowerRequests.Count) {
        New-Finding Plain ''
        New-Finding Info 'Keeping the PC awake right now (see POWER REQUESTS):'
        foreach ($request in $State.PowerRequests) {
            $text = "$($request.Name) $($request.Effect)"
            if ($request.Reason) { $text += " ($($request.Reason))" }
            New-Finding Detail $text
        }
    }
    elseif ($State.IsAdmin) {
        New-Finding Plain ''
        New-Finding Info 'Nothing is keeping the PC awake right now.'
    }

    if ($State.ModernStandby) {
        New-Finding Plain ''
        New-Finding Info 'Modern Standby (S0 Low Power Idle) is active. The PC uses connected standby',
                         'instead of classic S3 sleep, and extra plans such as Ultimate Performance',
                         'are usually unavailable.'
    }

    if (-not $State.IsAdmin) {
        New-Finding Plain ''
        New-Finding Warn 'Not running as Administrator: power requests and wake timers could not be read.'
    }
}

function Show-Analysis {
    param($State)

    Write-Header 'FINAL ANALYSIS'
    Write-Host ''

    foreach ($finding in Get-Analysis -State $State) {
        if ($finding.Color) {
            Write-Host $finding.Text -ForegroundColor $finding.Color
        }
        else {
            Write-Host $finding.Text
        }
    }
}

function Invoke-SleepDiagnostic {
    Show-Screen 'RUN DIAGNOSTICS'
    Write-Host 'Collecting diagnostics, please wait...'

    $state    = Get-SystemState
    $sections = @(Get-DiagnosticSection -State $state)

    Clear-Host
    foreach ($section in $sections) {
        Write-Header $section.Title
        foreach ($line in $section.Lines) { Write-Host $line }
        Write-Host ''
    }

    Show-Analysis -State $state
}

#endregion

#region Keep awake

function Initialize-KeepAwake {
    # Loads SetThreadExecutionState, the API media players use to keep the PC awake.
    if ('WhySoSleepy.NativeMethods' -as [type]) { return $true }

    try {
        Add-Type -Namespace WhySoSleepy -Name NativeMethods -ErrorAction Stop -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
private static extern uint SetThreadExecutionState(uint esFlags);

// ES_CONTINUOUS | ES_SYSTEM_REQUIRED, plus ES_DISPLAY_REQUIRED when asked.
public static bool StayAwake(bool keepDisplayOn)
{
    uint flags = 0x80000001;
    if (keepDisplayOn) { flags |= 0x00000002; }
    return SetThreadExecutionState(flags) != 0;
}

// ES_CONTINUOUS on its own clears the request.
public static void AllowSleep()
{
    SetThreadExecutionState(0x80000000);
}
'@
        return $true
    }
    catch {
        Write-Host "Could not load the Windows API that Keep Awake needs: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Start-KeepAwake {
    Show-Screen 'KEEP AWAKE'

    Write-Host 'Keeps the PC awake for a while without changing any settings. It needs no'
    Write-Host 'admin rights and is not undone by policy timeouts. It stops when the time'
    Write-Host 'runs out, when you press Q, or when you close this window.'
    Write-Host ''

    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        Write-Host 'Keep Awake is not available: PowerShell runs in Constrained Language Mode on' -ForegroundColor Red
        Write-Host 'this PC, which blocks the Windows API it needs.' -ForegroundColor Red
        return
    }
    if (-not (Initialize-KeepAwake)) { return }

    $blocked = @(Get-PolicyPowerSetting | Where-Object {
        $_.Guid -eq $AllowSystemRequiredGuid -and ($_.PluggedIn -eq 0 -or $_.OnBattery -eq 0)
    })
    if ($blocked.Count) {
        Write-Host 'Policy on this PC stops apps from preventing automatic sleep, so Keep Awake' -ForegroundColor Yellow
        Write-Host 'may not work (see Run Diagnostics for details).' -ForegroundColor Yellow
        Write-Host ''
    }

    $minutes = Read-Number -Prompt 'Minutes to stay awake (1-1440, 0 = until you press Q)' -Minimum 0 -Maximum 1440
    if ($null -eq $minutes) { return }

    if (@(Get-AvailableSleepState) -match '\bS0\b') {
        Write-Host 'Tip: on Modern Standby PCs, keeping the display on is the most reliable option.'
    }
    $keepDisplayOn = Confirm-Action 'Keep the display on as well?'

    if (-not [WhySoSleepy.NativeMethods]::StayAwake($keepDisplayOn)) {
        Write-Host 'Windows rejected the keep-awake request.' -ForegroundColor Red
        return
    }

    $start = Get-Date
    $end   = $start.AddMinutes($minutes)
    $what  = if ($keepDisplayOn) { 'the PC and display' } else { 'the PC' }

    Write-Host ''
    if ($minutes -gt 0) {
        Write-Host "Keeping $what awake until $($end.ToString('t'))." -ForegroundColor Green
    }
    else {
        Write-Host "Keeping $what awake until you press Q." -ForegroundColor Green
    }
    Write-Host 'Press Q to stop.'
    Write-Host ''

    # Without a real console (for example in the ISE) keys cannot be read, so
    # only the timer or closing the window stops it.
    $canReadKeys = $true
    try {
        while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) }
    }
    catch {
        $canReadKeys = $false
    }

    try {
        while ($true) {
            $now = Get-Date
            if ($minutes -gt 0) {
                $left = $end - $now
                if ($left.TotalSeconds -le 0) { break }
                $status = 'Time left: ' + (Format-Duration $left)
            }
            else {
                $status = 'Awake for: ' + (Format-Duration ($now - $start))
            }
            Write-Host "`r$status " -NoNewline

            if ($canReadKeys -and [Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq 'Q' -or $key.Key -eq 'Escape') { break }
            }
            Start-Sleep -Milliseconds 250
        }
    }
    finally {
        # Also runs on Ctrl+C. Windows drops the request when the process
        # exits anyway, so closing the window is safe too.
        [WhySoSleepy.NativeMethods]::AllowSleep()
        Write-Host ''
    }

    Write-Host ''
    Write-Host 'Keep Awake stopped. Normal sleep settings apply again.' -ForegroundColor Green
}

#endregion

#region Sleep settings

function Write-PolicyWarning {
    # powercfg changes are silently reverted when a policy enforces the setting.
    if (@(Get-PolicyPowerSetting).Count -or (Get-PolicyActivePlan) -or @(Get-MdmPowerPolicy).Count) {
        Write-Host ''
        Write-Host 'Power policies are enforced on this device and may override this change.' -ForegroundColor Yellow
        Write-Host 'Run Diagnostics (option 1) to see which settings are managed.' -ForegroundColor Yellow
    }
}

function Set-PowerTimeout {
    # Sets timeouts (minutes, 0 = never) on the active plan for both plugged-in
    # and battery power. Returns $true when every powercfg call succeeded.
    param(
        [int]$Minutes,
        [switch]$IncludeHibernate
    )

    Update-UndoState -Timeouts

    $settings = @('standby-timeout-ac', 'standby-timeout-dc', 'monitor-timeout-ac', 'monitor-timeout-dc')
    if ($IncludeHibernate) { $settings += 'hibernate-timeout-ac', 'hibernate-timeout-dc' }

    $ok = $true
    foreach ($setting in $settings) {
        powercfg /change $setting $Minutes | Out-Host
        if ($LASTEXITCODE -ne 0) { $ok = $false }
    }

    if (-not $ok) {
        Write-Host 'One or more settings could not be changed (see messages above).' -ForegroundColor Red
    }
    return $ok
}

function Set-SleepTimeout {
    Show-Screen 'SET SLEEP TIMEOUT'

    Write-Host 'Sets both the sleep and display-off timeouts, plugged in and on battery.'
    Write-Host ''
    Write-Host '0    = Never'
    Write-Host '5    = 5 Minutes'
    Write-Host '15   = 15 Minutes'
    Write-Host '30   = 30 Minutes'
    Write-Host '60   = 1 Hour'
    Write-Host '120  = 2 Hours'
    Write-Host '240  = 4 Hours'
    Write-Host '480  = 8 Hours'
    Write-Host '720  = 12 Hours'
    Write-Host '1440 = 24 Hours'
    Write-Host ''

    $minutes = Read-Number -Prompt 'Enter timeout in minutes (0-1440)' -Minimum 0 -Maximum 1440
    if ($null -eq $minutes) { return }

    if (Set-PowerTimeout -Minutes $minutes) {
        $label = if ($minutes -eq 0) { 'Never' } else { "$minutes minute(s)" }
        Write-Host ''
        Write-Host "Sleep and display timeouts set to $label." -ForegroundColor Green
    }

    Write-PolicyWarning
}

function Disable-Sleep {
    Show-Screen 'DISABLE SLEEP'

    if (Set-PowerTimeout -Minutes 0 -IncludeHibernate) {
        Write-Host 'Sleep, hibernate and display timeouts set to Never.' -ForegroundColor Green
    }

    Write-PolicyWarning
}

function Disable-SleepAndHibernation {
    Show-Screen 'DISABLE SLEEP + HIBERNATION'

    Write-Host 'This will:'
    Write-Host '  - Turn hibernation off (this also disables Fast Startup)'
    Write-Host '  - Set the sleep and display timeouts to Never'
    Write-Host ''
    Write-Host 'Undo Changes (option 8) can turn hibernation back on later.'
    Write-Host ''

    if (-not (Test-Elevation 'Turning hibernation off')) { return }
    if (-not (Confirm-Action 'Continue?')) {
        Write-Host 'Cancelled.'
        return
    }
    Write-Host ''

    Update-UndoState -Hibernation
    powercfg /hibernate off | Out-Host
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'Hibernation turned off.' -ForegroundColor Green
    }
    else {
        Write-Host 'Could not turn hibernation off.' -ForegroundColor Red
    }

    if (Set-PowerTimeout -Minutes 0) {
        Write-Host 'Sleep and display timeouts set to Never.' -ForegroundColor Green
    }

    Write-PolicyWarning
}

#endregion

#region Power plans

function Write-PlanList {
    param([object[]]$Plans)

    if (-not $Plans.Count) {
        Write-Host 'No power plans found.' -ForegroundColor Red
        return
    }

    for ($i = 0; $i -lt $Plans.Count; $i++) {
        $line = '{0,3}. {1}' -f ($i + 1), $Plans[$i].Name
        if ($Plans[$i].Active) {
            Write-Host "$line  (active)" -ForegroundColor Green
        }
        else {
            Write-Host $line
        }
    }
}

function Find-UltimatePlan {
    # Existing Ultimate Performance plans: WhySoSleepy's copy, the built-in one,
    # or copies made by hand or by older versions.
    Get-PowerPlan | Where-Object {
        $_.Guid -eq $UltimatePlanGuid -or $_.Guid -eq $UltimateSchemeGuid -or $_.Name -match 'Ultimate'
    }
}

function Set-ActivePlan {
    # Activates a plan, saving the previous one for Undo. Returns $true on success.
    param([string]$Guid)

    Update-UndoState -ActiveScheme
    powercfg /setactive $Guid | Out-Host
    return ($LASTEXITCODE -eq 0)
}

function Switch-PowerPlan {
    param([object[]]$Plans)

    if (-not $Plans.Count) { return }

    $number = Read-Number -Prompt "Plan number to activate (1-$($Plans.Count))" -Minimum 1 -Maximum $Plans.Count
    if ($null -eq $number) { return }

    $plan = $Plans[$number - 1]
    if ($plan.Active) {
        Write-Host "$($plan.Name) is already active."
        return
    }

    if (Set-ActivePlan -Guid $plan.Guid) {
        Write-Host "$($plan.Name) is now active." -ForegroundColor Green
        Write-PolicyWarning
    }
    else {
        Write-Host "Could not activate $($plan.Name)." -ForegroundColor Red
    }
}

function Enable-UltimatePerformance {
    $plan = Find-UltimatePlan | Select-Object -First 1

    if ($plan) {
        $guid = $plan.Guid
        if ($plan.Active) {
            Write-Host 'Ultimate Performance is already the active plan.'
            return
        }
    }
    else {
        $output = powercfg /duplicatescheme $UltimateSchemeGuid $UltimatePlanGuid 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'The Ultimate Performance plan could not be created.' -ForegroundColor Red
            Write-Host 'It is usually unavailable on Modern Standby (S0) devices.' -ForegroundColor Red
            return
        }

        $guid = $UltimatePlanGuid
        if ("$output" -match $GuidPattern) { $guid = $Matches[0] }
        Update-UndoState -CreatedPlan $guid
        Write-Host 'Created the Ultimate Performance plan.'
    }

    if (Set-ActivePlan -Guid $guid) {
        Write-Host 'Ultimate Performance plan activated.' -ForegroundColor Green
        Write-Host 'Note: it keeps the CPU at full speed, which uses more power and battery.'
        Write-PolicyWarning
    }
    else {
        Write-Host "Could not activate the Ultimate Performance plan ($guid)." -ForegroundColor Red
    }
}

function Show-PowerPlanMenu {
    while ($true) {
        Show-Screen 'POWER PLANS'
        $plans = @(Get-PowerPlan)
        Write-PlanList -Plans $plans
        Write-Host ''
        Write-Host '1. Switch plan'
        Write-Host '2. Enable Ultimate Performance'
        Write-Host '0. Back'
        Write-Host ''

        switch (Read-MenuChoice) {
            '1' { Switch-PowerPlan -Plans $plans; Wait-ForEnter }
            '2' { Write-Host ''; Enable-UltimatePerformance; Wait-ForEnter }
            '0' { return }
            default { Write-InvalidOption }
        }
    }
}

#endregion

#region Undo

function Write-UndoSummary {
    param(
        [hashtable]$Undo,
        [object[]]$Plans
    )

    if (-not $Undo.Saved) {
        Write-Host 'No saved settings yet. WhySoSleepy saves your settings automatically'
        Write-Host 'before it first changes them.'
        return
    }

    Write-Host "Settings saved on $($Undo.Saved), before WhySoSleepy changed them:"
    if ($Undo.ActiveScheme) {
        Write-Host "  Power plan  : $(Get-PlanName -Guid $Undo.ActiveScheme -Plans $Plans)"
    }
    if ($null -ne $Undo.HibernateEnabled) {
        Write-Host "  Hibernation : $(if ($Undo.HibernateEnabled) { 'On' } else { 'Off' })"
    }
    if ($Undo.Timeouts.Count) {
        $schemes = @($Undo.Timeouts | ForEach-Object { $_.Scheme } | Select-Object -Unique |
            ForEach-Object { Get-PlanName -Guid $_ -Plans $Plans })
        Write-Host "  Timeouts    : $($schemes -join ', ')"
    }
    if ($Undo.CreatedPlan) {
        Write-Host "  Added plan  : $(Get-PlanName -Guid $Undo.CreatedPlan -Plans $Plans) (will be removed)"
    }
}

function Restore-SavedSetting {
    $undo = Get-UndoState
    if (-not $undo.Saved) {
        Write-Host 'There are no saved settings to restore.'
        return
    }

    $planGuids = @(Get-PowerPlan | ForEach-Object { $_.Guid })
    $ok = $true

    if ($undo.HibernateEnabled -and -not (Test-HibernateEnabled)) {
        if (Test-IsAdmin) {
            powercfg /hibernate on | Out-Host
            if ($LASTEXITCODE -eq 0) {
                Write-Host 'Hibernation turned back on.' -ForegroundColor Green
                $undo.HibernateEnabled = $null
            }
            else {
                Write-Host 'Could not turn hibernation back on.' -ForegroundColor Red
                $ok = $false
            }
        }
        else {
            Write-Host 'Turning hibernation back on requires Administrator rights; skipped.' -ForegroundColor Yellow
            $ok = $false
        }
    }
    else {
        $undo.HibernateEnabled = $null
    }

    $remaining = @()
    $restored  = 0
    foreach ($timeout in $undo.Timeouts) {
        # Plans deleted since then have nothing left to restore.
        if ($planGuids -notcontains $timeout.Scheme) { continue }

        powercfg /setacvalueindex $timeout.Scheme $timeout.Subgroup $timeout.Setting $timeout.AC | Out-Host
        $acOk = ($LASTEXITCODE -eq 0)
        powercfg /setdcvalueindex $timeout.Scheme $timeout.Subgroup $timeout.Setting $timeout.DC | Out-Host
        if ($acOk -and $LASTEXITCODE -eq 0) {
            $restored++
        }
        else {
            $remaining += $timeout
            $ok = $false
        }
    }
    if ($restored -and -not $remaining.Count) {
        Write-Host 'Sleep, hibernate and display timeouts restored.' -ForegroundColor Green
    }
    $undo.Timeouts = $remaining

    # Re-activating the plan also applies the restored values.
    $target = Get-ActiveSchemeGuid
    if ($undo.ActiveScheme -and $planGuids -contains $undo.ActiveScheme) { $target = $undo.ActiveScheme }
    if ($target) {
        powercfg /setactive $target | Out-Host
        if ($LASTEXITCODE -eq 0) {
            if ($undo.ActiveScheme) {
                Write-Host "Switched back to $(Get-PlanName -Guid $target -Plans @(Get-PowerPlan))." -ForegroundColor Green
            }
            $undo.ActiveScheme = $null
        }
        else {
            Write-Host 'Could not re-activate the power plan.' -ForegroundColor Red
            $ok = $false
        }
    }

    if ($undo.CreatedPlan -and $planGuids -contains $undo.CreatedPlan -and $undo.CreatedPlan -ne $target) {
        powercfg /delete $undo.CreatedPlan | Out-Host
        if ($LASTEXITCODE -eq 0) {
            Write-Host 'Removed the Ultimate Performance plan WhySoSleepy added.' -ForegroundColor Green
            $undo.CreatedPlan = $null
        }
        else {
            Write-Host 'Could not remove the Ultimate Performance plan.' -ForegroundColor Red
            $ok = $false
        }
    }
    elseif ($planGuids -notcontains $undo.CreatedPlan) {
        $undo.CreatedPlan = $null
    }

    # Whatever was restored is dropped from the undo file; anything that
    # failed stays so it can be retried.
    $null = Save-UndoState -Undo $undo

    Write-Host ''
    if ($ok) {
        Write-Host 'All saved settings restored.' -ForegroundColor Green
    }
    else {
        Write-Host 'Some settings could not be restored. They are still saved, so you can try again.' -ForegroundColor Yellow
    }
}

function Switch-ToBalanced {
    powercfg /setactive $BalancedSchemeGuid | Out-Host
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'Balanced plan activated.' -ForegroundColor Green
    }
    else {
        Write-Host 'Could not activate the Balanced plan.' -ForegroundColor Red
    }
}

function Enable-Hibernation {
    if (-not (Test-Elevation 'Turning hibernation on')) { return }

    powercfg /hibernate on | Out-Host
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'Hibernation turned back on (Fast Startup is available again).' -ForegroundColor Green
    }
    else {
        Write-Host 'Could not turn hibernation on.' -ForegroundColor Red
    }
}

function Remove-UltimatePlan {
    # Removes copies of Ultimate Performance; the built-in scheme is left alone.
    $copies = @(Find-UltimatePlan | Where-Object { $_.Guid -ne $UltimateSchemeGuid })
    if (-not $copies.Count) {
        Write-Host 'There is no Ultimate Performance plan to remove.'
        return
    }

    Write-Host 'This removes:'
    foreach ($plan in $copies) { Write-Host "  - $($plan.Name) ($($plan.Guid))" }
    Write-Host ''
    if (-not (Confirm-Action 'Continue?')) {
        Write-Host 'Cancelled.'
        return
    }

    # The active plan cannot be deleted, so switch away from it first: back to
    # the plan saved for Undo, or to Balanced.
    $copyGuids = @($copies | ForEach-Object { $_.Guid })
    if ($copies | Where-Object { $_.Active }) {
        $undo     = Get-UndoState
        $fallback = $BalancedSchemeGuid
        $plans    = @(Get-PowerPlan | ForEach-Object { $_.Guid })
        if ($undo.ActiveScheme -and $copyGuids -notcontains $undo.ActiveScheme -and $plans -contains $undo.ActiveScheme) {
            $fallback = $undo.ActiveScheme
        }

        powercfg /setactive $fallback | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'Could not switch away from Ultimate Performance; nothing was removed.' -ForegroundColor Red
            return
        }
        Write-Host "Switched to $(Get-PlanName -Guid $fallback -Plans @(Get-PowerPlan))."
    }

    foreach ($plan in $copies) {
        powercfg /delete $plan.Guid | Out-Host
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Removed $($plan.Name)." -ForegroundColor Green
        }
        else {
            Write-Host "Could not remove $($plan.Name)." -ForegroundColor Red
        }
    }

    # Forget the removed plan so Undo does not try to remove it again.
    $undo = Get-UndoState
    if ($undo.CreatedPlan -and $copyGuids -contains $undo.CreatedPlan) {
        $undo.CreatedPlan = $null
        $null = Save-UndoState -Undo $undo
    }
}

function Restore-DefaultPowerPlan {
    Write-Host 'This resets every power plan to the Windows defaults and DELETES all'
    Write-Host 'custom power plans, including ones made by your PC maker or IT.'
    Write-Host ''
    if (-not (Confirm-Action 'Restore the default power plans?')) {
        Write-Host 'Cancelled.'
        return
    }

    powercfg /restoredefaultschemes | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Could not restore the default power plans.' -ForegroundColor Red
        return
    }
    Write-Host 'Default power plans restored.' -ForegroundColor Green

    # Saved plan and timeout values no longer apply; hibernation is separate.
    $undo = Get-UndoState
    $undo.ActiveScheme = $null
    $undo.CreatedPlan  = $null
    $undo.Timeouts     = @()
    $null = Save-UndoState -Undo $undo
}

function Show-UndoMenu {
    while ($true) {
        Show-Screen 'UNDO CHANGES'
        Write-UndoSummary -Undo (Get-UndoState) -Plans @(Get-PowerPlan)
        Write-Host ''
        Write-Host '1. Restore saved settings'
        Write-Host '2. Switch to the Balanced plan'
        Write-Host '3. Turn hibernation back on'
        Write-Host '4. Remove the Ultimate Performance plan'
        Write-Host '5. Restore Windows default power plans'
        Write-Host '0. Back'
        Write-Host ''

        switch (Read-MenuChoice) {
            '1' { Write-Host ''; Restore-SavedSetting; Wait-ForEnter }
            '2' { Write-Host ''; Switch-ToBalanced; Wait-ForEnter }
            '3' { Write-Host ''; Enable-Hibernation; Wait-ForEnter }
            '4' { Write-Host ''; Remove-UltimatePlan; Wait-ForEnter }
            '5' { Write-Host ''; Restore-DefaultPowerPlan; Wait-ForEnter }
            '0' { return }
            default { Write-InvalidOption }
        }
    }
}

#endregion

#region Reports

function New-PowercfgReport {
    # Runs a powercfg report command, saves the HTML to the Desktop and opens it.
    param(
        [string]$Title,
        [string]$FileName,
        [string[]]$Arguments,
        [string]$Note
    )

    Show-Screen $Title
    if (-not (Test-Elevation 'Generating this report')) { return }

    $path = Join-Path (Get-DesktopPath) $FileName
    if ($Note) {
        Write-Host $Note
        Write-Host ''
    }

    $started = (Get-Date).AddSeconds(-1)
    & powercfg @Arguments /output $path | Out-Host

    # Check the timestamp so a stale report from an earlier run is not opened.
    $report = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if ($report -and $report.LastWriteTime -ge $started) {
        Write-Host ''
        Write-Host "Saved to $path" -ForegroundColor Green
        Open-Report $path
    }
    else {
        Write-Host ''
        Write-Host 'powercfg did not produce a report (see messages above).' -ForegroundColor Red
    }
}

function Get-ReportLine {
    param($State)

    "$AppTitle report"
    "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    ''

    foreach ($section in Get-DiagnosticSection -State $State) {
        $Rule
        $section.Title
        $Rule
        $section.Lines
        ''
    }

    $Rule
    'FINAL ANALYSIS'
    $Rule
    Get-Analysis -State $State | ForEach-Object { $_.Text }
}

function Export-Report {
    Show-Screen 'TEXT REPORT'
    Write-Host 'Collecting diagnostics, please wait...'

    $path  = Join-Path (Get-DesktopPath) 'WhySoSleepyReport.txt'
    $lines = @(Get-ReportLine -State (Get-SystemState))

    try {
        Set-Content -LiteralPath $path -Value $lines -Encoding UTF8 -ErrorAction Stop
        Write-Host ''
        Write-Host "Saved to $path" -ForegroundColor Green
    }
    catch {
        Write-Host "Could not save the report: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Show-ReportMenu {
    while ($true) {
        Show-Screen 'REPORTS'
        Write-Host 'Reports are saved to your Desktop.'
        Write-Host ''
        Write-Host '1. Sleep Study report (HTML)'
        Write-Host '2. Energy report (HTML, takes 30 seconds)'
        Write-Host '3. Text report with all diagnostics'
        Write-Host '0. Back'
        Write-Host ''

        switch (Read-MenuChoice) {
            '1' {
                New-PowercfgReport -Title 'SLEEP STUDY REPORT' -FileName 'SleepStudy.html' -Arguments '/sleepstudy'
                Wait-ForEnter
            }
            '2' {
                New-PowercfgReport -Title 'ENERGY REPORT' -FileName 'EnergyReport.html' `
                    -Arguments '/energy', '/duration', '30' `
                    -Note 'Tracing system activity for 30 seconds. Leave the PC idle until it finishes.'
                Wait-ForEnter
            }
            '3' { Export-Report; Wait-ForEnter }
            '0' { return }
            default { Write-InvalidOption }
        }
    }
}

#endregion

#region Main

if (-not $NoElevate -and $PSCommandPath -and -not (Test-IsAdmin)) {
    try {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -ErrorAction Stop
        exit 0
    }
    catch {
        Write-Host 'Administrator rights were not granted. Continuing with limited functionality.' -ForegroundColor Yellow
        Start-Sleep -Seconds 2
    }
}

try { $Host.UI.RawUI.WindowTitle = $AppTitle } catch { }

$isAdmin = Test-IsAdmin

while ($true) {
    Clear-Host
    Write-Header $AppTitle

    if ($isAdmin) {
        Write-Host 'Running as Administrator' -ForegroundColor Green
    }
    else {
        Write-Host 'Not running as Administrator - some options are limited' -ForegroundColor Yellow
    }
    Write-Host ''

    Write-Host '1. Run Diagnostics'
    Write-Host '2. Keep Awake (temporary)'
    Write-Host '3. Set Sleep Timeout'
    Write-Host '4. Disable Sleep'
    Write-Host '5. Disable Sleep + Hibernation'
    Write-Host '6. Power Plans >'
    Write-Host '7. Reports >'
    Write-Host '8. Undo Changes >'
    Write-Host '0. Exit'
    Write-Host ''

    switch (Read-MenuChoice) {
        '1' { Invoke-SleepDiagnostic; Wait-ForEnter }
        '2' { Start-KeepAwake; Wait-ForEnter }
        '3' { Set-SleepTimeout; Wait-ForEnter }
        '4' { Disable-Sleep; Wait-ForEnter }
        '5' { Disable-SleepAndHibernation; Wait-ForEnter }
        '6' { Show-PowerPlanMenu }
        '7' { Show-ReportMenu }
        '8' { Show-UndoMenu }
        '0' { exit 0 }
        default { Write-InvalidOption }
    }
}

#endregion
