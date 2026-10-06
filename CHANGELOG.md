# Changelog

## 3.2

### Added

- **Keep Awake (option 2):** keeps the PC, and optionally the display, awake for 1-1440 minutes or until you press Q. It changes no settings and needs no admin rights, so it also works on PCs where policy controls the sleep timeouts. It warns when policy stops apps from preventing sleep.
- **Undo Changes menu (option 8):** WhySoSleepy now saves the active plan, timeouts and hibernation state before it first changes them, and **Restore saved settings** puts them back (including removing the Ultimate Performance plan it added). The menu also offers: switch to Balanced, turn hibernation back on, remove Ultimate Performance, and restore the Windows default plans.
- The analysis now lists what is keeping the PC awake right now, from `powercfg /requests`, with readable names. For example: "Microsoft Teams (ms-teams.exe) is keeping the display on (Video Wake Lock)".
- **Power Plans submenu (option 6):** a numbered plan list with the active plan highlighted, plus switching to any plan.

### Changed

- The main menu is reorganized, with submenus for Power Plans, Reports and Undo.
- Ultimate Performance moved into the Power Plans submenu and is no longer part of "disable sleep". The old option 6 is now **Disable Sleep + Hibernation** (option 5).
- Enabling Ultimate Performance now notes that it uses more power, and says when it is already active.
- Admin detection works in Constrained Language Mode.

## 3.1

### Fixed

- **Enable Ultimate Performance** (options 5 and 6) never switched plans because of a broken `[regex]::Match` call.
- Enabling Ultimate Performance no longer creates another copy of the plan on every run. An existing copy is reused.
- **MDM Enrolled** was reported as true on almost every PC, because the `Enrollments` registry key exists even on unmanaged devices. Only real enrollments (with a `ProviderID`) are counted now.
- **Modern Standby** was reported as true on most S3 PCs, because `powercfg /a` also lists S0 under "not available". Only available states are checked now.
- Reports failed to open in Chrome when the file path contained spaces.
- Reports and exports now go to the real Desktop when OneDrive (or another redirection) has moved it.
- Diagnostic tables could print out of order with the section headers.
- Success messages appeared even when `powercfg` failed. Each change is now checked.

### Added

- Detection of power settings enforced by Group Policy / ADMX and by Intune / MDM (Policy CSP), and of a policy-forced power plan.
- Configuration Manager client detection, alongside Tanium.
- A clearer final analysis that says whether local changes will stick.
- A warning after a change when a policy may override it.
- Self-elevation through UAC, with a limited mode if it is declined. Use `-NoElevate` to skip the prompt.
- Diagnostics now include the display timeout and Entra ID / domain join status.
- The text report (option 9) now contains every diagnostic plus the final analysis, and is saved as UTF-8.
- A confirmation prompt before option 6, which turns hibernation off.
- An "Invalid option" message in the menu.
- A notice that the Energy report takes 30 seconds.

### Changed

- **Disable Sleep** (option 3) also sets the hibernate timeout to Never, so the PC doesn't hibernate instead.
- Admin-only options (6-8) explain that they need elevation instead of failing with `powercfg` errors.
- The launcher passes arguments through to the script and pauses if the script fails, so errors stay visible.
- Added `.gitattributes` to keep Windows line endings in the scripts.

## 3.0

- Initial public release.
