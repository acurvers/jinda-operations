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
Legacy choice for both app groups. Yes or No fills in any group whose choice is still Ask.
.PARAMETER InstallEssentialApps
Ask (default), Yes or No. The question defaults to Yes.
.PARAMETER InstallOptionalApps
Ask (default), Yes or No. The question defaults to No.
.PARAMETER RemoteDesktop
Ask (default), Yes or No. Enables Remote Desktop for the selected LAN and WireGuard client.
.PARAMETER PowerShellRemoting
Ask (default), Yes or No. Enables Windows PowerShell remoting (WinRM).
.PARAMETER OpenSSH
Ask (default), Yes or No. Installs the OpenSSH client/server and enables SSH on the selected IPv4 LAN.
The question defaults to No and is independent of the apps choice.
.PARAMETER RemoveBundledApps
Ask (default), Yes or No. Removes LinkedIn and Microsoft Solitaire Collection. Defaults to No.
.PARAMETER RemoveDiscord
Ask (default), Yes or No. Offers to remove Discord if installed. The question defaults to No.
.PARAMETER WindowsHelloPin
Ask (default), Yes or No. Offers to open Windows Hello setup for the signed-in desktop user.
The question defaults to No and only appears when Windows Hello is not configured.
.PARAMETER LanIPAddress
Optional active IPv4 address of the target PC. Otherwise, the LAN is selected at startup.
.PARAMETER SshPublicKey
Overrides the salon Ed25519 public key installed for local Windows accounts when OpenSSH is selected.
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
    [string]$SshPublicKey,
    [ValidateSet('Ask', 'Yes', 'No')][string]$RemoveBundledApps = 'Ask',
    [ValidateSet('Ask', 'Yes', 'No')][string]$InstallEssentialApps = 'Ask',
    [ValidateSet('Ask', 'Yes', 'No')][string]$InstallOptionalApps = 'Ask',
    [ValidateSet('Ask', 'Yes', 'No')][string]$WindowsHelloPin = 'Ask',
    [Parameter(DontShow = $true)]
    [ValidateSet('Not checked', 'Skipped', 'No desktop session', 'Already available', 'Unavailable', 'Settings opened', 'Error')]
    [string]$WindowsHelloStatus = 'Not checked',
    [Parameter(DontShow = $true)][switch]$RuntimeReady,
    [ValidateSet('Ask', 'Yes', 'No')][string]$RemoveDiscord = 'Ask'
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

    Write-Host 'WinGet repair completed. Setup will verify the package index before installing apps.'
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

function Test-JindaDesktopSession {
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected -or
        [Environment]::GetCommandLineArgs() -contains '-NonInteractive') { return $false }

    $sessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId
    if ($sessionId -eq 0) { return $false }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    # An alternate administrator can share the desktop session but owns a different account.
    $shells = Get-CimInstance Win32_Process -Filter "Name='explorer.exe' AND SessionId=$sessionId" -ErrorAction Stop
    foreach ($shell in $shells) {
        $owner = Invoke-CimMethod -InputObject $shell -MethodName GetOwnerSid -ErrorAction Stop
        if ($owner.ReturnValue -eq 0 -and $owner.Sid -eq $sid) { return $true }
    }
    return $false
}

function Get-JindaWindowsHelloAvailability {
    $checkAvailability = {
        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'SilentlyContinue'
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $verifier = [Windows.Security.Credentials.UI.UserConsentVerifier,Windows.Security.Credentials.UI,ContentType=WindowsRuntime]
        $availability = [Windows.Security.Credentials.UI.UserConsentVerifierAvailability,Windows.Security.Credentials.UI,ContentType=WindowsRuntime]
        $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        }
        $task = $asTask.MakeGenericMethod($availability).Invoke($null, @($verifier::CheckAvailabilityAsync()))
        if (-not $task.Wait([TimeSpan]::FromSeconds(10))) { throw 'Windows Hello availability check timed out.' }
        return [string]$task.Result
    }

    if ($PSVersionTable.PSEdition -eq 'Desktop') { return (& $checkAvailability) }
    # Windows PowerShell 5.1 provides the .NET Framework WinRT projection.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($checkAvailability.ToString()))
    $result = & (Get-JindaWindowsPowerShell) -NoProfile -NonInteractive -EncodedCommand $encoded
    if ($LASTEXITCODE -ne 0) { throw "Windows Hello availability check failed (exit code $LASTEXITCODE)." }
    return $result
}

