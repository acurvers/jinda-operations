#Requires -Version 5.1
<#
.SYNOPSIS
Configure Windows 11: English (US), a US keyboard and optional remote access.
.DESCRIPTION
Installs the en-US display language pack when needed and configures the system,
sign-in screen, system accounts, new users and the current user.
Requests administrator privileges and selects the latest installed stable PowerShell 7+.
Windows configuration runs internally in Windows PowerShell 5.1. Restart afterwards.
RDP and WinRM are enabled only when their individual switches are specified.
Selected remote access and IPv4 ping allow the LAN and WireGuard client 10.6.0.3.
These address restrictions are retained when the script is run again.
Adds Jinda Operations as a managed bookmark in Chrome and Edge for all Windows users.
Personal bookmarks are unchanged; Edge excludes profiles signed in with a personal Microsoft account.
Disables age-based password expiration for existing and future local Windows accounts.
.PARAMETER Keyboard
US (default) or USInternational. Regional date and number formats are preserved.
.PARAMETER EnableRemoteDesktop
Enables RDP with NLA. Without this switch, RDP settings are unchanged.
.PARAMETER EnableWinRM
Enables Windows PowerShell and the latest installed stable PowerShell 7 remoting.
Connect with -ConfigurationName PowerShell.7. Without this switch, WinRM settings are unchanged.
.PARAMETER LanIPAddress
Active IPv4 address on this PC; required when a remote access option is selected.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('US', 'USInternational')]
    [string]$Keyboard = 'US',
    [switch]$EnableRemoteDesktop,
    [switch]$EnableWinRM,
    [string]$LanIPAddress,
    [Parameter(DontShow = $true)][switch]$RuntimeReady,
    [Parameter(DontShow = $true)][switch]$WindowsLanguageWorker
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

# BEGIN LAN remote access adapted from strato-kor-ansible/tools/windows-lan-remote-access/Enable-LanRemoteAccess.ps1.
function Get-LanIPv4Subnet {
    param(
        [Parameter(Mandatory)][System.Net.IPAddress]$Address,
        [Parameter(Mandatory)][ValidateRange(1, 30)][int]$PrefixLength
    )
    if ($Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw 'This script supports IPv4 LANs only.'
    }
    $bytes = $Address.GetAddressBytes()
    for ($index = 0; $index -lt 4; $index++) {
        $bits = [Math]::Min(8, [Math]::Max(0, $PrefixLength - ($index * 8)))
        $mask = if ($bits -eq 0) { 0 } else { (255 -shl (8 - $bits)) -band 255 }
        $bytes[$index] = $bytes[$index] -band $mask
    }
    return (($bytes -join '.') + '/' + $PrefixLength)
}

function Assert-LanRemoteAccessAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Open Windows PowerShell as administrator and run the script again.'
    }
}

function Get-JindaPowerShell7RemotingRuntime {
    $runtime = Get-JindaPowerShellCandidates | Where-Object { $_.Version.Major -eq 7 } |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $runtime) {
        throw 'WinRM requires an installed stable 64-bit PowerShell 7. Choose app installation first, then enable WinRM again.'
    }
    return $runtime
}

