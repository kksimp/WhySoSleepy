# WhySoSleepy

Find out why your Windows PC keeps going to sleep, and what is in control of it.

WhySoSleepy is a menu-driven PowerShell tool. It collects `powercfg` diagnostics, works out what controls sleep on the device (the local power plan, Group Policy, Intune / MDM, or a management agent), and lets you change sleep settings or generate reports to send to your IT team.

## Features

- **Diagnostics in one place:** active power plan, available sleep states, sleep and display settings, power requests, wake timers, last wake source and wake-armed devices.
- **Finds the controller:** detects Group Policy / ADMX power settings, Intune / MDM Power policies, MDM enrollment, Entra ID and domain join, and Configuration Manager or Tanium clients.
- **Plain-language analysis:** a summary of what was found and whether local changes will stick.
- **Quick fixes:** set sleep and display timeouts, disable sleep, or switch to the Ultimate Performance plan.
- **Reports:** Sleep Study and Energy HTML reports, plus a text report with every diagnostic and the analysis.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 (built in) or PowerShell 7
- Administrator rights for some options (see [Menu options](#menu-options))

## Getting started

1. Download the repository (**Code > Download ZIP**) and extract it. Keep `WhySoSleepy.bat` and `WhySoSleepy.ps1` in the same folder.
2. Double-click **`WhySoSleepy.bat`**.
3. Approve the UAC prompt. If you decline, or don't have admin rights, WhySoSleepy keeps running with limited functionality.

The batch file runs the script with `-ExecutionPolicy Bypass` for that run only. Your system's execution policy is not changed.

To run the script from a PowerShell window instead:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\WhySoSleepy.ps1

# Don't ask to relaunch as Administrator
powershell.exe -ExecutionPolicy Bypass -File .\WhySoSleepy.ps1 -NoElevate
```

`WhySoSleepy.bat -NoElevate` works too.

> **Blocked download?** Windows may flag files downloaded from the internet. Choose **More info > Run anyway**, or right-click each file, open **Properties** and tick **Unblock**. You can also run `Unblock-File .\WhySoSleepy.ps1, .\WhySoSleepy.bat`.

## Menu options

| # | Option | What it does | Changes settings | Admin |
|---|--------|--------------|------------------|-------|
| 1 | Run Diagnostics | Shows all diagnostics followed by the [final analysis](#reading-the-analysis). | No | Recommended |
| 2 | Set Sleep Timeout | Sets the sleep **and** display-off timeouts (0-1440 minutes, 0 = never) on the active plan, plugged in and on battery. | Yes | - |
| 3 | Disable Sleep | Sets the sleep, hibernate and display-off timeouts to Never on the active plan. | Yes | - |
| 4 | Show Power Plans | Lists the power plans. The active plan is marked with `*`. | No | - |
| 5 | Enable Ultimate Performance | Creates the Ultimate Performance plan the first time (later runs reuse it) and makes it active. | Yes | - |
| 6 | Ultimate + Disable Sleep | Option 5, then turns hibernation off and sets sleep and display timeouts to Never. Asks for confirmation first. | Yes | Required |
| 7 | Generate Sleep Study Report | Runs `powercfg /sleepstudy` and opens the report. | No | Required |
| 8 | Generate Energy Report | Watches the system for 30 seconds with `powercfg /energy` and opens the report. Leave the PC idle while it runs. | No | Required |
| 9 | Export Report | Saves every diagnostic plus the analysis to a text file to share with IT. | No | Recommended |

**Recommended:** works without admin rights, but power requests and wake timers can't be read. **-** means no elevation is needed, although a device policy can still block or revert the change.

Turning hibernation off (option 6) also disables Fast Startup and removes `hiberfil.sys`. See [Undoing changes](#undoing-changes) to turn it back on.

### Output files

Reports are saved to your Desktop and overwritten each time:

| File | Created by |
|------|------------|
| `SleepStudy.html` | Option 7 |
| `EnergyReport.html` | Option 8 |
| `WhySoSleepyReport.txt` | Option 9 |

WhySoSleepy finds the Desktop even when OneDrive redirects it. If you elevate with a different account (for example, help desk credentials), the files go to that account's Desktop. HTML reports open in Google Chrome when it is installed, otherwise in your default browser.

## Reading the analysis

The final analysis lists what was detected and how it affects sleep:

| Finding | Detected from | What it means |
|---------|---------------|---------------|
| Power settings enforced by policy | `HKLM\SOFTWARE\Policies\Microsoft\Power\PowerSettings` | Group Policy (or an Intune ADMX-backed policy) sets these values. Windows re-applies them, so local changes don't last. Ask your IT team to change the policy. |
| Intune / MDM power policies | `HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Power` and `...\ADMX_Power` | Intune or another MDM sets power settings through the Policy CSP. These override local settings too. |
| MDM enrolled | Subkeys of `HKLM\SOFTWARE\Microsoft\Enrollments` that have a `ProviderID` (`MS DM Server` is Intune) | The device is managed by an MDM, but no power policies were found. |
| Domain joined, but no power policy | `Win32_ComputerSystem` | Group Policy isn't setting power options. Run `gpresult /h gpresult.html` as Administrator for full detail. |
| Configuration Manager / Tanium | Installed services (`CcmExec`, `Tanium Client`) | Both can push their own power plans and settings. |
| Modern Standby | An `S0` state in the *available* list of `powercfg /a` | The PC uses connected standby instead of classic S3 sleep. Extra plans such as Ultimate Performance are usually unavailable. |
| No power policy or management agent | Nothing above found | The local power plan is in charge, so changes made with options 2, 3, 5 and 6 should stick. |

### Troubleshooting tips

- **PC sleeps too soon:** check the analysis for enforced policies first, then use option 2 or 3.
- **PC won't go to sleep:** look at **POWER REQUESTS**. It lists the apps, drivers and services that are keeping the PC awake.
- **PC wakes up by itself:** check **LAST WAKE**, **WAKE TIMERS** and **WAKE-ARMED DEVICES**. To stop a device from waking the PC, run `powercfg /devicedisablewake "<device name>"` as Administrator.

## Undoing changes

Run these from an elevated Command Prompt or PowerShell window:

```powershell
# Switch back to the Balanced plan
powercfg /setactive SCHEME_BALANCED

# Turn hibernation (and Fast Startup) back on
powercfg /hibernate on

# Set timeouts in minutes (pick values that suit you)
powercfg /change standby-timeout-ac 30
powercfg /change standby-timeout-dc 15
powercfg /change monitor-timeout-ac 10
powercfg /change monitor-timeout-dc 5
powercfg /change hibernate-timeout-dc 180

# Remove the Ultimate Performance plan (switch to another plan first)
powercfg /list
powercfg /delete <GUID of the Ultimate Performance plan>
```

`powercfg /restoredefaultschemes` resets every plan to the Windows defaults, but it also **deletes all custom plans**.

You can also change timeouts in **Settings > System > Power & battery** (just **Power** on Windows 11 desktops) or **Settings > System > Power & sleep** (Windows 10).

## Notes and limitations

- WhySoSleepy can't override Group Policy, Intune or management agent settings. It shows you that they exist so you know who to ask.
- Policy detection reads the registry, which reflects the most recent policy refresh.
- Run Diagnostics shows `powercfg` output in the Windows display language. Detection works on any language, except that Ultimate Performance plans created by hand are recognized by their English name.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

[Apache License 2.0](LICENSE)
