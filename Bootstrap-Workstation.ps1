#Requires -Version 5.1
<#
.SYNOPSIS
    Bootstraps, configures, and audits a fresh Windows engineering workstation.

.DESCRIPTION
    Bootstrap-Workstation.ps1 performs idempotent setup of a Windows workstation for
    engineering use: verifies elevation, installs/updates the Chocolatey package
    manager, deploys a curated developer toolset, applies Explorer/system
    performance tweaks, and validates network stack health.

    Every mutating action first inspects current state and skips itself if the
    desired state already exists, so the script can be re-run safely on a
    machine that has already been bootstrapped (e.g. after a Windows Update
    or a partial failure).

.PARAMETER SkipChocolatey
    Skip Chocolatey installation and package deployment entirely.

.PARAMETER PackageList
    Override the default developer package set. Accepts an array of Chocolatey
    package IDs. Defaults to a curated list defined in $script:DefaultPackages.

.PARAMETER SkipPerformanceTweaks
    Skip Explorer/registry performance tweaks.

.PARAMETER SkipNetworkCheck
    Skip network stack health validation.

.PARAMETER LogPath
    Path to the log file. Defaults to $env:ProgramData\WorkstationBootstrap\bootstrap.log.

.EXAMPLE
    PS> .\Bootstrap-Workstation.ps1
    Runs full bootstrap with default package list and all checks enabled.

.EXAMPLE
    PS> .\Bootstrap-Workstation.ps1 -WhatIf
    Dry-run: shows every action that would be taken without changing system state.

.EXAMPLE
    PS> .\Bootstrap-Workstation.ps1 -PackageList @('git','vscode','python') -SkipPerformanceTweaks
    Installs only the specified packages and skips registry tweaks.

.NOTES
    Author  : Charlie Q
    Requires: Elevated (Administrator) PowerShell session
    Tested  : Windows PowerShell 5.1, PowerShell 7.4+
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$SkipChocolatey,

    [string[]]$PackageList,

    [switch]$SkipPerformanceTweaks,

    [switch]$SkipNetworkCheck,

    [ValidateNotNullOrEmpty()]
    [string]$LogPath = (Join-Path $env:ProgramData 'WorkstationBootstrap\bootstrap.log')
)

# ----------------------------------------------------------------------------
# Module-scoped configuration
# ----------------------------------------------------------------------------
$script:DefaultPackages = @(
    'git',
    'vscode',
    'python',
    'powershell-core',
    '7zip',
    'sysinternals',
    'notepadplusplus'
)

