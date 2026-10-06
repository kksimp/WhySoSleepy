# WhySoSleepy

Find out why your Windows PC keeps going to sleep, what is in control of it, and what is keeping it awake.

WhySoSleepy is a menu-driven PowerShell tool. It collects `powercfg` diagnostics, works out what controls sleep on the device (the local power plan, Group Policy, Intune / MDM, or a management agent), and shows which apps are keeping the PC awake right now. It can keep the PC awake for a while without changing any settings, change sleep settings, manage power plans and generate reports to send to your IT team. Everything it changes can be undone from the menu.

## Features

- **Diagnostics in one place:** active power plan, available sleep states, sleep and display settings, power requests, wake timers, last wake source and wake-armed devices.
- **Finds the controller:** detects Group Policy / ADMX power settings, Intune / MDM Power policies, MDM enrollment, Entra ID and domain join, and Configuration Manager or Tanium clients.
- **Plain-language analysis:** whether local changes will stick, and what is keeping the PC awake (for example "Microsoft Teams is keeping the display on").
- **Keep Awake:** keeps the PC awake for a set time without changing settings. It works without admin rights, even on managed PCs.
- **Quick fixes:** set sleep and display timeouts, disable sleep, disable hibernation, or switch power plans (including Ultimate Performance).
- **Undo:** settings are saved before WhySoSleepy first changes them, and one menu option puts them back.
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
| 2 | Keep Awake (temporary) | Keeps the PC (and optionally the display) awake for 1-1440 minutes, or until you press Q. See [Keep Awake](#keep-awake). | No | - |
| 3 | Set Sleep Timeout | Sets the sleep **and** display-off timeouts (0-1440 minutes, 0 = never) on the active plan, plugged in and on battery. | Yes | - |
| 4 | Disable Sleep | Sets the sleep, hibernate and display-off timeouts to Never on the active plan. | Yes | - |
| 5 | Disable Sleep + Hibernation | Turns hibernation off, then sets the sleep and display timeouts to Never. Asks for confirmation first. | Yes | Required |
| 6 | Power Plans | Submenu: lists the power plans and lets you switch plan or enable Ultimate Performance. | Yes | - |
| 7 | Reports | Submenu: Sleep Study, Energy and text reports. | No | See below |
| 8 | Undo Changes | Submenu: puts back the settings WhySoSleepy changed. See [Undoing changes](#undoing-changes). | Yes | Some options |

**Recommended:** works without admin rights, but power requests and wake timers can't be read. **-** means no elevation is needed, although a device policy can still block or revert the change.

Turning hibernation off (option 5) also disables Fast Startup and removes `hiberfil.sys`. **Undo Changes** turns it back on.

### Power Plans submenu

| # | Option | What it does |
|---|--------|--------------|
| 1 | Switch plan | Activates any plan from the list. The active plan is shown in green. |
| 2 | Enable Ultimate Performance | Creates the Ultimate Performance plan the first time (later runs reuse it) and activates it. It keeps the CPU at full speed, so it uses more power. It is usually unavailable on Modern Standby PCs. |

### Reports submenu

| # | Report | What it does | Admin |
|---|--------|--------------|-------|
| 1 | Sleep Study | Runs `powercfg /sleepstudy` and opens `SleepStudy.html`. | Required |
| 2 | Energy | Watches the system for 30 seconds with `powercfg /energy` and opens `EnergyReport.html`. Leave the PC idle while it runs. | Required |
| 3 | Text report | Saves every diagnostic plus the analysis to `WhySoSleepyReport.txt` to share with IT. | Recommended |

Reports are saved to your Desktop and overwritten each time. WhySoSleepy finds the Desktop even when OneDrive redirects it. If you elevate with a different account (for example, help desk credentials), the files go to that account's Desktop. HTML reports open in Google Chrome when it is installed, otherwise in your default browser.

## Keep Awake

Keep Awake holds a "stay awake" request, the same way video players and presentation apps do, for as long as you choose. It's the option to use on a managed PC where IT controls the sleep timeouts:

- It changes no settings, so there is nothing to undo and policy can't revert it.
- It needs no admin rights.
- It stops when the time runs out, when you press **Q**, or when you close the window. Windows drops the request as soon as WhySoSleepy closes.
- You can choose to keep the display on too. On Modern Standby PCs that is the most reliable choice.

It won't work if IT has disabled **Allow applications to prevent automatic sleep** through policy (WhySoSleepy warns you when that's the case). It also isn't available when PowerShell runs in Constrained Language Mode, which some managed PCs enforce.

## Reading the analysis

The final analysis lists what was detected and how it affects sleep:

| Finding | Detected from | What it means |
|---------|---------------|---------------|
| Power settings enforced by policy | `HKLM\SOFTWARE\Policies\Microsoft\Power\PowerSettings` | Group Policy (or an Intune ADMX-backed policy) sets these values. Windows re-applies them, so local changes don't last. Use Keep Awake, or ask your IT team to change the policy. |
| Intune / MDM power policies | `HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Power` and `...\ADMX_Power` | Intune or another MDM sets power settings through the Policy CSP. These override local settings too. |
| MDM enrolled | Subkeys of `HKLM\SOFTWARE\Microsoft\Enrollments` that have a `ProviderID` (`MS DM Server` is Intune) | The device is managed by an MDM, but no power policies were found. |
| Domain joined, but no power policy | `Win32_ComputerSystem` | Group Policy isn't setting power options. Run `gpresult /h gpresult.html` as Administrator for full detail. |
| Configuration Manager / Tanium | Installed services (`CcmExec`, `Tanium Client`) | Both can push their own power plans and settings. |
| Keeping the PC awake right now | `powercfg /requests` (needs admin) | Apps, services and drivers that are currently stopping sleep or keeping the display on, with the reason they give. For example: *Microsoft Teams (ms-teams.exe) is keeping the display on (Video Wake Lock)*. |
| Modern Standby | An `S0` state in the *available* list of `powercfg /a` | The PC uses connected standby instead of classic S3 sleep. Extra plans such as Ultimate Performance are usually unavailable. |
| No power policy or management agent | Nothing above found | The local power plan is in charge, so changes made with WhySoSleepy should stick. |

### Troubleshooting tips

- **PC sleeps too soon:** check the analysis for enforced policies. If there are none, use option 3 or 4. If there are, use Keep Awake (option 2).
- **PC won't go to sleep:** the analysis lists what is keeping it awake (run as Administrator). Close that app, or wait for it to finish.
- **PC wakes up by itself:** check **LAST WAKE**, **WAKE TIMERS** and **WAKE-ARMED DEVICES**. To stop a device from waking the PC, run `powercfg /devicedisablewake "<device name>"` as Administrator.

## Undoing changes

Before WhySoSleepy first changes something, it saves the current value: the active power plan, the sleep / hibernate / display timeouts of each plan it changes, and whether hibernation was on. It also remembers if it created the Ultimate Performance plan. Only the first value is kept, so Undo always goes back to how things were before you started using WhySoSleepy.

The saved settings are stored in `C:\ProgramData\WhySoSleepy\undo.json`. The **Undo Changes** menu shows what is saved and offers:

| # | Option | What it does | Admin |
|---|--------|--------------|-------|
| 1 | Restore saved settings | Puts back everything listed above and removes the Ultimate Performance plan if WhySoSleepy added it. Restored items are cleared; anything that fails stays saved so you can try again. | Needed to turn hibernation back on |
| 2 | Switch to the Balanced plan | Activates the Windows Balanced plan. | - |
| 3 | Turn hibernation back on | Runs `powercfg /hibernate on`, which also makes Fast Startup available again. | Required |
| 4 | Remove the Ultimate Performance plan | Deletes Ultimate Performance plan copies, switching to another plan first if one is active. | - |
| 5 | Restore Windows default power plans | Runs `powercfg /restoredefaultschemes`. This **deletes all custom plans**, including ones from your PC maker or IT. Asks for confirmation first. | May be required |

Changes made before version 3.2 weren't saved. Use options 2-5, or the commands below.

### Manual commands

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

You can also change timeouts in **Settings > System > Power & battery** (just **Power** on Windows 11 desktops) or **Settings > System > Power & sleep** (Windows 10).

## Notes and limitations

- WhySoSleepy can't override Group Policy, Intune or management agent settings. It shows you that they exist so you know who to ask, and Keep Awake works around timeout policies.
- Policy detection reads the registry, which reflects the most recent policy refresh.
- Run Diagnostics shows `powercfg` output in the Windows display language. Detection works on any language, except that Ultimate Performance plans created by hand are recognized by their English name.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

[Apache License 2.0](LICENSE)
