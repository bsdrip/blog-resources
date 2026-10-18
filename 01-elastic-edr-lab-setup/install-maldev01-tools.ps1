#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    MALDEV01 lab software installer for the MalDevAcademy course.

.DESCRIPTION
    Installs the tools the MalDevAcademy course asks for on a freshly installed
    Windows 10/11 machine with internet access. Software only - no Defender,
    firewall, network, account, or hostname configuration.

    Installed tools:
      * Visual Studio 2022 Community - "Desktop development with C++" workload
        (MSVC, Windows SDK)                                   [VS bootstrapper]
      * Visual Studio Code                                    [winget]
      * Git for Windows (optional)                            [winget]
      * Python 3                                              [winget]
      * x64dbg                                                [GitHub release -> C:\Tools\x64dbg]
      * WinDbg (optional)                                     [winget]
      * PE-bear                                               [GitHub release -> C:\Tools\PE-bear]
      * Ghidra + Microsoft OpenJDK 21 (Ghidra's runtime)      [GitHub release -> C:\Tools\Ghidra, winget]
      * System Informer                                       [winget]
      * Sysinternals Suite                                    [sysinternals.com -> C:\Tools\Sysinternals]
      * Wireshark + Npcap (optional; Wireshark's capture driver)  [winget, npcap.com]

    IDA Free is not installed: Hex-Rays requires a free account login to
    download it, so it cannot be scripted. Install it by hand if you prefer it
    over Ghidra.

    Portable tools go to C:\Tools and get a Start menu shortcut. Each step runs
    on its own; a failed step prints a warning and the script continues.

.PARAMETER LogPath
    Full path to the PowerShell transcript log file. Defaults to
    "$env:WINDIR\Temp\install-maldev01-tools.log".

.PARAMETER ToolsDir
    Install root for the portable tools. Default: "C:\Tools".

.PARAMETER SkipGit
    Do not install Git for Windows (optional in the course).

.PARAMETER SkipWinDbg
    Do not install WinDbg (optional in the course).

.PARAMETER SkipGhidra
    Do not install Ghidra and OpenJDK 21 (optional in the course).

.PARAMETER SkipWireshark
    Do not install Wireshark and Npcap (optional in the course).

.PARAMETER PythonWingetId
    winget package ID for Python. Default: "Python.Python.3.14".

.EXAMPLE
    Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
    .\install-maldev01-tools.ps1

.EXAMPLE
    .\install-maldev01-tools.ps1 -SkipWireshark -SkipWinDbg

.NOTES
    REQUIREMENTS
      * Run elevated (Administrator) from an interactive desktop session.
      * winget (App Installer), present on current Windows 10/11 builds.
      * Outbound HTTPS to github.com, aka.ms, download.visualstudio.microsoft.com,
        download.sysinternals.com, npcap.com and the winget CDN.
      * ~40 GB free disk space (Visual Studio is the largest part).
#>

[CmdletBinding()]
param(
    [string]$LogPath  = "$env:WINDIR\Temp\install-maldev01-tools.log",
    [string]$ToolsDir = "C:\Tools",

    [switch]$SkipGit,
    [switch]$SkipWinDbg,
    [switch]$SkipGhidra,
    [switch]$SkipWireshark,

    [string]$PythonWingetId = "Python.Python.3.14",

    [string]$VisualStudioBootstrapperUrl = "https://aka.ms/vs/17/release/vs_community.exe",
    [string]$SysinternalsSuiteUrl        = "https://download.sysinternals.com/files/SysinternalsSuite.zip",
    [string]$NpcapDownloadPage           = "https://npcap.com/"
)

# Halt on first un-caught error. Individual install steps wrap themselves in
# try/catch and downgrade to Write-Warning so the script continues.
$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"   # Invoke-WebRequest is very slow with the progress bar on PS 5.1

# Collect every timed task's elapsed duration here for the final summary table.
$script:BootstrapTimings = [System.Collections.Generic.List[object]]::new()
$script:FailedSteps      = [System.Collections.Generic.List[string]]::new()


###############################################################################
#                            HELPER / UTILITY FUNCS                            #
###############################################################################

function Format-BootstrapElapsed {
    # Render a TimeSpan as hh:mm:ss.fff for stable column-aligned logs.
    param([TimeSpan]$Elapsed)
    return $Elapsed.ToString('hh\:mm\:ss\.fff')
}

function Write-BootstrapTimingSummary {
    # Dump the collected per-step timings as a final readable table.
    if ($script:BootstrapTimings.Count -eq 0) { return }
    Write-Output "========== Timing summary =========="
    foreach ($entry in $script:BootstrapTimings) {
        Write-Output ("  {0,-45} {1}" -f $entry.Task, $entry.ElapsedFormatted)
    }
}

function Invoke-LabStep {
<#
.SYNOPSIS  Run one install step, time it, and isolate its failure.
#>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Output ""
    Write-Output "==> $Name"
    try {
        & $Action
    }
    catch {
        $script:FailedSteps.Add($Name) | Out-Null
        Write-Warning "$Name failed (other steps continue): $_"
    }
    finally {
        $sw.Stop()
        $script:BootstrapTimings.Add([PSCustomObject]@{
            Task             = $Name
            ElapsedFormatted = Format-BootstrapElapsed -Elapsed $sw.Elapsed
        }) | Out-Null
    }
}

function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}

function Add-DirToMachinePath {
    param([Parameter(Mandatory)][string]$Dir)
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $parts = @($machinePath.Split(';') | Where-Object { $_ })
    if ($parts -notcontains $Dir) {
        [Environment]::SetEnvironmentVariable("Path", (($parts + $Dir) -join ';'), "Machine")
    }
    Update-SessionPath
}

function Save-HttpFile {
<#
.SYNOPSIS  Download a file over TLS 1.2 and reject truncated/HTML-error downloads.
#>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [long]$MinBytes = 0
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $destParent = Split-Path $Destination -Parent
    if ($destParent -and -not (Test-Path $destParent)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    }
    if (Test-Path $Destination) { Remove-Item $Destination -Force }

    Write-Output "Downloading $Uri"
    Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing -Headers @{ "User-Agent" = "maldev-lab-installer" }

    if (-not (Test-Path $Destination)) { throw "Download failed; file not found at $Destination" }
    $fileSize = (Get-Item -LiteralPath $Destination).Length
    if ($MinBytes -gt 0 -and $fileSize -lt $MinBytes) {
        throw "Download too small ($fileSize bytes, expected at least $MinBytes): $Uri"
    }
    Write-Output "Downloaded $fileSize bytes to $Destination"
}

function Get-GitHubReleaseAssetUrl {
<#
.SYNOPSIS  Return the download URL of the first asset in a repo's latest release matching a pattern.
#>
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$AssetPattern
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing -Headers @{ "User-Agent" = "maldev-lab-installer" }
    $asset = $release.assets | Where-Object { $_.name -match $AssetPattern } | Select-Object -First 1
    if (-not $asset) { throw "No asset matching '$AssetPattern' in latest release of $Repo ($($release.tag_name))" }
    Write-Output "Latest $Repo release: $($release.tag_name) -> $($asset.name)" | Out-Host
    return $asset.browser_download_url
}

function Expand-ZipToToolDir {
<#
.SYNOPSIS  Extract a zip into a clean tool directory, flattening a single top-level folder.
#>
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$DestDir
    )
    $staging = Join-Path $env:TEMP ("lab-extract-" + [guid]::NewGuid().ToString("N"))
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $staging -Force
    $items = @(Get-ChildItem -LiteralPath $staging)
    $sourceDir = if ($items.Count -eq 1 -and $items[0].PSIsContainer) { $items[0].FullName } else { $staging }

    if (Test-Path $DestDir) { Remove-Item $DestDir -Recurse -Force }
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    Copy-Item -Path (Join-Path $sourceDir '*') -Destination $DestDir -Recurse -Force
    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
}