$script:StartTime = Get-Date

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
function Write-BootstrapLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[{0}] [{1}] {2}" -f $timestamp, $Level, $Message

    $color = switch ($Level) {
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        'SUCCESS' { 'Green' }
        default   { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color

    $logDir = Split-Path -Path $LogPath -Parent
    if (-not (Test-Path -Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
    Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------
# Elevation check
# ----------------------------------------------------------------------------
function Test-Elevation {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ----------------------------------------------------------------------------
# Chocolatey install + package deployment
# ----------------------------------------------------------------------------
function Install-ChocolateyIfMissing {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $chocoCmd = Get-Command -Name choco.exe -ErrorAction SilentlyContinue
    if ($chocoCmd) {
        Write-BootstrapLog -Message "Chocolatey already present at $($chocoCmd.Source). Skipping install." -Level INFO
        return
    }

    if ($PSCmdlet.ShouldProcess('Chocolatey package manager', 'Install')) {
        Write-BootstrapLog -Message 'Chocolatey not found. Installing...' -Level INFO
        try {
            # Match Chocolatey's documented bootstrap: force TLS 1.2 on hosts where
            # the OS default protocol is older (relevant on down-level Server/Win10 images).
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            $installScript = (New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')
            Invoke-Expression $installScript

            # Refresh PATH in this session so choco.exe is immediately callable
            # without spawning a new shell.
            $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                        [System.Environment]::GetEnvironmentVariable('Path', 'User')

            Write-BootstrapLog -Message 'Chocolatey installed successfully.' -Level SUCCESS
        }
        catch {
            Write-BootstrapLog -Message "Chocolatey install failed: $($_.Exception.Message)" -Level ERROR
            throw
        }
    }
}

function Install-ChocoPackages {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [string[]]$Packages
    )

    # Query installed state once, up front, rather than shelling out to choco
    # per-package. Cuts an N-package run from N processes to 1.
    Write-BootstrapLog -Message 'Querying currently installed Chocolatey packages...' -Level INFO
    $installedRaw = choco list --local-only --limit-output 2>$null
    $installedIds = @()
    if ($installedRaw) {
        $installedIds = $installedRaw | ForEach-Object { ($_ -split '\|')[0] }
    }

    foreach ($pkg in $Packages) {
        if ($installedIds -contains $pkg) {
            Write-BootstrapLog -Message "Package '$pkg' already installed. Skipping." -Level INFO
            continue
        }

        if ($PSCmdlet.ShouldProcess($pkg, 'Install Chocolatey package')) {
            Write-BootstrapLog -Message "Installing package: $pkg" -Level INFO
            try {
                $result = choco install $pkg --yes --no-progress 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-BootstrapLog -Message "Package '$pkg' installed successfully." -Level SUCCESS
                }
                else {
                    Write-BootstrapLog -Message "Package '$pkg' returned exit code $LASTEXITCODE. Output: $result" -Level WARN
                }
            }
            catch {
                Write-BootstrapLog -Message "Failed to install '$pkg': $($_.Exception.Message)" -Level ERROR
            }
        }
    }
}

# ----------------------------------------------------------------------------
# Explorer / system performance tweaks
# ----------------------------------------------------------------------------
function Set-RegistryValueIdempotent {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord', 'String', 'ExpandString', 'Binary')]
        [string]$Type = 'DWord'
    )

    if (-not (Test-Path -Path $Path)) {
        if ($PSCmdlet.ShouldProcess($Path, 'Create registry key')) {
            New-Item -Path $Path -Force | Out-Null
        }
    }

    $current = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name

    if ($null -ne $current -and $current -eq $Value) {
        Write-BootstrapLog -Message "Registry value '$Name' at '$Path' already set to '$Value'. Skipping." -Level INFO
        return
    }

    if ($PSCmdlet.ShouldProcess("$Path\$Name = $Value", 'Set registry value')) {
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        Write-BootstrapLog -Message "Set '$Name' at '$Path' to '$Value'." -Level SUCCESS
    }
}

function Set-ExplorerTweaks {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Write-BootstrapLog -Message 'Applying Explorer/performance tweaks...' -Level INFO

    $explorerAdvanced = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

    # Show known file extensions -- default-hidden extensions are a routine
    # source of misidentified scripts/executables in an engineering context.
    Set-RegistryValueIdempotent -Path $explorerAdvanced -Name 'HideFileExt' -Value 0 -Type DWord

    # Show hidden files -- engineers routinely need to see dotfiles/config dirs.
    Set-RegistryValueIdempotent -Path $explorerAdvanced -Name 'Hidden' -Value 1 -Type DWord

    # Launch Explorer to "This PC" instead of Quick Access/Home -- reduces
    # accidental clicks into cloud-synced recent-file lists on shared machines.
    Set-RegistryValueIdempotent -Path $explorerAdvanced -Name 'LaunchTo' -Value 1 -Type DWord

    # Disable animations in the taskbar/Explorer for lower input latency on
    # remote/VDI-style sessions, without touching full visual-effects presets
    # (which would also disable font smoothing and hurt readability).
    Set-RegistryValueIdempotent -Path $explorerAdvanced -Name 'TaskbarAnimations' -Value 0 -Type DWord

    Write-BootstrapLog -Message 'Explorer tweaks complete.' -Level SUCCESS
}

# ----------------------------------------------------------------------------
# Network stack health check
# ----------------------------------------------------------------------------
function Test-NetworkHealth {
    [CmdletBinding()]
    param()

    Write-BootstrapLog -Message 'Running network stack health checks...' -Level INFO
    $results = [ordered]@{}

    # Adapter status
    try {
        $adapters = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }
        $results['ActiveAdapters'] = $adapters.Count
        if ($adapters.Count -eq 0) {
            Write-BootstrapLog -Message 'No active network adapters detected.' -Level ERROR
        }
        else {
            Write-BootstrapLog -Message "$($adapters.Count) active adapter(s): $($adapters.Name -join ', ')" -Level SUCCESS
        }
    }
    catch {
        Write-BootstrapLog -Message "Get-NetAdapter unavailable, falling back to legacy check: $($_.Exception.Message)" -Level WARN
    }

    # Default gateway reachability
    try {
        $gateway = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
                    Sort-Object -Property RouteMetric | Select-Object -First 1).NextHop
        if ($gateway) {
            $gwPing = Test-Connection -ComputerName $gateway -Count 2 -Quiet -ErrorAction SilentlyContinue
            $results['GatewayReachable'] = [bool]$gwPing
            $level = if ($gwPing) { 'SUCCESS' } else { 'ERROR' }
            Write-BootstrapLog -Message "Default gateway ($gateway) reachable: $gwPing" -Level $level
        }
    }
    catch {
        Write-BootstrapLog -Message "Gateway check failed: $($_.Exception.Message)" -Level WARN
    }

    # DNS resolution
    try {
        $dnsResult = Resolve-DnsName -Name 'github.com' -ErrorAction Stop
        $results['DnsResolution'] = $true
        Write-BootstrapLog -Message "DNS resolution succeeded ($($dnsResult[0].IPAddress))." -Level SUCCESS
    }
    catch {
        $results['DnsResolution'] = $false
        Write-BootstrapLog -Message "DNS resolution failed: $($_.Exception.Message)" -Level ERROR
    }

    # Internet reachability (HTTPS, not just ICMP -- many corporate networks
    # block ICMP outbound but allow 443, so an ICMP-only check would false-negative)
    try {
        $https = Invoke-WebRequest -Uri 'https://www.microsoft.com' -Method Head -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        $results['InternetReachable'] = ($https.StatusCode -eq 200)
        Write-BootstrapLog -Message "HTTPS egress check succeeded (status $($https.StatusCode))." -Level SUCCESS
    }
    catch {
        $results['InternetReachable'] = $false
        Write-BootstrapLog -Message "HTTPS egress check failed: $($_.Exception.Message)" -Level WARN
    }

    return [PSCustomObject]$results
}

# ----------------------------------------------------------------------------
# Orchestration
# ----------------------------------------------------------------------------
function Invoke-Bootstrap {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Write-BootstrapLog -Message "=== Bootstrap-Workstation started (PSVersion $($PSVersionTable.PSVersion)) ===" -Level INFO

    if (-not (Test-Elevation)) {
        Write-BootstrapLog -Message 'This script must be run from an elevated (Administrator) PowerShell session.' -Level ERROR
        throw 'Elevation required. Relaunch PowerShell as Administrator.'
    }
    Write-BootstrapLog -Message 'Elevation verified.' -Level SUCCESS

    $ErrorActionPreference = 'Stop'
    $exitCode = 0

    try {
        if (-not $SkipChocolatey) {
            Install-ChocolateyIfMissing
            $packages = if ($PackageList) { $PackageList } else { $script:DefaultPackages }
            Install-ChocoPackages -Packages $packages
        }
        else {
            Write-BootstrapLog -Message 'Chocolatey step skipped via -SkipChocolatey.' -Level INFO
        }

        if (-not $SkipPerformanceTweaks) {
            Set-ExplorerTweaks
        }
        else {
            Write-BootstrapLog -Message 'Performance tweaks skipped via -SkipPerformanceTweaks.' -Level INFO
        }

        if (-not $SkipNetworkCheck) {
            $networkResults = Test-NetworkHealth
            $networkResults | Format-List | Out-String | Write-Verbose
        }
        else {
            Write-BootstrapLog -Message 'Network check skipped via -SkipNetworkCheck.' -Level INFO
        }
    }
    catch {
        Write-BootstrapLog -Message "Bootstrap failed: $($_.Exception.Message)" -Level ERROR
        $exitCode = 1
    }
    finally {
        $duration = (Get-Date) - $script:StartTime
        Write-BootstrapLog -Message "=== Bootstrap-Workstation finished in $([math]::Round($duration.TotalSeconds, 1))s (exit code $exitCode) ===" -Level INFO
    }

    return $exitCode
}

# Entry point -- only auto-run when the file is executed directly, not when
# dot-sourced for unit testing of individual functions.
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-Bootstrap)
}