function Enable-JindaPowerShell7Endpoint {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    $ErrorActionPreference = 'Stop'
    if (-not $PSCmdlet.ShouldProcess('PowerShell.7', 'Enable remoting with this PowerShell installation')) { return }
    if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -ne 7 -or
        $PSVersionTable.PSVersion.ToString() -match '-') {
        throw 'The WinRM endpoint worker must run in stable PowerShell 7.'
    }
    Enable-PSRemoting -SkipNetworkProfileCheck -Force -Confirm:$false -ErrorAction Stop
    $endpoint = Get-PSSessionConfiguration -Name 'PowerShell.7' -ErrorAction Stop
    $versionedName = 'PowerShell.' + $PSVersionTable.PSVersion.ToString()
    $expectedPlugin = (Get-WSManInstance -ResourceURI 'winrm/config/plugin' -SelectorSet @{ Name = $versionedName } -ErrorAction Stop).Filename
    $plugin = (Get-WSManInstance -ResourceURI 'winrm/config/plugin' -SelectorSet @{ Name = 'PowerShell.7' } -ErrorAction Stop).Filename
    if (-not $expectedPlugin) { throw 'The version-specific PowerShell 7 WinRM plugin was not found.' }
    # Enable-PSRemoting keeps existing endpoints. Refresh an older major-name
    # endpoint from this runtime while retaining its access-control descriptor.
    # PSVersion metadata omits the patch number, so compare versioned plugin paths.
    if ($plugin -ine $expectedPlugin) {
        $parameters = @{ Name = 'PowerShell.7'; Force = $true; Confirm = $false; ErrorAction = 'Stop' }
        if (-not $endpoint.SecurityDescriptorSddl) { throw 'Cannot preserve the existing PowerShell.7 endpoint permissions.' }
        $parameters.SecurityDescriptorSddl = $endpoint.SecurityDescriptorSddl
        Register-PSSessionConfiguration @parameters | Out-Null
        $endpoint = Get-PSSessionConfiguration -Name 'PowerShell.7' -ErrorAction Stop
        $plugin = (Get-WSManInstance -ResourceURI 'winrm/config/plugin' -SelectorSet @{ Name = 'PowerShell.7' } -ErrorAction Stop).Filename
    }
    $endpointVersion = [version]$endpoint.PSVersion
    if ($plugin -ine $expectedPlugin -or $endpointVersion.Major -ne 7 -or
        $endpointVersion.Minor -ne $PSVersionTable.PSVersion.Minor -or
        [string]$endpoint.Enabled -ne 'True') {
        throw 'PowerShell.7 endpoint verification failed: it must be enabled and use the selected PowerShell version.'
    }
    Write-Host "WinRM endpoint PowerShell.7 is enabled for PowerShell $($PSVersionTable.PSVersion)."
}

function Invoke-JindaPowerShell7Remoting {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][string]$Executable)
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    if (-not $PSCmdlet.ShouldProcess($Executable, 'Configure the PowerShell.7 WinRM endpoint')) { return }
    # Run the function in the native runtime, never through the 5.1 compatibility layer.
    $command = '$ErrorActionPreference = ''Stop''; try { & {' +
        ${function:Enable-JindaPowerShell7Endpoint}.ToString() +
        '}; exit 0 } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    & $Executable -NoProfile -NonInteractive -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand $encoded | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "PowerShell 7 WinRM configuration failed (exit code $LASTEXITCODE)."
    }
}

