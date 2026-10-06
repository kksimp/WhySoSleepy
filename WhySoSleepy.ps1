$Host.UI.RawUI.WindowTitle = "WhySoSleepy v3.0"

function Pause-Menu {
    Write-Host ""
    Read-Host "Press Enter to return to menu"
}

function Open-File {
    param($Path)

    $Chrome64 = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
    $Chrome32 = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"

    if (Test-Path $Chrome64) {
        Start-Process $Chrome64 $Path
    }
    elseif (Test-Path $Chrome32) {
        Start-Process $Chrome32 $Path
    }
    else {
        Start-Process $Path
    }
}

function Show-Analysis {

    $DomainJoined = $false
    $EntraJoined = $false
    $MDM = $false
    $ModernStandby = $false

    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        $DomainJoined = $cs.PartOfDomain
    } catch {}

    try {
        $ds = dsregcmd /status

        if ($ds -match "AzureAdJoined\s*:\s*YES") {
            $EntraJoined = $true
        }
    } catch {}

    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Enrollments") {
        $MDM = $true
    }

    try {
        $power = powercfg /a

        if ($power -match "S0 Low Power Idle") {
            $ModernStandby = $true
        }
    } catch {}

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "FINAL ANALYSIS" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "Domain Joined    : $DomainJoined"
    Write-Host "Entra Joined     : $EntraJoined"
    Write-Host "MDM Enrolled     : $MDM"
    Write-Host "Modern Standby   : $ModernStandby"

    Write-Host ""

    if ($MDM) {
        Write-Host "[1] Intune / MDM Policy is a likely controller." -ForegroundColor Yellow
    }

    if ($DomainJoined) {
        Write-Host "[2] Group Policy is a likely controller." -ForegroundColor Yellow
    }

    Write-Host "[3] Local Power Plan may control sleep."

    if ($ModernStandby) {
        Write-Host ""
        Write-Host "Modern Standby (S0) detected." -ForegroundColor Green
        Write-Host "Sleep behavior may be controlled by Intune, Policy CSP, or GPO."
    }

    Write-Host ""
}

function Run-Diagnostics {

    Clear-Host

    Write-Host "============================================================"
    Write-Host "DOMAIN STATUS"
    Write-Host "============================================================"

    Get-CimInstance Win32_ComputerSystem |
        Select-Object Domain, PartOfDomain

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "ACTIVE POWER PLAN"
    Write-Host "============================================================"

    powercfg /getactivescheme

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "AVAILABLE POWER STATES"
    Write-Host "============================================================"

    powercfg /a

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "CURRENT SLEEP SETTINGS"
    Write-Host "============================================================"

    powercfg /query SCHEME_CURRENT SUB_SLEEP

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "POWER REQUESTS"
    Write-Host "============================================================"

    powercfg /requests

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "WAKE TIMERS"
    Write-Host "============================================================"

    powercfg /waketimers

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "LAST WAKE"
    Write-Host "============================================================"

    powercfg /lastwake

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "WAKE DEVICES"
    Write-Host "============================================================"

    powercfg /devicequery wake_armed

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "ENTRA STATUS"
    Write-Host "============================================================"

    dsregcmd /status | Select-String "AzureAdJoined","DomainJoined","WorkplaceJoined"

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "MDM ENROLLMENT"
    Write-Host "============================================================"

    reg query HKLM\SOFTWARE\Microsoft\Enrollments

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "TANIUM DETECTION"
    Write-Host "============================================================"

    Get-Service *tanium* -ErrorAction SilentlyContinue

    Write-Host ""
    tasklist | findstr /i tanium

    Show-Analysis
}

