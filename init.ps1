#Requires -Version 5.1
<#
.SYNOPSIS
Start Jinda setup: choose options first, optionally install software, then configure Windows.
.DESCRIPTION
Requests administrator privileges when needed and collects all choices up front.
Uses the two scripts from the same GitHub ZIP package and selects PowerShell again
after the optional software installation.
.PARAMETER Keyboard
USInternational (default) or US.
.PARAMETER RepairWinGet
Repairs WinGet using Microsoft.WinGet.Client and checks its source before installing
software. Only runs when this switch is specified and app installation is enabled.
.PARAMETER InstallApps
Ask (default), Yes or No. Asks at startup whether to download and install apps.
.PARAMETER RemoteDesktop
Ask (default), Yes or No. Enables Remote Desktop for the selected LAN and WireGuard client.
.PARAMETER PowerShellRemoting
Ask (default), Yes or No. Enables Windows PowerShell remoting (WinRM).
.PARAMETER OpenSSH
Ask (default), Yes or No. Installs the OpenSSH client/server and enables SSH on private/domain local subnets.
The question defaults to No and is independent of the apps choice.
.PARAMETER LanIPAddress
Optional active IPv4 address of the target PC. Otherwise, the LAN is selected at startup.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('US', 'USInternational')]
    [string]$Keyboard = 'USInternational',
    [switch]$RepairWinGet,
    [ValidateSet('Ask', 'Yes', 'No')][string]$InstallApps = 'Ask',
    [ValidateSet('Ask', 'Yes', 'No')][string]$RemoteDesktop = 'Ask',
    [ValidateSet('Ask', 'Yes', 'No')][string]$PowerShellRemoting = 'Ask',
    [ValidateSet('Ask', 'Yes', 'No')][string]$OpenSSH = 'Ask',
    [string]$LanIPAddress,
    [Parameter(DontShow = $true)][switch]$RuntimeReady
)

# BEGIN shared runtime (kept identical in all entry scripts).
function Test-JindaAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-JindaWindowsPowerShell {
    $systemDirectory = if ([Environment]::Is64BitProcess) { 'System32' } else { 'Sysnative' }
    return Join-Path $env:WINDIR "$systemDirectory\WindowsPowerShell\v1.0\powershell.exe"
}

function Get-JindaPowerShellCandidates {
    $paths = @()
    $paths += Join-Path $PSHOME 'pwsh.exe'
    foreach ($root in @($env:ProgramW6432, $env:ProgramFiles) | Select-Object -Unique) {
        if ($root) {
            $folder = Join-Path $root 'PowerShell'
            foreach ($directory in (Get-ChildItem -LiteralPath $folder -Directory -ErrorAction SilentlyContinue)) {
                $paths += Join-Path $directory.FullName 'pwsh.exe'
            }
        }
    }
    $paths += @(Get-Command pwsh.exe -CommandType Application -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        $paths += @(Get-AppxPackage -Name Microsoft.PowerShell -ErrorAction SilentlyContinue |
            Where-Object InstallLocation | ForEach-Object { Join-Path $_.InstallLocation 'pwsh.exe' })
    }
    $architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $nativeMachine = if ($architecture -eq 'ARM64') { 0xAA64 } else { 0x8664 }
    foreach ($path in ($paths | Select-Object -Unique)) {
        $reader = $null
        try {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
            $versionText = $info.ProductVersion
            if ($versionText -match '(?i)preview|alpha|beta|rc' -or
                $versionText -notmatch '^(\d+\.\d+\.\d+(?:\.\d+)?)') { continue }
            $version = [version]$matches[1]
            if ($version.Major -lt 7) { continue }
            # Read PE architecture: do not select an x86 runtime.
            $reader = New-Object IO.BinaryReader([IO.File]::OpenRead($path))
            $null = $reader.BaseStream.Seek(0x3C, [IO.SeekOrigin]::Begin)
            $peOffset = $reader.ReadInt32()
            $null = $reader.BaseStream.Seek($peOffset, [IO.SeekOrigin]::Begin)
            if ($reader.ReadUInt32() -ne 0x00004550 -or $reader.ReadUInt16() -ne $nativeMachine) { continue }
            [pscustomobject]@{ Path = $path; Version = $version }
        }
        catch { Write-Verbose "Skipped PowerShell candidate: $path ($($_.Exception.Message))" }
        finally { if ($reader) { $reader.Dispose() } }
    }
}