function Get-LanRemoteAccessPlan {
    param(
        [Parameter(Mandatory)][System.Net.IPAddress]$Address,
        [switch]$EnableRemoteDesktop,
        [switch]$EnableWinRM
    )

    if (-not $EnableRemoteDesktop -and -not $EnableWinRM) { throw 'Select at least one remote access option.' }

    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        throw 'Use Windows PowerShell 5.1 (powershell.exe), not PowerShell 7 (pwsh.exe).'
    }
    $powerShell7 = $null
    if ($EnableWinRM) { $powerShell7 = Get-JindaPowerShell7RemotingRuntime }
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $edition = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    if ($os.ProductType -ne 1 -or [int]$os.BuildNumber -lt 22000 -or
        $edition.EditionID -notmatch '^(Professional|Enterprise|Education|IoTEnterprise)') {
        throw 'This script requires Windows 11 Pro/Enterprise/Education with RDP host support.'
    }

    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -IPAddress $Address.IPAddressToString -ErrorAction SilentlyContinue |
        Where-Object { $_.AddressState -eq 'Preferred' })
    if ($addresses.Count -ne 1) {
        throw "Target address $Address must match exactly one active interface on this PC. Nothing will be changed."
    }
    $lan = $addresses[0]
    $subnet = Get-LanIPv4Subnet -Address $Address -PrefixLength $lan.PrefixLength
    $profiles = @(Get-NetConnectionProfile -InterfaceIndex $lan.InterfaceIndex -ErrorAction Stop)
    if ($profiles.Count -ne 1) { throw 'Cannot identify a unique network profile for the LAN interface.' }
    $category = [string]$profiles[0].NetworkCategory
    $firewallProfileName = if ($category -eq 'DomainAuthenticated') { 'Domain' } else { $category }
    $firewallProfile = Get-NetFirewallProfile -PolicyStore ActiveStore -Name $firewallProfileName -ErrorAction Stop
    if ([string]$firewallProfile.Enabled -ne 'True') {
        throw "Windows Firewall is disabled for $firewallProfileName. LAN access restrictions cannot be applied."
    }
    if ([string]$firewallProfile.AllowLocalFirewallRules -eq 'False') {
        throw 'Policy does not allow local firewall rules. Update the central policy; this script will not override it.'
    }

    $port = $null
    if ($EnableRemoteDesktop) {
        $policy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -ErrorAction SilentlyContinue
        if ($null -ne $policy -and $policy.PSObject.Properties['fDenyTSConnections'] -and $policy.fDenyTSConnections -eq 1) {
            throw 'RDP is blocked by policy. Nothing will be changed.'
        }
        $rdp = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction Stop
        $port = [int]$rdp.PortNumber
        if ($port -lt 1 -or $port -gt 65535 -or $port -eq 5985) { throw 'The existing RDP port is invalid or conflicts with WinRM.' }
    }

    # Internal rule names are independent of the Windows display language.
    $ruleNames = @()
    if ($EnableWinRM) { $ruleNames += 'WINRM-*' }
    if ($EnableRemoteDesktop) { $ruleNames += 'RemoteDesktop*' }
    $rules = @(Get-NetFirewallRule -PolicyStore PersistentStore -Name $ruleNames -ErrorAction SilentlyContinue |
        Where-Object { $_.Direction -eq 'Inbound' })
    if ($EnableRemoteDesktop) {
        foreach ($required in @('RemoteDesktop-UserMode-In-TCP', 'RemoteDesktop-UserMode-In-UDP')) {
            if ($required -notin $rules.Name) { throw "A required Windows default rule is missing: $required. Nothing will be changed." }
        }
    }
    if ($EnableWinRM -and @($rules | Where-Object { $_.Name -like 'WINRM-HTTP-In-TCP*' }).Count -eq 0) {
        throw 'Windows default rules for WinRM are missing. Nothing will be changed.'
    }
    $managed = @(Get-NetFirewallRule -PolicyStore ActiveStore -Name $rules.Name -ErrorAction Stop)
    $pingRuleName = 'Jinda-LAN-WireGuard-ICMPv4-In'
    $managed += @(Get-NetFirewallRule -PolicyStore ActiveStore -Name $pingRuleName -ErrorAction SilentlyContinue)
    if (@($managed | Where-Object { $_.PolicyStoreSourceType -eq 'GroupPolicy' }).Count) {
        throw 'One of the required firewall rules is centrally managed. Nothing will be changed.'
    }

    [pscustomobject]@{
        Computer = $env:COMPUTERNAME
        Address = $Address.IPAddressToString
        InterfaceAlias = [string]$lan.InterfaceAlias
        Subnet = $subnet
        RemoteAddresses = @($subnet, '10.6.0.3')
        PingRuleName = $pingRuleName
        NetworkProfile = $category
        WinRMPort = 5985
        RDPPort = $port
        EnableRemoteDesktop = [bool]$EnableRemoteDesktop
        EnableWinRM = [bool]$EnableWinRM
        PowerShell7 = $powerShell7
        RuleNames = $ruleNames
        Rules = $rules
    }
}

function Set-LanRemoteAccessRuleScope {
    param([Parameter(Mandatory)]$Plan)
    $interfacePattern = [System.Management.Automation.WildcardPattern]::Escape($Plan.InterfaceAlias)
    foreach ($rule in $Plan.Rules) {
        # Preserve enabled/disabled state here. Only the three required rule types
        # are enabled below; compatibility, HTTPS and shadowing rules stay as found.
        Set-NetFirewallRule -PolicyStore PersistentStore -Name $rule.Name -Profile Any `
            -LocalAddress $Plan.Address -RemoteAddress $Plan.RemoteAddresses `
            -InterfaceAlias $interfacePattern -EdgeTraversalPolicy Block -ErrorAction Stop
    }
}