function New-StartMenuShortcut {
    # All-users Start menu shortcut so portable tools are findable like installed ones.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$TargetPath
    )
    $programsDir = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Lab Tools"
    New-Item -ItemType Directory -Path $programsDir -Force | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path $programsDir "$Name.lnk"))
    $shortcut.TargetPath       = $TargetPath
    $shortcut.WorkingDirectory = Split-Path $TargetPath -Parent
    $shortcut.Save()
    Write-Output "Start menu shortcut: Lab Tools\$Name"
}


###############################################################################
#                                    WINGET                                    #
###############################################################################

function Get-WingetPath {
<#
.SYNOPSIS  Locate winget.exe, registering App Installer first if it is not yet available.
.DESCRIPTION
    On a fresh install, winget can be missing until App Installer has been
    registered for the user. Registering it by family name is Microsoft's
    documented fix.
#>
    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetCmd) {
        Write-Output "winget not found; registering App Installer..." | Out-Host
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction SilentlyContinue
        Update-SessionPath
        $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    }
    if (-not $wingetCmd) {
        throw "winget not available. Update 'App Installer' from the Microsoft Store, then rerun this script."
    }
    return $wingetCmd.Source
}

function Install-WingetPackage {
<#
.SYNOPSIS  Silent winget install of one package; "already installed" counts as success.
#>
    param(
        [Parameter(Mandatory)][string]$Id,
        [ValidateSet("machine", "user", "")][string]$Scope = "machine",
        [string]$Override
    )
    $winget = Get-WingetPath
    $wingetArgs = @(
        "install", "--id", $Id, "--exact", "--source", "winget",
        "--silent", "--disable-interactivity",
        "--accept-package-agreements", "--accept-source-agreements"
    )
    if ($Scope)    { $wingetArgs += @("--scope", $Scope) }
    if ($Override) { $wingetArgs += @("--override", $Override) }

    Write-Output "Running: winget $($wingetArgs -join ' ')"
    & $winget @wingetArgs
    $exitCode = $LASTEXITCODE
    Update-SessionPath

    # 0x8A15002B = no applicable upgrade, 0x8A150061 = already installed,
    # 0x8A150109 = installed, reboot required to finish.
    switch ($exitCode) {
        0           { Write-Output "CONFIRMED: $Id installed." }
        -1978335189 { Write-Output "CONFIRMED: $Id already installed and up to date." }
        -1978335135 { Write-Output "CONFIRMED: $Id already installed." }
        -1978334967 { Write-Output "CONFIRMED: $Id installed (reboot required to finish)." }
        default     { throw "winget install $Id failed with exit code $exitCode" }
    }
}


