#Requires -Version 5.1
<#
.SYNOPSIS
Configureert Windows 11: Engels (VS) als systeemstandaard en een US-toetsenbord.
.DESCRIPTION
Installeert zo nodig het en-US-weergavetaalpakket en stelt de systeemtaal,
het aanmeldscherm, systeemaccounts, nieuwe gebruikers en de uitvoerende gebruiker in.
Vraagt automatisch beheerrechten en kiest de nieuwste aanwezige stabiele PowerShell 7+.
De Windows-taalcmdlets draaien intern in Windows PowerShell 5.1. Herstart daarna.
.PARAMETER Keyboard
US (standaard) of USInternational. De regionale notatie blijft behouden.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('US', 'USInternational')]
    [string]$Keyboard = 'US',
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
        [switch]$Elevate
    )
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $ScriptArguments
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
    param([string]$ScriptPath, [string]$Keyboard)
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        # Keep live WinUserLanguage objects in one native Windows PowerShell process.
        # This worker inherits administrator rights and is part of this same file.
        Write-Host 'Windows-taalonderdeel uitvoeren in Windows PowerShell 5.1 (compatibiliteit).'
        return Invoke-JindaChildProcess -Executable (Get-JindaWindowsPowerShell) -ScriptPath $ScriptPath -ScriptArguments @('-Keyboard', $Keyboard, '-WindowsLanguageWorker', '-RuntimeReady')
    }
    Set-JindaWindowsEnglish -Keyboard $Keyboard
    return 0
}

# Dot-sourcing defines functions only, for tests.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $forwardArguments = @('-Keyboard', $Keyboard)
        if ($WindowsLanguageWorker) { $forwardArguments += '-WindowsLanguageWorker' }
        $exitCode = Invoke-JindaManagedScript -ScriptPath $PSCommandPath -ScriptArguments $forwardArguments -RuntimeReady:$RuntimeReady -WindowsPowerShell:$WindowsLanguageWorker -WhatIf:$WhatIfPreference -Work {
            Invoke-JindaConfiguration -ScriptPath $PSCommandPath -Keyboard $Keyboard
        }
        exit $exitCode
    }
    catch {
        Write-Host "FOUT: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
