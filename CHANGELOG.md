# Changelog

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