###############################################################################
#                          TOP-LEVEL INSTALL FUNCTIONS                          #
###############################################################################

function Install-VisualStudioCommunity {
<#
.SYNOPSIS  Visual Studio 2022 Community with the "Desktop development with C++" workload.
.DESCRIPTION
    The NativeDesktop workload with recommended components includes MSVC and
    the Windows SDK, so the SDK needs no separate install. The longest single
    step (~20-40 min).
#>
    $installer = Join-Path $env:TEMP "vs_community.exe"
    Save-HttpFile -Uri $VisualStudioBootstrapperUrl -Destination $installer -MinBytes 1MB

    $vsArgs = @(
        "--add", "Microsoft.VisualStudio.Workload.NativeDesktop",
        "--includeRecommended",
        "--passive", "--norestart", "--wait"
    )
    Write-Output "Running: vs_community.exe $($vsArgs -join ' ')"
    $proc = Start-Process -FilePath $installer -ArgumentList $vsArgs -Wait -PassThru
    # 3010 = success, reboot required.
    if ($proc.ExitCode -notin @(0, 3010)) { throw "Visual Studio installer exited with code $($proc.ExitCode)" }
    if ($proc.ExitCode -eq 3010) { Write-Output "Visual Studio installed; a reboot is required to finish." }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if (-not $vsPath) { throw "MSVC tools not found by vswhere after Visual Studio install." }
    Write-Output "CONFIRMED: Visual Studio with MSVC at $vsPath"

    $sdkRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Include"
    $sdkVersion = Get-ChildItem -Path $sdkRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $sdkVersion) { throw "Windows SDK headers not found under $sdkRoot." }
    Write-Output "CONFIRMED: Windows SDK $($sdkVersion.Name)"
}

function Install-Python {
    # Override so Python lands machine-wide and on PATH for every user.
    Install-WingetPackage -Id $PythonWingetId -Override "/quiet InstallAllUsers=1 PrependPath=1 Include_pip=1 Include_launcher=1"
    # Skip the WindowsApps "python" alias that only opens the Microsoft Store.
    $pythonCmd = Get-Command python -All -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notlike "*\WindowsApps\*" } | Select-Object -First 1
    if (-not $pythonCmd) { throw "python not on PATH after install." }
    & $pythonCmd.Source --version
}