function Get-JindaPowerShell {
    param([switch]$WindowsPowerShell)
    if (-not $WindowsPowerShell) {
        $latest = Get-JindaPowerShellCandidates | Sort-Object Version -Descending | Select-Object -First 1
        if ($latest) { return $latest.Path }
    }
    return Get-JindaWindowsPowerShell
}

function Get-JindaCurrentPowerShell {
    return (Get-Process -Id $PID).Path
}

function Invoke-JindaChildProcess {
    param(
        [string]$Executable,
        [string]$ScriptPath,
        [string[]]$ScriptArguments = @(),
        [switch]$Elevate,
        [switch]$NonInteractive
    )
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
    if ($NonInteractive) { $arguments += '-NonInteractive' }
    $arguments += @('-File', $ScriptPath) + $ScriptArguments
    if ($Elevate) {
        # Start-Process joins its arguments, so explicitly quote paths and values.
        if (@($arguments | Where-Object { $_ -match '["\r\n]' }).Count) {
            throw 'A script path or argument contains invalid characters.'
        }
        $argumentLine = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
        try {
            $process = Start-Process -FilePath $Executable -ArgumentList $argumentLine -Verb RunAs -Wait -PassThru -ErrorAction Stop
            return [int]$process.ExitCode
        }
        catch {
            throw "Could not start as administrator. Accept the Windows UAC prompt. $($_.Exception.Message)"
        }
    }
    $PSNativeCommandUseErrorActionPreference = $false
    & $Executable @arguments | Out-Host
    return $LASTEXITCODE
}

function Invoke-JindaManagedScript {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$ScriptPath,
        [string[]]$ScriptArguments = @(),
        [switch]$RuntimeReady,
        [switch]$WindowsPowerShell,
        [scriptblock]$Work
    )
    $ErrorActionPreference = 'Stop'
    # WhatIf causes no elevation, download, log creation or settings changes.
    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Run $(Split-Path -Leaf $ScriptPath) as administrator")) { return 0 }
    $executable = Get-JindaPowerShell -WindowsPowerShell:$WindowsPowerShell
    $administrator = Test-JindaAdministrator
    if (-not $administrator -or (Get-JindaCurrentPowerShell) -ne $executable) {
        if ($RuntimeReady) { throw 'The relaunched process does not have the required administrator privileges or PowerShell version.' }
        Write-Host "Starting with administrator privileges using $executable"
        return Invoke-JindaChildProcess -Executable $executable -ScriptPath $ScriptPath -ScriptArguments ($ScriptArguments + @('-RuntimeReady')) -Elevate:(-not $administrator)
    }
    $transcriptStarted = $false
    $logPath = $null
    try {
        $logFolder = Join-Path $env:LOCALAPPDATA 'JindaOperations\Logs'
        $null = New-Item -ItemType Directory -Path $logFolder -Force
        $logName = '{0}-{1}-{2}.log' -f [IO.Path]::GetFileNameWithoutExtension($ScriptPath), (Get-Date -Format 'yyyyMMdd-HHmmss'), $PID
        $logPath = Join-Path $logFolder $logName
        $null = Start-Transcript -LiteralPath $logPath -Force
        $transcriptStarted = $true
        Write-Host "Log file: $logPath"
        Write-Host "PowerShell $($PSVersionTable.PSVersion); administrator privileges active."
        return (& $Work)
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        if ($logPath) { Write-Host "Details: $logPath" }
        return 1
    }
    finally {
        if ($transcriptStarted) { $null = Stop-Transcript -ErrorAction SilentlyContinue }
    }
}
# END shared runtime.

function Repair-JindaWinGet {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $ErrorActionPreference = 'Stop'
    if (-not $PSCmdlet.ShouldProcess('This PC', 'Repair WinGet and update it to the latest stable version')) { return }

    Write-Host 'Repairing WinGet using the official Microsoft module...'
    # Windows PowerShell 5.1 may still need the NuGet provider to use PSGallery.
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
            Where-Object { [version]$_.Version -ge [version]'2.8.5.201' }
        if (-not $nuget) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -ErrorAction Stop | Out-Host
        }
    }
    Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Scope CurrentUser -Force -ErrorAction Stop | Out-Host
    Import-Module -Name Microsoft.WinGet.Client -Force -ErrorAction Stop
    Repair-WinGetPackageManager -Force -Latest -Verbose -ErrorAction Stop | Out-Host

    # Probe a required app: Chrome installation errors are allowed to continue.
    Write-Host 'Checking the WinGet source using TeamViewer...'
    $winget = (Get-Command winget.exe -CommandType Application -ErrorAction Stop).Source
    $PSNativeCommandUseErrorActionPreference = $false
    & $winget show --id TeamViewer.TeamViewer --exact --source winget --accept-source-agreements --disable-interactivity | Out-Host
    $sourceCode = $LASTEXITCODE
    if ($sourceCode -ne 0) {
        throw "The WinGet source is still unavailable after repair (exit code $sourceCode). Installation and configuration have not started."
    }
    Write-Host 'WinGet repair and source check completed successfully.'
}