function Set-LanRemoteAccessPingRule {
    param([Parameter(Mandatory)]$Plan)
    $parameters = @{
        PolicyStore = 'PersistentStore'
        Enabled = 'True'
        Direction = 'Inbound'
        Action = 'Allow'
        Profile = 'Any'
        Protocol = 'ICMPv4'
        IcmpType = '8'
        LocalAddress = $Plan.Address
        RemoteAddress = $Plan.RemoteAddresses
        InterfaceAlias = [System.Management.Automation.WildcardPattern]::Escape($Plan.InterfaceAlias)
        EdgeTraversalPolicy = 'Block'
        ErrorAction = 'Stop'
    }
    if (Get-NetFirewallRule -PolicyStore PersistentStore -Name $Plan.PingRuleName -ErrorAction SilentlyContinue) {
        Set-NetFirewallRule -Name $Plan.PingRuleName @parameters
    }
    else {
        New-NetFirewallRule -Name $Plan.PingRuleName -DisplayName 'Jinda - IPv4 ping from LAN and WireGuard' @parameters | Out-Null
    }
}

function Invoke-LanRemoteAccessSetup {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)]$Plan)
    $ErrorActionPreference = 'Stop'
    if (-not $PSCmdlet.ShouldProcess($Plan.Address, 'Enable selected remote access and IPv4 ping for this LAN and WireGuard 10.6.0.3')) { return }
    Assert-LanRemoteAccessAdministrator
    # Scope the rules before enabling, and again afterwards because Microsoft's
    # remoting setup may update standard firewall rules itself.
    Set-LanRemoteAccessRuleScope -Plan $Plan
    if ($Plan.EnableWinRM) {
        try {
            Enable-PSRemoting -SkipNetworkProfileCheck -Force -Confirm:$false -ErrorAction Stop
            Write-Host "Configuring WinRM using PowerShell $($Plan.PowerShell7.Version)..."
            Invoke-JindaPowerShell7Remoting -Executable $Plan.PowerShell7.Path
        }
        finally {
            # Include any extra standard rule created by Microsoft's setup.
            $Plan.Rules = @(Get-NetFirewallRule -PolicyStore PersistentStore -Name $Plan.RuleNames -ErrorAction Stop |
                Where-Object { $_.Direction -eq 'Inbound' })
            Set-LanRemoteAccessRuleScope -Plan $Plan
        }
        foreach ($rule in $Plan.Rules | Where-Object { $_.Name -like 'WINRM-HTTP-In-TCP*' }) {
            Set-NetFirewallRule -PolicyStore PersistentStore -Name $rule.Name -Enabled True `
                -Protocol TCP -LocalPort $Plan.WinRMPort -ErrorAction Stop
        }
        # Keep Windows authentication and encrypted WinRM messages, including over HTTP.
        # Use direct WSMan requests rather than the WSMan: provider, which failed
        # with a Public-network error after successful remoting setup on a client PC.
        Set-WSManInstance -ResourceURI 'winrm/config/service' `
            -ValueSet @{ AllowUnencrypted = 'false' } -ErrorAction Stop | Out-Null
        Set-WSManInstance -ResourceURI 'winrm/config/service/auth' `
            -ValueSet @{ Basic = 'false' } -ErrorAction Stop | Out-Null
        $serviceSettings = Get-WSManInstance -ResourceURI 'winrm/config/service' -ErrorAction Stop
        $authSettings = Get-WSManInstance -ResourceURI 'winrm/config/service/auth' -ErrorAction Stop
        if ([string]$serviceSettings.AllowUnencrypted -ine 'false' -or [string]$authSettings.Basic -ine 'false') {
            throw 'WinRM security verification failed: AllowUnencrypted and Basic must both be disabled.'
        }
        Test-WSMan -ComputerName localhost -ErrorAction Stop | Out-Null
    }
    # Enable the scoped RDP rules before touching the listener. Do not restart
    # TermService: an existing RDP session should not be forcibly disconnected.
    if ($Plan.EnableRemoteDesktop) {
        Set-NetFirewallRule -PolicyStore PersistentStore -Name 'RemoteDesktop-UserMode-In-TCP' `
            -Enabled True -Protocol TCP -LocalPort $Plan.RDPPort -ErrorAction Stop
        Set-NetFirewallRule -PolicyStore PersistentStore -Name 'RemoteDesktop-UserMode-In-UDP' `
            -Enabled True -Protocol UDP -LocalPort $Plan.RDPPort -ErrorAction Stop
        Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' `
            -Name fDenyTSConnections -Value 0 -ErrorAction Stop
        Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
            -Name UserAuthentication -Value 1 -ErrorAction Stop
        Set-Service -Name TermService -StartupType Automatic -ErrorAction Stop
        Start-Service -Name TermService -ErrorAction Stop
    }

    Set-LanRemoteAccessPingRule -Plan $Plan

    $services = @()
    $ports = @()
    if ($Plan.EnableWinRM) { $services += 'WinRM'; $ports += $Plan.WinRMPort }
    if ($Plan.EnableRemoteDesktop) { $services += 'TermService'; $ports += $Plan.RDPPort }
    Get-Service -Name $services -ErrorAction Stop | Select-Object Name, Status, StartType
    Get-NetTCPConnection -State Listen -ErrorAction Stop |
        Where-Object { $_.LocalPort -in $ports } |
        Select-Object LocalAddress, LocalPort, State
    Write-Host 'Settings applied. Test connectivity and sign-in from the other PC.'
    Write-Host ("Allowed source addresses for selected remote access and IPv4 pings: {0}." -f ($Plan.RemoteAddresses -join ', '))
    Write-Host 'This script does not configure WinRM client authentication (such as TrustedHosts/HTTPS).'
    if ($Plan.EnableWinRM) {
        Write-Host "For PowerShell 7, connect with: Enter-PSSession -ComputerName $($Plan.Address) -ConfigurationName PowerShell.7 -Authentication Negotiate -Credential (Get-Credential)"
        Write-Host 'Without -ConfigurationName PowerShell.7, the client still selects Windows PowerShell 5.1.'
    }
}
# END LAN remote access.