function Install-X64dbg {
    $url = Get-GitHubReleaseAssetUrl -Repo "x64dbg/x64dbg" -AssetPattern '^snapshot_.*\.zip$'
    $zip = Join-Path $env:TEMP "x64dbg.zip"
    Save-HttpFile -Uri $url -Destination $zip -MinBytes 10MB

    $destDir = Join-Path $ToolsDir "x64dbg"
    Expand-ZipToToolDir -ZipPath $zip -DestDir $destDir
    # The snapshot zip puts the binaries under release\.
    $releaseDir = Join-Path $destDir "release"
    if (Test-Path $releaseDir) {
        Get-ChildItem -LiteralPath $releaseDir | Move-Item -Destination $destDir -Force
        Remove-Item $releaseDir -Recurse -Force
    }

    $x64Exe = Join-Path $destDir "x64\x64dbg.exe"
    $x32Exe = Join-Path $destDir "x32\x32dbg.exe"
    if (-not (Test-Path $x64Exe)) { throw "x64dbg.exe not found at $x64Exe" }
    New-StartMenuShortcut -Name "x64dbg" -TargetPath $x64Exe
    if (Test-Path $x32Exe) { New-StartMenuShortcut -Name "x32dbg" -TargetPath $x32Exe }
    Write-Output "CONFIRMED: x64dbg at $x64Exe"
}

function Install-PeBear {
    $url = Get-GitHubReleaseAssetUrl -Repo "hasherezade/pe-bear" -AssetPattern '_x64_win_.*\.zip$'
    $zip = Join-Path $env:TEMP "pe-bear.zip"
    Save-HttpFile -Uri $url -Destination $zip -MinBytes 1MB

    $destDir = Join-Path $ToolsDir "PE-bear"
    Expand-ZipToToolDir -ZipPath $zip -DestDir $destDir
    $exe = Join-Path $destDir "PE-bear.exe"
    if (-not (Test-Path $exe)) { throw "PE-bear.exe not found at $exe" }
    New-StartMenuShortcut -Name "PE-bear" -TargetPath $exe
    Write-Output "CONFIRMED: PE-bear at $exe"
}

function Install-Ghidra {
<#
.SYNOPSIS  Ghidra (latest GitHub release) plus the JDK 21 it needs to run.
#>
    Install-WingetPackage -Id "Microsoft.OpenJDK.21"

    $url = Get-GitHubReleaseAssetUrl -Repo "NationalSecurityAgency/ghidra" -AssetPattern '^ghidra_.*_PUBLIC_.*\.zip$'
    $zip = Join-Path $env:TEMP "ghidra.zip"
    Save-HttpFile -Uri $url -Destination $zip -MinBytes 100MB

    $destDir = Join-Path $ToolsDir "Ghidra"
    Expand-ZipToToolDir -ZipPath $zip -DestDir $destDir
    $launcher = Join-Path $destDir "ghidraRun.bat"
    if (-not (Test-Path $launcher)) { throw "ghidraRun.bat not found at $launcher" }
    New-StartMenuShortcut -Name "Ghidra" -TargetPath $launcher
    Write-Output "CONFIRMED: Ghidra at $destDir"
}

function Install-SysinternalsSuite {
    $zip = Join-Path $env:TEMP "SysinternalsSuite.zip"
    Save-HttpFile -Uri $SysinternalsSuiteUrl -Destination $zip -MinBytes 10MB

    $destDir = Join-Path $ToolsDir "Sysinternals"
    Expand-ZipToToolDir -ZipPath $zip -DestDir $destDir
    Add-DirToMachinePath -Dir $destDir

    # Pre-accept the EULA so the tools do not prompt on first launch.
    foreach ($regPath in @("HKCU:\Software\Sysinternals", "HKLM:\Software\Sysinternals")) {
        if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        Set-ItemProperty -Path $regPath -Name "EulaAccepted" -Value 1 -Type DWord -Force
    }

    foreach ($tool in @(
        @{ Name = "Process Monitor";  Exe = "Procmon64.exe" },
        @{ Name = "Process Explorer"; Exe = "procexp64.exe" }
    )) {
        $exe = Join-Path $destDir $tool.Exe
        if (Test-Path $exe) { New-StartMenuShortcut -Name $tool.Name -TargetPath $exe }
    }
    $exeCount = @(Get-ChildItem -Path $destDir -Filter "*.exe" -File).Count
    Write-Output "CONFIRMED: Sysinternals Suite at $destDir ($exeCount tools, on machine PATH)."
}