function Invoke-JindaWindowsHelloPinSetup {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([ValidateSet('Ask', 'Yes', 'No')][string]$Choice = 'Ask')

    if ($Choice -eq 'No') { return 'Skipped' }
    if (-not $PSCmdlet.ShouldProcess('Windows Hello', 'Offer PIN setup for the signed-in desktop user')) { return 'Not checked' }
    try {
        if (-not (Test-JindaDesktopSession)) {
            if ($Choice -eq 'Yes') { Write-Warning 'Start setup from the desktop of the Windows account that needs the PIN.' }
            return 'No desktop session'
        }
        $availability = Get-JindaWindowsHelloAvailability
        if ($availability -eq 'Available') { return 'Already available' }
        if ($availability -ne 'NotConfiguredForUser') {
            Write-Warning "Windows Hello PIN setup was skipped (availability: $availability)."
            return 'Unavailable'
        }
        if (-not (Read-JindaYesNo -Prompt 'Set up a Windows Hello PIN for this Windows account?' -Choice $Choice)) { return 'Skipped' }

        # https://learn.microsoft.com/windows/apps/develop/launch/launch-settings
        Start-Process 'ms-settings:signinoptions-launchpinenrollment' -ErrorAction Stop
        $null = Read-Host 'Complete or close PIN setup in Windows Settings, then press Enter here'
        return 'Settings opened'
    }
    catch {
        Write-Warning "Could not complete the Windows Hello PIN setup step: $($_.Exception.Message)"
        return 'Error'
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
        Write-Host 'Select the LAN for the enabled remote access options:'
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
    return $selected[0]
}

function Test-JindaDiscordInstalled {
    $uninstallPaths = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $discord = Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue | Where-Object {
        $_.DisplayName -eq 'Discord' -and $_.Publisher -match '^Discord(?:,? Inc\.?)?$'
    } | Select-Object -First 1
    return [bool]$discord
}

function Uninstall-JindaDiscord {
    if (-not (Test-JindaDiscordInstalled)) {
        Write-Host 'Discord is already absent.'
        return
    }

    $winget = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue
    if (-not $winget) { throw 'WinGet is unavailable. Remove Discord from Windows Settings > Apps > Installed apps.' }

    Write-Host 'Uninstalling Discord using WinGet...'
    $PSNativeCommandUseErrorActionPreference = $false
    & $winget.Source uninstall --name Discord --exact --source winget --silent --accept-source-agreements --disable-interactivity | Out-Host
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $exitCodeHex = '{0:X8}' -f ($exitCode -band 0xFFFFFFFFL)
        throw "Discord: WinGet uninstall failed (exit code $exitCode / 0x$exitCodeHex)."
    }
    if (Test-JindaDiscordInstalled) { throw 'Discord is still registered as installed after WinGet returned success.' }
    Write-Host 'Discord was uninstalled.'
}