function Test-JindaEnglishLanguagePack {
    # Deze cmdlet geeft een List terug als een enkel pipeline-object.
    $languages = Get-InstalledLanguage -Language 'en-US' -ErrorAction Stop
    foreach ($language in $languages) {
        if ($language.LanguageId -eq 'en-US' -and [string]$language.LanguagePacks -match 'LpCab') {
            return $true
        }
    }
    return $false
}

function Set-JindaWindowsEnglish {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [ValidateSet('US', 'USInternational')]
        [string]$Keyboard = 'US'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) {
        throw 'The internal language configuration requires 64-bit Windows PowerShell 5.1.'
    }

    $windows = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    if ($windows.InstallationType -ne 'Client' -or [int]$windows.CurrentBuildNumber -lt 22000) {
        throw 'This script requires Windows 11.'
    }
    if ($windows.EditionID -match 'SingleLanguage|CountrySpecific') {
        throw 'This Windows edition does not support changing the display language. Use an edition such as Windows 11 Pro.'
    }

    Import-Module International -ErrorAction Stop
    Import-Module LanguagePackManagement -ErrorAction Stop
    $requiredCommands = @(
        'Get-InstalledLanguage', 'Install-Language', 'Set-SystemPreferredUILanguage',
        'Get-SystemPreferredUILanguage', 'New-WinUserLanguageList', 'Get-WinUserLanguageList',
        'Set-WinUserLanguageList', 'Set-WinUILanguageOverride', 'Set-WinSystemLocale',
        'Set-WinDefaultInputMethodOverride', 'Set-WinCultureFromLanguageListOptOut',
        'Copy-UserInternationalSettingsToSystem'
    )
    foreach ($command in $requiredCommands) {
        $null = Get-Command -Name $command -ErrorAction Stop
    }

    $inputTip = if ($Keyboard -eq 'USInternational') { '0409:00020409' } else { '0409:00000409' }
    Write-Host "Windows display language: en-US; keyboard: $Keyboard ($inputTip)."
    Write-Host "Preserving regional date and number formats: $((Get-Culture).Name)."
    Write-Host 'Scope: system default, sign-in screen, system accounts, new users and the current account.'
    Write-Host 'Other existing users keep their personal language settings.'

    # Alle instellingen en downloads staan achter deze ene WhatIf-controle.
    if (-not $PSCmdlet.ShouldProcess('Windows 11', 'Set English (US) and the selected keyboard as defaults')) {
        return
    }
    if (-not (Test-JindaAdministrator)) {
        throw 'Open Windows PowerShell using Run as administrator and start the script again.'
    }
    if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
        throw 'Run this script from a signed-in user account with administrator privileges, not as SYSTEM.'
    }

    if (-not (Test-JindaEnglishLanguagePack)) {
        Write-Host 'Downloading and installing the en-US display language pack. This may take several minutes...'
        # Geen CopyToSettings: dat zou ook de regionale notatie veranderen.
        $null = Install-Language -Language 'en-US' -ExcludeFeatures -ErrorAction Stop
        if (-not (Test-JindaEnglishLanguagePack)) {
            throw 'The en-US display language pack is not available yet. Restart Windows and run the script again.'
        }
    }

    $languageList = New-WinUserLanguageList -Language 'en-US'
    $languageList[0].InputMethodTips.Clear()
    $languageList[0].InputMethodTips.Add($inputTip)
    # Engels wordt de eerste voorkeur; overige talen blijven beschikbaar.
    foreach ($existingLanguage in (Get-WinUserLanguageList)) {
        if ($existingLanguage.LanguageTag -ne 'en-US') {
            $languageList.Add($existingLanguage)
        }
    }

    # Voorkom dat de Engelse UI ook datum- en getalnotatie omzet naar Amerikaans.
    Write-Host 'Setting the Windows language and keyboard, then copying settings to system accounts and new users...'
    Set-WinCultureFromLanguageListOptOut -OptOut $true
    Set-SystemPreferredUILanguage -Language 'en-US'
    Set-WinSystemLocale -SystemLocale 'en-US'
    Set-WinUserLanguageList -LanguageList $languageList -Force
    Set-WinUILanguageOverride -Language 'en-US'
    Set-WinDefaultInputMethodOverride -InputTip $inputTip
    Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true

    if ([string](Get-SystemPreferredUILanguage) -ne 'en-US') {
        throw 'The system language preference is not en-US after configuration. Check whether organization policy blocks the setting.'
    }
    Write-Host 'English (US) is set as the system default. Restart Windows to apply all changes.'
    Write-Host 'Country/region and time zone are unchanged. New accounts inherit the region of the current account.'
    Write-Host 'For other existing accounts, set the personal display language separately if needed.'
}



