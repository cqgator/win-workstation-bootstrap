# win-workstation-bootstrap

A modular, idempotent PowerShell utility that bootstraps, configures, and audits
fresh Windows engineering workstations: elevation verification, Chocolatey
package management, Explorer/performance tweaks, and network stack health
checks — designed to be re-run safely at any time with zero side effects on a
machine that's already in the desired state.

## Why this exists

Manually re-imaging or hand-configuring engineering workstations doesn't scale
past a handful of machines, and GUI-driven provisioning tools don't compose
well with source control, code review, or CI. This project treats workstation
setup the same way you'd treat infrastructure-as-code: declarative desired
state, idempotent execution, and a script you can read top to bottom and trust.

## Architecture

`Bootstrap-Workstation.ps1` is a single script organized as a set of pure-ish
functions called from one orchestrator (`Invoke-Bootstrap`). This mirrors the
shape a real module would take (`.psm1` + `.psd1` + `Public/Private` folders)
without the overhead of a full module manifest for a project this size — the
functions are already boundary-clean, so splitting them out later is a
copy-paste operation, not a rewrite.

| Function | Responsibility |
|---|---|
| `Test-Elevation` | Confirms the session is running as Administrator before any mutation occurs |
| `Install-ChocolateyIfMissing` | Installs Chocolatey only if `choco.exe` isn't already on PATH |
| `Install-ChocoPackages` | Diffs the desired package list against installed packages, installs only the delta |
| `Set-RegistryValueIdempotent` | Generic idempotent registry-write helper used by all tweak functions |
| `Set-ExplorerTweaks` | Applies a small set of engineering-friendly Explorer defaults |
| `Test-NetworkHealth` | Validates adapter status, gateway reachability, DNS resolution, and HTTPS egress |
| `Write-BootstrapLog` | Timestamped, leveled logging to console and a persistent log file |
| `Invoke-Bootstrap` | Orchestrates the above in order, with centralized error handling and exit codes |

## Idempotency model

Every mutating function follows the same pattern: **read current state, compare
to desired state, act only on the delta.**

- Chocolatey install checks for `choco.exe` on PATH before downloading anything.
- Package installation queries `choco list --local-only` once up front and
  skips any package already present, instead of shelling out per-package or
  blindly re-running `choco install`.
- Registry tweaks read the existing value with `Get-ItemProperty` and only
  write when the current value differs from the target.

Running the script twice in a row produces identical system state and a log
file showing every second-run action as `Skipping` rather than performing
redundant work or throwing errors.

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-SkipChocolatey` | switch | off | Skip Chocolatey install and package deployment |
| `-PackageList` | string[] | curated default set (git, vscode, python, powershell-core, 7zip, sysinternals, notepadplusplus) | Override the packages to install |
| `-SkipPerformanceTweaks` | switch | off | Skip Explorer/registry tweaks |
| `-SkipNetworkCheck` | switch | off | Skip network stack validation |
| `-LogPath` | string | `%ProgramData%\WorkstationBootstrap\bootstrap.log` | Log file destination |
| `-WhatIf` / `-Confirm` | (built-in) | — | Standard `SupportsShouldProcess` dry-run and confirmation support |

## Usage

```powershell
# Full run with defaults
.\Bootstrap-Workstation.ps1

# Dry run -- see every action that would be taken, change nothing
.\Bootstrap-Workstation.ps1 -WhatIf

# Custom package set, skip registry tweaks
.\Bootstrap-Workstation.ps1 -PackageList @('git','vscode','python') -SkipPerformanceTweaks

# Package management and tweaks only, no network validation
.\Bootstrap-Workstation.ps1 -SkipNetworkCheck
```

## Compatibility

Tested on Windows PowerShell 5.1 and PowerShell 7.4+. The script deliberately
avoids syntax unique to one version (ternary operators, null-coalescing
operators, `ForEach-Object -Parallel`) so it runs unmodified on both, which
matters in fleets where hosts are mid-migration between the two runtimes.

## Requirements

- Windows 10/11 or Windows Server 2016+
- Elevated (Administrator) PowerShell session
- Outbound HTTPS access (for Chocolatey install and package downloads)

## Roadmap

- [ ] Split into a proper module (`WorkstationBootstrap.psm1`) with Pester tests
- [ ] Config-driven package/tweak definitions (JSON/YAML) instead of hardcoded arrays
- [ ] Optional integration with a central logging endpoint (e.g., Log Analytics)