function Read-JindaYesNo {
    param(
        [string]$Prompt,
        [ValidateSet('Ask', 'Yes', 'No')][string]$Choice = 'Ask',
        [bool]$Default = $false
    )
    if ($Choice -ne 'Ask') { return ($Choice -eq 'Yes') }
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = ([string](Read-Host "$Prompt $hint")).Trim().ToLowerInvariant()
        if ($answer -eq '') { return $Default }
        if ($answer -in @('y', 'yes', 'j', 'ja')) { return $true }
        if ($answer -in @('n', 'no', 'nee')) { return $false }
        Write-Host 'Please enter y or n.'
    }
}

function Select-JindaLanAddress {
    param([string]$Address)
    $candidates = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object {
            $_.AddressState -eq 'Preferred' -and $_.PrefixLength -ge 1 -and $_.PrefixLength -le 30 -and
            $_.IPAddress -notmatch '^(127\.|169\.254\.|0\.)'
        } | Sort-Object InterfaceIndex, IPAddress)
    if ($Address) {
        $parsed = [Net.IPAddress]::Parse($Address)
        if ($parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'Please select an IPv4 LAN address.' }
        $selected = @($candidates | Where-Object IPAddress -eq $parsed.IPAddressToString)
        if ($selected.Count -ne 1) { throw "LAN address $Address must match exactly one active interface on this PC." }
    }
    elseif ($candidates.Count -eq 0) { throw 'No active IPv4 LAN found. Nothing has been installed or configured.' }
    elseif ($candidates.Count -eq 1) { $selected = @($candidates[0]) }
    else {
        Write-Host 'Select the LAN where Remote Desktop/WinRM should be accessible:'
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            Write-Host ('{0}: {1} - {2}/{3}' -f ($i + 1), $candidates[$i].InterfaceAlias, $candidates[$i].IPAddress, $candidates[$i].PrefixLength)
        }
        while ($true) {
            $number = 0
            $answer = Read-Host 'LAN number'
            if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $candidates.Count) {
                $selected = @($candidates[$number - 1])
                break
            }
            Write-Host 'Please select a number from the list.'
        }
    }
    Write-Host ('LAN for remote access: {0} - {1}/{2}.' -f $selected[0].InterfaceAlias, $selected[0].IPAddress, $selected[0].PrefixLength)
    return [string]$selected[0].IPAddress
}

function Get-JindaSetupOptions {
    param(
        [string]$InstallApps = 'Ask', [string]$RemoteDesktop = 'Ask',
        [string]$PowerShellRemoting = 'Ask', [string]$OpenSSH = 'Ask', [string]$LanIPAddress
    )
    Write-Host 'Choose the setup options now. Setup will then continue without further questions.'
    $apps = Read-JindaYesNo -Prompt 'Download and install apps?' -Choice $InstallApps -Default $true
    $rdp = Read-JindaYesNo -Prompt 'Enable Remote Desktop (RDP) on the LAN? (N = skip; leave existing settings unchanged)' -Choice $RemoteDesktop
    $winrm = Read-JindaYesNo -Prompt 'Enable PowerShell remoting (WinRM) on the LAN? (N = skip; leave existing settings unchanged)' -Choice $PowerShellRemoting
    $ssh = Read-JindaYesNo -Prompt 'Install OpenSSH client/server and enable SSH on private/domain local subnets? (N = skip; leave existing settings unchanged)' -Choice $OpenSSH
    $address = ''
    if ($rdp -or $winrm) { $address = Select-JindaLanAddress -Address $LanIPAddress }
    [pscustomobject]@{ InstallApps = $apps; RemoteDesktop = $rdp; PowerShellRemoting = $winrm; OpenSSH = $ssh; LanIPAddress = $address }
}