# BEGIN managed browser bookmarks.
function Assert-JindaBookmarkNodes {
    param([AllowEmptyCollection()][object[]]$Nodes, [int]$Depth = 0)
    if ($Depth -gt 40) { throw 'The existing bookmark policy is too deeply nested; it has not been changed.' }
    foreach ($node in $Nodes) {
        if ($null -eq $node -or $node -isnot [pscustomobject]) { throw 'The existing bookmark policy contains an invalid entry.' }
        $properties = $node.PSObject.Properties
        if ($properties['toplevel_name']) {
            if ($Depth -ne 0 -or $node.toplevel_name -isnot [string] -or @($properties).Count -ne 1) {
                throw 'The existing bookmark policy has an invalid top-level folder name.'
            }
            continue
        }
        if (-not $properties['name'] -or $node.name -isnot [string]) { throw 'The existing bookmark policy contains an entry without a name.' }
        if ($properties['children']) {
            if ($properties['url'] -or $node.children -isnot [array]) { throw 'The existing bookmark policy contains an invalid folder.' }
            Assert-JindaBookmarkNodes -Nodes $node.children -Depth ($Depth + 1)
        }
        elseif (-not $properties['url'] -or $node.url -isnot [string]) { throw 'The existing bookmark policy contains an entry without a URL.' }
    }
}

function Test-JindaBookmarkUrl {
    param([AllowEmptyCollection()][object[]]$Nodes)
    foreach ($node in $Nodes) {
        if ($node.PSObject.Properties['url'] -and $node.url.TrimEnd('/') -ceq 'https://acurvers.github.io/jinda-operations') { return $true }
        if ($node.PSObject.Properties['children'] -and (Test-JindaBookmarkUrl -Nodes $node.children)) { return $true }
    }
    return $false
}

