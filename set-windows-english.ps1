#Requires -Version 5.1
<#
.SYNOPSIS
Configureert Windows 11: Engels (VS), een US-toetsenbord en optionele LAN-toegang.
.DESCRIPTION
Installeert zo nodig het en-US-weergavetaalpakket en stelt de systeemtaal,
het aanmeldscherm, systeemaccounts, nieuwe gebruikers en de uitvoerende gebruiker in.
Vraagt automatisch beheerrechten en kiest de nieuwste aanwezige stabiele PowerShell 7+.
De Windows-configuratie draait intern in Windows PowerShell 5.1. Herstart daarna.
RDP en WinRM worden alleen ingeschakeld als hun eigen switch is meegegeven.
Bij gekozen remote-toegang zijn het LAN en WireGuard-client 10.6.0.3 toegestaan,
ook voor IPv4-pings. De adresbegrenzing blijft behouden bij opnieuw uitvoeren.
.PARAMETER Keyboard
US (standaard) of USInternational. De regionale notatie blijft behouden.
.PARAMETER EnableRemoteDesktop
Schakelt RDP met NLA in voor het gekozen LAN. Zonder switch blijft RDP ongewijzigd.
.PARAMETER EnableWinRM
Schakelt Windows PowerShell-remoting in voor het gekozen LAN. Zonder switch blijft WinRM ongewijzigd.
.PARAMETER LanIPAddress
Actief IPv4-adres op deze pc; verplicht als een van de remote-opties is gekozen.
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
        catch { Write-Verbose "PowerShell-kandidaat overgeslagen: $path ($($_.Exception.Message))" }
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
            throw 'Een scriptpad of argument bevat ongeldige tekens.'
        }
        $argumentLine = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
        try {
            $process = Start-Process -FilePath $Executable -ArgumentList $argumentLine -Verb RunAs -Wait -PassThru -ErrorAction Stop
            return [int]$process.ExitCode
        }
        catch {
            throw "Starten als administrator is niet gelukt. Accepteer de Windows UAC-vraag. $($_.Exception.Message)"
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
    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Uitvoeren: $(Split-Path -Leaf $ScriptPath) met beheerrechten")) { return 0 }
    $executable = Get-JindaPowerShell -WindowsPowerShell:$WindowsPowerShell
    $administrator = Test-JindaAdministrator
    if (-not $administrator -or (Get-JindaCurrentPowerShell) -ne $executable) {
        if ($RuntimeReady) { throw 'De herstart heeft niet de vereiste beheerrechten of PowerShell-versie opgeleverd.' }
        Write-Host "Starten met beheerrechten via $executable"
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
        Write-Host "Logbestand: $logPath"
        Write-Host "PowerShell $($PSVersionTable.PSVersion); administratorrechten actief."
        return (& $Work)
    }
    catch {
        Write-Host "FOUT: $($_.Exception.Message)" -ForegroundColor Red
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
        throw 'Dit script ondersteunt alleen een IPv4-LAN.'
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
        throw 'Open Windows PowerShell als administrator en voer het script opnieuw uit.'
    }
}

