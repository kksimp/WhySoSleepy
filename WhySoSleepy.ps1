<#
.SYNOPSIS
    Diagnose and control Windows sleep behavior.

.DESCRIPTION
    WhySoSleepy is an interactive menu that helps figure out why a Windows PC
    goes to sleep and what is in control of that: the local power plan, Group
    Policy, Intune / MDM, or a management agent such as Configuration Manager or
    Tanium. It can also change sleep and display timeouts, switch to the
    Ultimate Performance power plan, and generate powercfg reports.

    Several diagnostics need Administrator rights. When started without them,
    the script asks to relaunch itself elevated (UAC prompt). If that is
    declined it keeps running with limited functionality.

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

$ScriptVersion = '3.1'
$AppTitle      = "WhySoSleepy v$ScriptVersion"
$Rule          = '=' * 60
$GuidPattern   = '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'

# Built-in (hidden) scheme that "Ultimate Performance" plans are copied from,
# and the GUID WhySoSleepy gives its copy so it can find it again on any
# Windows display language.
$UltimateSchemeGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$UltimatePlanGuid   = 'e28c86af-35f3-4692-9b2d-b89202566d6f'

# Friendly names for power setting GUIDs that commonly show up in policies.
$PowerSettingNames = @{
    '29f6c1db-86da-48c5-9fdb-f2b67b1f44da' = 'Sleep after (seconds)'
    '9d7815a6-7ee4-497e-8888-515a05f02364' = 'Hibernate after (seconds)'
    '7bc4a2f9-d8fc-4469-b07b-33eb785aaca0' = 'Unattended sleep timeout (seconds)'
    '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e' = 'Turn off display after (seconds)'
    'abfc2519-3608-4c2a-94ea-171b0ed546ab' = 'Allow standby states S1-S3'
    '94ac6d29-73ce-41a6-809f-6363ba21b47e' = 'Hybrid sleep'
    'bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d' = 'Allow wake timers'
    '5ca83367-6e45-459f-a27b-476b1d01c936' = 'Lid close action'
    '7648efa3-dd9c-4e3e-b566-50f929386280' = 'Power button action'
    '96996bc0-ad50-47ec-923b-6f41874dd9eb' = 'Sleep button action'
    '0e796bdb-100d-47d6-a2d5-f7d2daa51f51' = 'Require password on wake'
}

#region Console helpers

function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
    Read-Host 'Press Enter to return to menu' | Out-Null
}