function Add-JindaManagedBookmarkJson {
    param([AllowNull()][AllowEmptyString()][string]$Json)
    $entries = @()
    if (-not [string]::IsNullOrWhiteSpace($Json)) {
        if (-not $Json.TrimStart().StartsWith('[')) { throw 'The existing bookmark policy must be a JSON array; it has not been changed.' }
        # Windows PowerShell 5.1 emits the parsed array as one pipeline object.
        try { $parsed = ConvertFrom-Json -InputObject $Json -ErrorAction Stop }
        catch { throw "The existing bookmark policy is invalid JSON; it has not been changed. $($_.Exception.Message)" }
        $entries = @($parsed)
        Assert-JindaBookmarkNodes -Nodes $entries
        if (@($entries | Where-Object { $_.PSObject.Properties['toplevel_name'] }).Count -gt 1) {
            throw 'The existing bookmark policy has multiple top-level folder names; it has not been changed.'
        }
        # Preserve an existing link, including its name/location and original JSON.
        if (Test-JindaBookmarkUrl -Nodes $entries) { return $Json }
    }
    $bookmark = [pscustomobject]@{ name = 'Jinda Operations'; url = 'https://acurvers.github.io/jinda-operations/' }
    $topNames = @($entries | Where-Object { $_.PSObject.Properties['toplevel_name'] })
    if ($entries.Count -eq 0) {
        $entries = @([pscustomobject]@{ toplevel_name = 'Jinda' }, $bookmark)
    }
    elseif ($topNames.Count -eq 1 -and $topNames[0].toplevel_name -eq 'Jinda') {
        $entries += $bookmark
    }
    else {
        # Keep an existing managed folder name and put Jinda inside that folder.
        $folders = @($entries | Where-Object { $_.PSObject.Properties['children'] -and $_.name -eq 'Jinda' })
        if ($folders.Count -gt 0) { $folders[0].children = @($folders[0].children) + @($bookmark) }
        else { $entries += [pscustomobject]@{ name = 'Jinda'; children = @($bookmark) } }
    }
    return ConvertTo-Json -InputObject $entries -Depth 100 -Compress
}

function Get-JindaBookmarkPolicyJson {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) { return $null }
    if (Test-Path -LiteralPath (Join-Path $Path $Name) -ErrorAction Stop) {
        throw "The existing $Name policy uses registry subkeys. Merge it in its management tool; this script will not replace it."
    }
    $key = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
    $property = $key.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    if ($property.Value -isnot [string]) { throw "The existing $Name policy is not a JSON string; it has not been changed." }
    return $property.Value
}

function Set-JindaBrowserBookmarks {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    if (-not $PSCmdlet.ShouldProcess('Chrome and Edge on this PC', 'Add the managed Jinda Operations bookmark for all Windows users')) { return }
    if (-not (Test-JindaAdministrator) -or -not [Environment]::Is64BitProcess) {
        throw 'Managed browser bookmarks require a 64-bit administrator PowerShell process.'
    }
    $policies = @(
        [pscustomobject]@{ Browser = 'Chrome'; Path = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; Name = 'ManagedBookmarks' },
        [pscustomobject]@{ Browser = 'Edge'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'ManagedFavorites' }
    )
    # Validate both existing policies before writing either one. Never reset a
    # malformed policy or touch profile Bookmarks files, user data or other policies.
    $plans = foreach ($policy in $policies) {
        $original = Get-JindaBookmarkPolicyJson -Path $policy.Path -Name $policy.Name
        [pscustomobject]@{ Policy = $policy; Original = $original; Json = (Add-JindaManagedBookmarkJson -Json $original) }
    }
    foreach ($plan in $plans) {
        $policy = $plan.Policy
        if ($plan.Json -ceq $plan.Original) {
            Write-Host "$($policy.Browser): the Jinda Operations bookmark is already configured."
            continue
        }
        $current = Get-JindaBookmarkPolicyJson -Path $policy.Path -Name $policy.Name
        if ($current -cne $plan.Original) { throw "$($policy.Browser): bookmark policy changed during setup. Run again to merge the current value." }
        $null = New-Item -Path $policy.Path -Force -ErrorAction Stop
        $null = New-ItemProperty -LiteralPath $policy.Path -Name $policy.Name -PropertyType String -Value $plan.Json -Force -ErrorAction Stop
        if ((Get-JindaBookmarkPolicyJson -Path $policy.Path -Name $policy.Name) -cne $plan.Json) {
            throw "$($policy.Browser): could not verify the saved bookmark policy."
        }
        Write-Host "$($policy.Browser): the managed Jinda Operations bookmark policy is configured."
    }
    Write-Host 'Browsers apply the bookmark on policy refresh or next start; existing windows remain open.'
    Write-Host 'Edge does not apply this policy to profiles signed in with a personal Microsoft account.'
}
# END managed browser bookmarks.