function Install-Npcap {
<#
.SYNOPSIS  Npcap, Wireshark's packet capture driver.
.DESCRIPTION
    The free Npcap edition has no silent install, so its installer opens for
    you to click through. Keep the default options.
#>
    if (Test-Path (Join-Path $env:SystemRoot "System32\Npcap\wpcap.dll")) {
        Write-Output "CONFIRMED: Npcap already installed."
        return
    }
    $page = Invoke-WebRequest -Uri $NpcapDownloadPage -UseBasicParsing -Headers @{ "User-Agent" = "maldev-lab-installer" }
    $match = [regex]::Match($page.Content, 'dist/npcap-[0-9.]+\.exe')
    if (-not $match.Success) { throw "Npcap installer link not found on $NpcapDownloadPage; install it from there by hand." }
    $installer = Join-Path $env:TEMP "npcap-installer.exe"
    Save-HttpFile -Uri ($NpcapDownloadPage.TrimEnd('/') + "/" + $match.Value) -Destination $installer -MinBytes 500KB

    Write-Output "ACTION REQUIRED: the Npcap installer is opening - click through it with the default options."
    $proc = Start-Process -FilePath $installer -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "Npcap installer exited with code $($proc.ExitCode)" }
    Write-Output "CONFIRMED: Npcap installed."
}


###############################################################################
#                                MAIN EXECUTION                                 #
###############################################################################

Start-Transcript -Path $LogPath -Append | Out-Null

try {
    Write-Output "MALDEV01 lab software installer"
    Write-Output "Log file: $LogPath"
    $totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null

    Invoke-LabStep -Name "Visual Studio 2022 Community (C++ + SDK)" { Install-VisualStudioCommunity }
    Invoke-LabStep -Name "Visual Studio Code"  { Install-WingetPackage -Id "Microsoft.VisualStudioCode" }
    if (-not $SkipGit) {
        Invoke-LabStep -Name "Git for Windows" { Install-WingetPackage -Id "Git.Git" }
    }
    Invoke-LabStep -Name "Python"              { Install-Python }
    Invoke-LabStep -Name "x64dbg"              { Install-X64dbg }
    if (-not $SkipWinDbg) {
        # MSIX package: installs for the current user, so no --scope.
        Invoke-LabStep -Name "WinDbg" { Install-WingetPackage -Id "Microsoft.WinDbg" -Scope "" }
    }
    Invoke-LabStep -Name "PE-bear"             { Install-PeBear }
    if (-not $SkipGhidra) {
        Invoke-LabStep -Name "Ghidra (+ OpenJDK 21)" { Install-Ghidra }
    }
    Invoke-LabStep -Name "System Informer"     { Install-WingetPackage -Id "WinsiderSS.SystemInformer" }
    Invoke-LabStep -Name "Sysinternals Suite"  { Install-SysinternalsSuite }
    if (-not $SkipWireshark) {
        Invoke-LabStep -Name "Wireshark" { Install-WingetPackage -Id "WiresharkFoundation.Wireshark" }
        Invoke-LabStep -Name "Npcap"     { Install-Npcap }
    }

    Write-BootstrapTimingSummary
    $totalStopwatch.Stop()
    Write-Output ("Total elapsed: {0}" -f (Format-BootstrapElapsed $totalStopwatch.Elapsed))
    Write-Output ""
    Write-Output "=============================================================================="
    if ($script:FailedSteps.Count -gt 0) {
        Write-Warning "Steps that FAILED: $($script:FailedSteps -join ', '). Rerun the script to retry them."
    }
    else {
        Write-Output " install-maldev01-tools.ps1 complete. Reboot before you start working."
    }
    Write-Output " Full transcript: $LogPath"
    Write-Output "=============================================================================="
}
catch {
    Write-Error $_
    throw
}
finally {
    Stop-Transcript | Out-Null
}