function Confirm-Action {
    param([string]$Prompt)

    $answer = Read-Host "$Prompt [y/N]"
    return ($answer -match '^\s*y(es)?\s*$')
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
    $desktop = [Environment]::GetFolderPath('Desktop')
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

function Get-SystemState {
    # Every probe is best effort: anything that fails shows up as Unknown or empty.
    $cs = $null
    $os = $null
    try { $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop } catch { }
    try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { }

    $dsreg = @()
    try { $dsreg = @(dsregcmd /status 2>$null) } catch { }

    $availableStates = @(Get-AvailableSleepState)

    [pscustomobject]@{
        ComputerName     = $env:COMPUTERNAME
        OperatingSystem  = if ($os) { "$($os.Caption) (build $($os.BuildNumber))" } else { 'Unknown' }
        IsAdmin          = Test-IsAdmin
        Domain           = if ($cs) { $cs.Domain } else { 'Unknown' }
        DomainJoined     = [bool]($cs -and $cs.PartOfDomain)
        EntraJoined      = [bool]($dsreg -match '^\s*AzureAdJoined\s*:\s*YES')
        JoinStatus       = @($dsreg -match '^\s*(AzureAdJoined|EnterpriseJoined|DomainJoined|WorkplaceJoined)\s*:' |
                             ForEach-Object { $_.Trim() })
        MdmEnrollments   = @(Get-MdmEnrollment)
        AvailableStates  = $availableStates
        ModernStandby    = [bool]($availableStates -match '\bS0\b')
        PolicySettings   = @(Get-PolicyPowerSetting)
        PolicyActivePlan = Get-PolicyActivePlan
        MdmPowerPolicies = @(Get-MdmPowerPolicy)
        ManagementAgents = @(Get-ManagementAgent)
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
            $State.PolicySettings | ConvertTo-TableText
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
    New-Section 'POWER REQUESTS'      { powercfg /requests }
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

    New-Finding Plain "Domain joined      : $($yesNo[$State.DomainJoined])"
    New-Finding Plain "Entra ID joined    : $($yesNo[$State.EntraJoined])"
    New-Finding Plain "MDM enrolled       : $mdmSummary"
    New-Finding Plain "Modern Standby     : $($yesNo[$State.ModernStandby])"
    New-Finding Plain "Policy settings    : $($State.PolicySettings.Count) Group Policy / ADMX, $($State.MdmPowerPolicies.Count) MDM CSP"
    New-Finding Plain "Management agents  : $agentSummary"
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
        New-Finding Info 'Settings not listed above come from the local power plan.'
    }
    else {
        New-Finding Good 'No power policy or management agent found: the local power plan controls sleep,',
                         'so changes made with options 2, 3, 5 and 6 should stick.'
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
    Show-Screen 'EXPORT REPORT'
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

#endregion

#region Power changes

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

    $answer  = Read-Host 'Enter timeout in minutes (0-1440)'
    $minutes = 0

    if (-not [int]::TryParse("$answer".Trim(), [ref]$minutes) -or $minutes -lt 0 -or $minutes -gt 1440) {
        Write-Host 'Please enter a whole number from 0 to 1440.' -ForegroundColor Red
        return
    }

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

function Show-PowerPlanList {
    Show-Screen 'POWER PLANS'
    powercfg /list | Out-Host
    Write-Host '* = active plan'
}

function Get-UltimatePlanGuid {
    # Reuse an existing Ultimate Performance plan (ours, the built-in one, or a
    # copy made by hand or by an older version): /duplicatescheme creates a
    # brand new copy every time it runs.
    foreach ($line in @(powercfg /list)) {
        if ($line -match "$UltimatePlanGuid|$UltimateSchemeGuid|Ultimate" -and $line -match $GuidPattern) {
            return $Matches[0]
        }
    }

    $output = powercfg /duplicatescheme $UltimateSchemeGuid $UltimatePlanGuid 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    if ("$output" -match $GuidPattern) { return $Matches[0] }
    return $UltimatePlanGuid
}

function Enable-UltimatePerformance {
    # Returns $true when the Ultimate Performance plan ends up active.
    $guid = Get-UltimatePlanGuid
    if (-not $guid) {
        Write-Host 'The Ultimate Performance plan could not be created.' -ForegroundColor Red
        Write-Host 'It is usually unavailable on Modern Standby (S0) devices.' -ForegroundColor Red
        return $false
    }

    powercfg /setactive $guid | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Could not activate the Ultimate Performance plan ($guid)." -ForegroundColor Red
        return $false
    }

    Write-Host "Ultimate Performance plan activated ($guid)." -ForegroundColor Green
    return $true
}

function Enable-UltimateNoSleep {
    Show-Screen 'ULTIMATE PERFORMANCE + DISABLE SLEEP'

    Write-Host 'This will:'
    Write-Host '  - Activate the Ultimate Performance power plan'
    Write-Host '  - Turn hibernation off (this also disables Fast Startup)'
    Write-Host '  - Set the sleep and display timeouts to Never'
    Write-Host ''

    if (-not (Test-Elevation 'Turning hibernation off')) { return }
    if (-not (Confirm-Action 'Continue?')) {
        Write-Host 'Cancelled.'
        return
    }
    Write-Host ''

    # Timeouts apply to the active plan, so switch plans first. If the switch
    # fails, sleep is still disabled on the current plan.
    $null = Enable-UltimatePerformance

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
        Write-Host 'Not running as Administrator - options 6-8 are unavailable' -ForegroundColor Yellow
    }
    Write-Host ''

    Write-Host '1. Run Diagnostics'
    Write-Host '2. Set Sleep Timeout'
    Write-Host '3. Disable Sleep'
    Write-Host '4. Show Power Plans'
    Write-Host '5. Enable Ultimate Performance'
    Write-Host '6. Ultimate + Disable Sleep'
    Write-Host '7. Generate Sleep Study Report'
    Write-Host '8. Generate Energy Report'
    Write-Host '9. Export Report'
    Write-Host '0. Exit'
    Write-Host ''

    $choice = Read-Host 'Select option'

    switch ("$choice".Trim()) {
        '1' { Invoke-SleepDiagnostic; Wait-ForEnter }
        '2' { Set-SleepTimeout; Wait-ForEnter }
        '3' { Disable-Sleep; Wait-ForEnter }
        '4' { Show-PowerPlanList; Wait-ForEnter }
        '5' {
            Show-Screen 'ENABLE ULTIMATE PERFORMANCE'
            if (Enable-UltimatePerformance) { Write-PolicyWarning }
            Wait-ForEnter
        }
        '6' { Enable-UltimateNoSleep; Wait-ForEnter }
        '7' {
            New-PowercfgReport -Title 'SLEEP STUDY REPORT' -FileName 'SleepStudy.html' -Arguments '/sleepstudy'
            Wait-ForEnter
        }
        '8' {
            New-PowercfgReport -Title 'ENERGY REPORT' -FileName 'EnergyReport.html' `
                -Arguments '/energy', '/duration', '30' `
                -Note 'Tracing system activity for 30 seconds. Leave the PC idle until it finishes.'
            Wait-ForEnter
        }
        '9' { Export-Report; Wait-ForEnter }
        '0' { exit 0 }
        default {
            Write-Host 'Invalid option.' -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}

#endregion