function Set-JindaLocalPasswordAgePolicy {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if (-not $PSCmdlet.ShouldProcess('Local Windows account policy', 'Set maximum password age to unlimited')) { return }
    if (-not (Test-JindaAdministrator)) { throw 'Local password policy setup requires administrator privileges.' }
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    $net = Get-Command -Name 'net.exe' -CommandType Application -ErrorAction Stop
    # Change only maximum password age, for this PC (no /DOMAIN). This also
    # covers future local accounts without a recurring task or per-user flags.
    # https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/net-commands-on-operating-systems
    & $net.Source accounts /maxpwage:unlimited | Out-Host
    $policyExitCode = $LASTEXITCODE
    if ($policyExitCode -ne 0) { throw "Could not disable local password expiration (net.exe exit code $policyExitCode)." }
    Write-Host 'Local Windows passwords no longer expire because of their age.'
    Write-Host 'Current local account policy (centrally managed policies can override local settings):'
    & $net.Source accounts | Out-Host
    $queryExitCode = $LASTEXITCODE
    if ($queryExitCode -ne 0) { throw "Password policy was applied, but displaying the current policy failed (net.exe exit code $queryExitCode)." }
}

function Invoke-JindaConfiguration {
    param(
        [string]$ScriptPath, [string]$Keyboard,
        [switch]$EnableRemoteDesktop, [switch]$EnableWinRM, [string]$LanIPAddress
    )
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        # Keep live WinUserLanguage objects in one native Windows PowerShell process.
        # This worker inherits administrator rights and is part of this same file.
        Write-Host 'Running Windows configuration in Windows PowerShell 5.1 (compatibility).'
        $workerArguments = @('-Keyboard', $Keyboard, '-WindowsLanguageWorker', '-RuntimeReady')
        if ($EnableRemoteDesktop) { $workerArguments += '-EnableRemoteDesktop' }
        if ($EnableWinRM) { $workerArguments += '-EnableWinRM' }
        if ($LanIPAddress) { $workerArguments += @('-LanIPAddress', $LanIPAddress) }
        return Invoke-JindaChildProcess -Executable (Get-JindaWindowsPowerShell) -ScriptPath $ScriptPath -ScriptArguments $workerArguments -NonInteractive
    }
    $remotePlan = $null
    if ($EnableRemoteDesktop -or $EnableWinRM) {
        if (-not $LanIPAddress) { throw 'LanIPAddress is required for remote access. Start with init.ps1 to select the LAN.' }
        $remotePlan = Get-LanRemoteAccessPlan -Address $LanIPAddress -EnableRemoteDesktop:$EnableRemoteDesktop -EnableWinRM:$EnableWinRM
    }
    Set-JindaWindowsEnglish -Keyboard $Keyboard
    Write-Host ''
    Set-JindaLocalPasswordAgePolicy
    Write-Host ''
    Set-JindaBrowserBookmarks
    if ($remotePlan) {
        Write-Host ''
        Write-Host 'Configuring the selected LAN access options...'
        $remotePlan | Select-Object Address, RemoteAddresses, InterfaceAlias, EnableRemoteDesktop, EnableWinRM | Format-List | Out-Host
        Invoke-LanRemoteAccessSetup -Plan $remotePlan | Out-Host
    }
    return 0
}

# Dot-sourcing defines functions only, for tests.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $forwardArguments = @('-Keyboard', $Keyboard)
        if ($WindowsLanguageWorker) { $forwardArguments += '-WindowsLanguageWorker' }
        if ($EnableRemoteDesktop) { $forwardArguments += '-EnableRemoteDesktop' }
        if ($EnableWinRM) { $forwardArguments += '-EnableWinRM' }
        if ($LanIPAddress) { $forwardArguments += @('-LanIPAddress', $LanIPAddress) }
        $exitCode = Invoke-JindaManagedScript -ScriptPath $PSCommandPath -ScriptArguments $forwardArguments -RuntimeReady:$RuntimeReady -WindowsPowerShell:$WindowsLanguageWorker -WhatIf:$WhatIfPreference -Work {
            Invoke-JindaConfiguration -ScriptPath $PSCommandPath -Keyboard $Keyboard -EnableRemoteDesktop:$EnableRemoteDesktop -EnableWinRM:$EnableWinRM -LanIPAddress $LanIPAddress
        }
        exit $exitCode
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