function Invoke-JindaInitialization {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [ValidateSet('US', 'USInternational')]
        [string]$Keyboard = 'USInternational',
        [switch]$RepairWinGet,
        [ValidateSet('Ask', 'Yes', 'No')][string]$InstallApps = 'Ask',
        [ValidateSet('Ask', 'Yes', 'No')][string]$RemoteDesktop = 'Ask',
        [ValidateSet('Ask', 'Yes', 'No')][string]$PowerShellRemoting = 'Ask',
        [ValidateSet('Ask', 'Yes', 'No')][string]$OpenSSH = 'Ask',
        [string]$LanIPAddress
    )

    $ErrorActionPreference = 'Stop'
    if (-not $PSCmdlet.ShouldProcess('This PC', 'Install Jinda software and configure Windows')) { return 0 }

    # The start command downloads one complete source archive. Children never prompt.
    $options = Get-JindaSetupOptions -InstallApps $InstallApps -RemoteDesktop $RemoteDesktop -PowerShellRemoting $PowerShellRemoting -OpenSSH $OpenSSH -LanIPAddress $LanIPAddress
    $folder = $PSScriptRoot
    $install = Join-Path $folder 'install-software.ps1'
    $config = Join-Path $folder 'set-windows-english.ps1'
    $requiredScripts = @($config)
    if ($options.InstallApps -or $options.OpenSSH) { $requiredScripts = @($install, $config, (Join-Path $folder 'skip-apps.conf')) }
    foreach ($path in $requiredScripts) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Incomplete script package: $path is missing. Use the new startup command from the GitHub README."
        }
    }
    Write-Host "Using scripts from GitHub package: $folder"

    $installCode = 0
    if ($options.InstallApps -or $options.OpenSSH) {
        if ($RepairWinGet -and $options.InstallApps) { Repair-JindaWinGet }
        $installArguments = @()
        if ($options.OpenSSH) { $installArguments += '-EnableOpenSSH' }
        if (-not $options.InstallApps) { $installArguments += '-SkipApps' }
        Write-Host 'Step 1/2: installing the selected software components.'
        $installCode = Invoke-JindaChildProcess -Executable (Get-JindaPowerShell) -ScriptPath $install -ScriptArguments $installArguments -NonInteractive
        if ($installCode -notin @(0, 3010)) { throw "Software installation failed (exit code $installCode). Configuration has not started." }
    }
    else { Write-Host 'Software installation and any WinGet repair have been skipped as requested.' }

    # PowerShell may have just been installed or upgraded; select it again.
    Write-Host 'Step 2/2: configuring Windows.'
    $configArguments = @('-Keyboard', $Keyboard)
    if ($options.RemoteDesktop) { $configArguments += '-EnableRemoteDesktop' }
    if ($options.PowerShellRemoting) { $configArguments += '-EnableWinRM' }
    if ($options.LanIPAddress) { $configArguments += @('-LanIPAddress', $options.LanIPAddress) }
    $configCode = Invoke-JindaChildProcess -Executable (Get-JindaPowerShell) -ScriptPath $config -ScriptArguments $configArguments -NonInteractive
    if ($configCode -ne 0) { throw "Windows configuration failed (exit code $configCode)." }

    if ($installCode -eq 3010) {
        Write-Host 'Jinda setup completed. Restart Windows to apply the changes.'
    } else {
        Write-Host 'Jinda setup completed.'
    }
    return $installCode
}

# Dot-sourcing defines functions only, for tests.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $scriptArguments = @('-Keyboard', $Keyboard, '-InstallApps', $InstallApps, '-RemoteDesktop', $RemoteDesktop, '-PowerShellRemoting', $PowerShellRemoting, '-OpenSSH', $OpenSSH)
        if ($RepairWinGet) { $scriptArguments += '-RepairWinGet' }
        if ($LanIPAddress) { $scriptArguments += @('-LanIPAddress', $LanIPAddress) }
        $exitCode = Invoke-JindaManagedScript -ScriptPath $PSCommandPath -ScriptArguments $scriptArguments -RuntimeReady:$RuntimeReady -WhatIf:$WhatIfPreference -Work {
            Invoke-JindaInitialization -Keyboard $Keyboard -RepairWinGet:$RepairWinGet -InstallApps $InstallApps -RemoteDesktop $RemoteDesktop -PowerShellRemoting $PowerShellRemoting -OpenSSH $OpenSSH -LanIPAddress $LanIPAddress
        }
        exit $exitCode
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