function Get-JindaSetupOptions {
    param(
        [string]$InstallApps = 'Ask', [string]$RemoteDesktop = 'Ask',
        [string]$PowerShellRemoting = 'Ask', [string]$OpenSSH = 'Ask',
        [string]$LanIPAddress, [string]$RemoveBundledApps = 'Ask', [string]$RemoveDiscord = 'Ask',
        [string]$InstallEssentialApps = 'Ask', [string]$InstallOptionalApps = 'Ask'
    )
    Write-Host 'Choose the setup options now. Setup will then continue without further questions.'
    if ($InstallEssentialApps -eq 'Ask') { $InstallEssentialApps = $InstallApps }
    if ($InstallOptionalApps -eq 'Ask') { $InstallOptionalApps = $InstallApps }
    $essential = Read-JindaYesNo -Prompt 'Install essential apps (VS Code, Everything, Notepad++, Chrome and LastPass)?' -Choice $InstallEssentialApps -Default $true
    $optional = Read-JindaYesNo -Prompt 'Install optional apps?' -Choice $InstallOptionalApps
    $rdp = Read-JindaYesNo -Prompt 'Enable Remote Desktop (RDP) on the LAN? (N = skip; leave existing settings unchanged)' -Choice $RemoteDesktop
    $winrm = Read-JindaYesNo -Prompt 'Enable PowerShell remoting (WinRM) on the LAN? (N = skip; leave existing settings unchanged)' -Choice $PowerShellRemoting
    $ssh = Read-JindaYesNo -Prompt 'Install OpenSSH for the selected LAN and authorize the salon SSH key for local users? (N = skip)' -Choice $OpenSSH
    $removeApps = Read-JindaYesNo -Prompt 'Uninstall unwanted apps?' -Choice $RemoveBundledApps
    $uninstallDiscord = $false
    if ($RemoveDiscord -ne 'No' -and (Test-JindaDiscordInstalled)) {
        $uninstallDiscord = Read-JindaYesNo -Prompt 'Uninstall Discord?' -Choice $RemoveDiscord
    }
    $lan = $null
    if ($rdp -or $winrm -or $ssh) { $lan = Select-JindaLanAddress -Address $LanIPAddress }
    [pscustomobject]@{
        InstallEssentialApps = $essential; InstallOptionalApps = $optional
        RemoteDesktop = $rdp; PowerShellRemoting = $winrm
        OpenSSH = $ssh; RemoveBundledApps = $removeApps
        RemoveDiscord = $uninstallDiscord
        LanIPAddress = [string]$lan.IPAddress
        LanInterfaceAlias = $lan.InterfaceAlias
        LanPrefixLength = $lan.PrefixLength
    }
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
        [string]$LanIPAddress,
        [string]$SshPublicKey,
        [ValidateSet('Ask', 'Yes', 'No')][string]$RemoveBundledApps = 'Ask',
        [ValidateSet('Ask', 'Yes', 'No')][string]$RemoveDiscord = 'Ask',
        [ValidateSet('Ask', 'Yes', 'No')][string]$InstallEssentialApps = 'Ask',
        [ValidateSet('Ask', 'Yes', 'No')][string]$InstallOptionalApps = 'Ask',
        [string]$WindowsHelloStatus = 'Not checked'
    )

    $ErrorActionPreference = 'Stop'
    if (-not $PSCmdlet.ShouldProcess('This PC', 'Install Jinda software and configure Windows')) { return 0 }

    # The start command downloads one complete source archive. Children never prompt.
    $choices = @{
        InstallApps = $InstallApps
        InstallEssentialApps = $InstallEssentialApps
        InstallOptionalApps = $InstallOptionalApps
        RemoteDesktop = $RemoteDesktop
        PowerShellRemoting = $PowerShellRemoting
        OpenSSH = $OpenSSH
        RemoveBundledApps = $RemoveBundledApps
        RemoveDiscord = $RemoveDiscord
        LanIPAddress = $LanIPAddress
    }
    $options = Get-JindaSetupOptions @choices
    $installAppsSelected = $options.InstallEssentialApps -or $options.InstallOptionalApps

    $selectedActions = [ordered]@{
        'Install essential apps' = $options.InstallEssentialApps
        'Install optional apps' = $options.InstallOptionalApps
        'Enable Remote Desktop (RDP)' = $options.RemoteDesktop
        'Enable PowerShell remoting (WinRM)' = $options.PowerShellRemoting
        'Install OpenSSH' = $options.OpenSSH
        'Uninstall unwanted apps' = $options.RemoveBundledApps
        'Uninstall Discord' = $options.RemoveDiscord
        'Repair WinGet' = ($RepairWinGet -and $installAppsSelected)
    }
    Write-Host ''
    Write-Host 'Setup choices'
    foreach ($action in $selectedActions.GetEnumerator()) {
        $answer = if ($action.Value) { 'Yes' } else { 'No' }
        Write-Host "  $($action.Key): $answer"
    }
    Write-Host "  Keyboard: $Keyboard"
    Write-Host "  Windows Hello: $WindowsHelloStatus"
    if ($options.LanIPAddress) {
        Write-Host ('  LAN for remote access: {0} - {1}/{2}' -f $options.LanInterfaceAlias, $options.LanIPAddress, $options.LanPrefixLength)
    }
    Write-Host ''

    if ($SshPublicKey -and -not $options.OpenSSH) {
        throw 'Select OpenSSH when providing -SshPublicKey.'
    }
    $folder = $PSScriptRoot
    $install = Join-Path $folder 'install-software.ps1'
    $config = Join-Path $folder 'set-windows-english.ps1'
    $requiredScripts = @($config)
    if ($installAppsSelected -or $options.OpenSSH) { $requiredScripts = @($install, $config, (Join-Path $folder 'skip-apps.conf')) }
    foreach ($path in $requiredScripts) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Incomplete script package: $path is missing. Use the new startup command from the GitHub README."
        }
    }
    Write-Host "Using scripts from GitHub package: $folder"

    if ($options.RemoveDiscord) { Uninstall-JindaDiscord }

    $installCode = 0
    if ($installAppsSelected -or $options.OpenSSH) {
        if ($RepairWinGet -and $installAppsSelected) { Repair-JindaWinGet }
        $installArguments = @()
        if ($options.OpenSSH) {
            if (-not $SshPublicKey) {
                $SshPublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIMeP3VEDigCWmNhjGp6BnNldtmax6GKg1Ge5xgJ5lGg salon-oss-admin'
            }
            $installArguments += @('-EnableOpenSSH', '-LanIPAddress', $options.LanIPAddress, '-SshPublicKey', $SshPublicKey)
        }
        if (-not $installAppsSelected) { $installArguments += '-SkipApps' }
        elseif (-not $options.InstallOptionalApps) { $installArguments += @('-AppGroup', 'Essential') }
        elseif (-not $options.InstallEssentialApps) { $installArguments += @('-AppGroup', 'Optional') }
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
    if ($options.RemoveBundledApps) { $configArguments += '-RemoveBundledApps' }
    if ($options.RemoteDesktop -or $options.PowerShellRemoting) {
        $configArguments += @('-LanIPAddress', $options.LanIPAddress)
    }
    $configCode = Invoke-JindaChildProcess -Executable (Get-JindaPowerShell) -ScriptPath $config -ScriptArguments $configArguments -NonInteractive
    if ($configCode -notin @(0, 3010)) { throw "Windows configuration failed (exit code $configCode)." }

    if ($installCode -eq 3010 -or $configCode -eq 3010) {
        Write-Host 'Jinda setup completed. Restart Windows to apply the changes.'
        return 3010
    }
    Write-Host 'Jinda setup completed.'
    return 0
}