function Get-LanRemoteAccessPlan {
    param(
        [Parameter(Mandatory)][System.Net.IPAddress]$Address,
        [switch]$EnableRemoteDesktop,
        [switch]$EnableWinRM
    )

    if (-not $EnableRemoteDesktop -and -not $EnableWinRM) { throw 'Kies minstens een remote-onderdeel.' }

    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        throw 'Gebruik Windows PowerShell 5.1 (powershell.exe), niet PowerShell 7 (pwsh.exe).'
    }
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $edition = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    if ($os.ProductType -ne 1 -or [int]$os.BuildNumber -lt 22000 -or
        $edition.EditionID -notmatch '^(Professional|Enterprise|Education|IoTEnterprise)') {
        throw 'Dit script is bedoeld voor Windows 11 Pro/Enterprise/Education met RDP-hostondersteuning.'
    }

    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -IPAddress $Address.IPAddressToString -ErrorAction SilentlyContinue |
        Where-Object { $_.AddressState -eq 'Preferred' })
    if ($addresses.Count -ne 1) {
        throw "Doeladres $Address is niet eenduidig actief op deze pc. Er wordt niets aangepast."
    }
    $lan = $addresses[0]
    $subnet = Get-LanIPv4Subnet -Address $Address -PrefixLength $lan.PrefixLength
    $profiles = @(Get-NetConnectionProfile -InterfaceIndex $lan.InterfaceIndex -ErrorAction Stop)
    if ($profiles.Count -ne 1) { throw 'Kan het netwerkprofiel van de LAN-interface niet eenduidig bepalen.' }
    $category = [string]$profiles[0].NetworkCategory
    $firewallProfileName = if ($category -eq 'DomainAuthenticated') { 'Domain' } else { $category }
    $firewallProfile = Get-NetFirewallProfile -PolicyStore ActiveStore -Name $firewallProfileName -ErrorAction Stop
    if ([string]$firewallProfile.Enabled -ne 'True') {
        throw "Windows Firewall staat uit voor $firewallProfileName. LAN-begrenzing kan zo niet worden toegepast."
    }
    if ([string]$firewallProfile.AllowLocalFirewallRules -eq 'False') {
        throw 'Beleid staat lokale firewallregels niet toe. Pas het centrale beleid aan; dit script overschrijft het niet.'
    }

    $port = $null
    if ($EnableRemoteDesktop) {
        $policy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -ErrorAction SilentlyContinue
        if ($null -ne $policy -and $policy.PSObject.Properties['fDenyTSConnections'] -and $policy.fDenyTSConnections -eq 1) {
            throw 'RDP wordt geblokkeerd door beleid. Er wordt niets aangepast.'
        }
        $rdp = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction Stop
        $port = [int]$rdp.PortNumber
        if ($port -lt 1 -or $port -gt 65535 -or $port -eq 5985) { throw 'Het bestaande RDP-poortnummer is ongeldig of conflicteert met WinRM.' }
    }

    # Internal rule names are independent of the Windows display language.
    $ruleNames = @()
    if ($EnableWinRM) { $ruleNames += 'WINRM-*' }
    if ($EnableRemoteDesktop) { $ruleNames += 'RemoteDesktop*' }
    $rules = @(Get-NetFirewallRule -PolicyStore PersistentStore -Name $ruleNames -ErrorAction SilentlyContinue |
        Where-Object { $_.Direction -eq 'Inbound' })
    if ($EnableRemoteDesktop) {
        foreach ($required in @('RemoteDesktop-UserMode-In-TCP', 'RemoteDesktop-UserMode-In-UDP')) {
            if ($required -notin $rules.Name) { throw "Windows-standaardregel ontbreekt: $required. Er wordt niets aangepast." }
        }
    }
    if ($EnableWinRM -and @($rules | Where-Object { $_.Name -like 'WINRM-HTTP-In-TCP*' }).Count -eq 0) {
        throw 'Windows-standaardregels voor WinRM ontbreken. Er wordt niets aangepast.'
    }
    $managed = @(Get-NetFirewallRule -PolicyStore ActiveStore -Name $rules.Name -ErrorAction Stop)
    $pingRuleName = 'Jinda-LAN-WireGuard-ICMPv4-In'
    $managed += @(Get-NetFirewallRule -PolicyStore ActiveStore -Name $pingRuleName -ErrorAction SilentlyContinue)
    if (@($managed | Where-Object { $_.PolicyStoreSourceType -eq 'GroupPolicy' }).Count) {
        throw 'Een van de benodigde firewallregels wordt centraal beheerd. Er wordt niets aangepast.'
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
    if (-not $PSCmdlet.ShouldProcess($Plan.Address, 'Gekozen remote-toegang en IPv4-ping toestaan voor dit LAN en WireGuard 10.6.0.3')) { return }
    Assert-LanRemoteAccessAdministrator
    # Scope the rules before enabling, and again afterwards because Microsoft's
    # remoting setup may update standard firewall rules itself.
    Set-LanRemoteAccessRuleScope -Plan $Plan
    if ($Plan.EnableWinRM) {
        try {
            Enable-PSRemoting -SkipNetworkProfileCheck -Force -Confirm:$false -ErrorAction Stop
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
        Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $false -ErrorAction Stop
        Set-Item -Path WSMan:\localhost\Service\Auth\Basic -Value $false -ErrorAction Stop
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
    Write-Host 'Instellingen toegepast. Test de bereikbaarheid en aanmelding nog vanaf de andere pc.'
    Write-Host ("Toegestane bronadressen voor gekozen remote-toegang en IPv4-pings: {0}." -f ($Plan.RemoteAddresses -join ', '))
    Write-Host 'WinRM-clientauthenticatie (eventueel TrustedHosts/HTTPS) wordt niet door dit script ingesteld.'
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
        throw 'De interne taalconfiguratie vereist 64-bits Windows PowerShell 5.1.'
    }

    $windows = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    if ($windows.InstallationType -ne 'Client' -or [int]$windows.CurrentBuildNumber -lt 22000) {
        throw 'Dit script vereist Windows 11.'
    }
    if ($windows.EditionID -match 'SingleLanguage|CountrySpecific') {
        throw 'Deze Windows-editie ondersteunt het wisselen van weergavetaal niet. Gebruik bijvoorbeeld Windows 11 Pro.'
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
    Write-Host "Windows-weergavetaal: en-US; toetsenbord: $Keyboard ($inputTip)."
    Write-Host "Regionale datum- en getalnotatie behouden: $((Get-Culture).Name)."
    Write-Host 'Bereik: systeemstandaard, aanmeldscherm, systeemaccounts, nieuwe gebruikers en uitvoerend account.'
    Write-Host 'Andere bestaande gebruikers behouden hun persoonlijke taalinstellingen.'

    # Alle instellingen en downloads staan achter deze ene WhatIf-controle.
    if (-not $PSCmdlet.ShouldProcess('Windows 11', 'Engels (VS) en het gekozen toetsenbord als standaard instellen')) {
        return
    }
    if (-not (Test-JindaAdministrator)) {
        throw 'Open Windows PowerShell met Als administrator uitvoeren en start het script opnieuw.'
    }
    if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
        throw 'Start dit script onder een aangemeld gebruikersaccount met beheerrechten, niet als SYSTEM.'
    }

    if (-not (Test-JindaEnglishLanguagePack)) {
        Write-Host 'Het en-US-weergavetaalpakket downloaden en installeren. Dit kan enkele minuten duren...'
        # Geen CopyToSettings: dat zou ook de regionale notatie veranderen.
        $null = Install-Language -Language 'en-US' -ExcludeFeatures -ErrorAction Stop
        if (-not (Test-JindaEnglishLanguagePack)) {
            throw 'Het en-US-weergavetaalpakket is nog niet beschikbaar. Herstart Windows en voer het script opnieuw uit.'
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
    Write-Host 'Windows-taal en toetsenbord instellen en kopieren naar systeemaccounts en nieuwe gebruikers...'
    Set-WinCultureFromLanguageListOptOut -OptOut $true
    Set-SystemPreferredUILanguage -Language 'en-US'
    Set-WinSystemLocale -SystemLocale 'en-US'
    Set-WinUserLanguageList -LanguageList $languageList -Force
    Set-WinUILanguageOverride -Language 'en-US'
    Set-WinDefaultInputMethodOverride -InputTip $inputTip
    Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true

    if ([string](Get-SystemPreferredUILanguage) -ne 'en-US') {
        throw 'De systeemvoorkeur is na het instellen niet en-US. Controleer of organisatiebeleid de instelling blokkeert.'
    }
    Write-Host 'Engels (VS) is als systeemstandaard ingesteld. Herstart Windows om alle wijzigingen toe te passen.'
    Write-Host 'Land/regio en tijdzone zijn niet aangepast. Voor nieuwe accounts wordt de regio van het uitvoerende account gekopieerd.'
    Write-Host 'Voor andere bestaande accounts moet de persoonlijke weergavetaal zo nodig afzonderlijk worden ingesteld.'
}



function Invoke-JindaConfiguration {
    param(
        [string]$ScriptPath, [string]$Keyboard,
        [switch]$EnableRemoteDesktop, [switch]$EnableWinRM, [string]$LanIPAddress
    )
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        # Keep live WinUserLanguage objects in one native Windows PowerShell process.
        # This worker inherits administrator rights and is part of this same file.
        Write-Host 'Windows-configuratie uitvoeren in Windows PowerShell 5.1 (compatibiliteit).'
        $workerArguments = @('-Keyboard', $Keyboard, '-WindowsLanguageWorker', '-RuntimeReady')
        if ($EnableRemoteDesktop) { $workerArguments += '-EnableRemoteDesktop' }
        if ($EnableWinRM) { $workerArguments += '-EnableWinRM' }
        if ($LanIPAddress) { $workerArguments += @('-LanIPAddress', $LanIPAddress) }
        return Invoke-JindaChildProcess -Executable (Get-JindaWindowsPowerShell) -ScriptPath $ScriptPath -ScriptArguments $workerArguments -NonInteractive
    }
    $remotePlan = $null
    if ($EnableRemoteDesktop -or $EnableWinRM) {
        if (-not $LanIPAddress) { throw 'LanIPAddress is verplicht voor remote-toegang. Start via init.ps1 om het LAN te kiezen.' }
        $remotePlan = Get-LanRemoteAccessPlan -Address $LanIPAddress -EnableRemoteDesktop:$EnableRemoteDesktop -EnableWinRM:$EnableWinRM
    }
    Set-JindaWindowsEnglish -Keyboard $Keyboard
    if ($remotePlan) {
        Write-Host ''
        Write-Host 'Gekozen LAN-toegang configureren...'
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
        Write-Host "FOUT: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