function Set-SleepTimeout {

    Clear-Host

    Write-Host "============================================================"
    Write-Host "SET SLEEP TIMEOUT"
    Write-Host "============================================================"
    Write-Host ""
    Write-Host "0    = Never"
    Write-Host "5    = 5 Minutes"
    Write-Host "15   = 15 Minutes"
    Write-Host "30   = 30 Minutes"
    Write-Host "60   = 1 Hour"
    Write-Host "120  = 2 Hours"
    Write-Host "240  = 4 Hours"
    Write-Host "480  = 8 Hours"
    Write-Host "720  = 12 Hours"
    Write-Host "1440 = 24 Hours"
    Write-Host ""

    $Minutes = Read-Host "Enter timeout in minutes (0-1440)"

    if (-not ($Minutes -match '^\d+$')) {
        Write-Host "Invalid number." -ForegroundColor Red
        return
    }

    if ([int]$Minutes -gt 1440) {
        Write-Host "Maximum is 1440." -ForegroundColor Red
        return
    }

    powercfg /change standby-timeout-ac $Minutes
    powercfg /change standby-timeout-dc $Minutes
    powercfg /change monitor-timeout-ac $Minutes
    powercfg /change monitor-timeout-dc $Minutes

    Write-Host ""
    Write-Host "Successfully applied." -ForegroundColor Green
}

function Disable-Sleep {

    powercfg /change standby-timeout-ac 0
    powercfg /change standby-timeout-dc 0
    powercfg /change monitor-timeout-ac 0
    powercfg /change monitor-timeout-dc 0

    Write-Host ""
    Write-Host "Sleep disabled." -ForegroundColor Green
}

function Show-Plans {
    powercfg /list
}

function Create-Ultimate {
    powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61
}

function Enable-Ultimate {

    try {
        Create-Ultimate | Out-Null
    } catch {}

    $Ultimate = powercfg /list | Select-String "Ultimate"

    if ($Ultimate) {

        $Guid = :Match($Ultimate.Line,
            "[0-9a-fA-F-]{36}").Value

        powercfg /setactive $Guid

        Write-Host ""
        Write-Host "Ultimate Performance Activated" -ForegroundColor Green
    }
}

function Ultimate-NoSleep {

    Enable-Ultimate

    powercfg /hibernate off

    powercfg /change standby-timeout-ac 0
    powercfg /change standby-timeout-dc 0

    powercfg /change monitor-timeout-ac 0
    powercfg /change monitor-timeout-dc 0

    Write-Host ""
    Write-Host "Ultimate + No Sleep Enabled" -ForegroundColor Green
}

function SleepStudy {

    $Report = "$env:USERPROFILE\Desktop\SleepStudy.html"

    powercfg /sleepstudy /output $Report

    Open-File $Report
}

function EnergyReport {

    $Report = "$env:USERPROFILE\Desktop\EnergyReport.html"

    powercfg /energy /duration 30 /output $Report

    Open-File $Report
}

function Export-Report {

    $Report = "$env:USERPROFILE\Desktop\WhySoSleepyReport.txt"

    "WhySoSleepy Report" | Out-File $Report

    powercfg /getactivescheme | Out-File $Report -Append
    powercfg /a | Out-File $Report -Append
    powercfg /requests | Out-File $Report -Append
    powercfg /waketimers | Out-File $Report -Append
    powercfg /lastwake | Out-File $Report -Append

    Write-Host ""
    Write-Host "Saved to $Report" -ForegroundColor Green
}

do {

    Clear-Host

    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "WhySoSleepy v3.0" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "1. Run Diagnostics"
    Write-Host "2. Set Sleep Timeout"
    Write-Host "3. Disable Sleep"
    Write-Host "4. Show Power Plans"
    Write-Host "5. Enable Ultimate Performance"
    Write-Host "6. Ultimate + Disable Sleep"
    Write-Host "7. Generate Sleep Study Report"
    Write-Host "8. Generate Energy Report"
    Write-Host "9. Export Report"
    Write-Host "0. Exit"
    Write-Host ""

    $Choice = Read-Host "Select Option"

    switch ($Choice) {

        "1" { Run-Diagnostics; Pause-Menu }
        "2" { Set-SleepTimeout; Pause-Menu }
        "3" { Disable-Sleep; Pause-Menu }
        "4" { Show-Plans; Pause-Menu }
        "5" { Enable-Ultimate; Pause-Menu }
        "6" { Ultimate-NoSleep; Pause-Menu }
        "7" { SleepStudy; Pause-Menu }
        "8" { EnergyReport; Pause-Menu }
        "9" { Export-Report; Pause-Menu }
        "0" { return }
    }

} while ($true)