# Dot-sourcing defines functions only, for tests.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        # Keep PIN enrollment in the original desktop user's context before any UAC relaunch.
        if (-not $RuntimeReady) {
            $pinSetupStatus = Invoke-JindaWindowsHelloPinSetup -Choice $WindowsHelloPin -WhatIf:$WhatIfPreference
            if ($pinSetupStatus) { $WindowsHelloStatus = $pinSetupStatus }
        }
        $scriptArguments = @('-Keyboard', $Keyboard, '-InstallApps', $InstallApps, '-RemoteDesktop', $RemoteDesktop, '-PowerShellRemoting', $PowerShellRemoting, '-OpenSSH', $OpenSSH)
        if ($WindowsHelloStatus -ne 'Not checked') { $scriptArguments += @('-WindowsHelloStatus', $WindowsHelloStatus) }
        if ($InstallEssentialApps -ne 'Ask') { $scriptArguments += @('-InstallEssentialApps', $InstallEssentialApps) }
        if ($InstallOptionalApps -ne 'Ask') { $scriptArguments += @('-InstallOptionalApps', $InstallOptionalApps) }
        if ($RemoveBundledApps -ne 'Ask') { $scriptArguments += @('-RemoveBundledApps', $RemoveBundledApps) }
        if ($RemoveDiscord -ne 'Ask') { $scriptArguments += @('-RemoveDiscord', $RemoveDiscord) }
        if ($RepairWinGet) { $scriptArguments += '-RepairWinGet' }
        if ($LanIPAddress) { $scriptArguments += @('-LanIPAddress', $LanIPAddress) }
        if ($SshPublicKey) { $scriptArguments += @('-SshPublicKey', $SshPublicKey) }
        $exitCode = Invoke-JindaManagedScript -ScriptPath $PSCommandPath -ScriptArguments $scriptArguments -RuntimeReady:$RuntimeReady -WhatIf:$WhatIfPreference -Work {
            $setup = @{
                Keyboard = $Keyboard
                RepairWinGet = $RepairWinGet
                InstallApps = $InstallApps
                InstallEssentialApps = $InstallEssentialApps
                InstallOptionalApps = $InstallOptionalApps
                RemoteDesktop = $RemoteDesktop
                PowerShellRemoting = $PowerShellRemoting
                OpenSSH = $OpenSSH
                RemoveBundledApps = $RemoveBundledApps
                RemoveDiscord = $RemoveDiscord
                LanIPAddress = $LanIPAddress
                SshPublicKey = $SshPublicKey
                WindowsHelloStatus = $WindowsHelloStatus
            }
            Invoke-JindaInitialization @setup
        }
        exit $exitCode
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
