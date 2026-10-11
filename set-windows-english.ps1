#Requires -Version 5.1
<#
.SYNOPSIS
Stelt Engels (Verenigde Staten) in als Windows 11-systeemstandaard.
.DESCRIPTION
Installeert zo nodig het en-US-weergavetaalpakket en stelt de systeemtaal,
het aanmeldscherm, systeemaccounts, nieuwe gebruikers en de uitvoerende
gebruiker in. Andere bestaande gebruikers behouden hun eigen voorkeuren.
Gebruik 64-bits Windows PowerShell 5.1 als administrator. Herstart daarna.
.PARAMETER Keyboard
US (standaard) of USInternational. De regionale notatie blijft behouden.
.EXAMPLE
.\set-windows-english.ps1 -Keyboard USInternational -WhatIf
.EXAMPLE
.\set-windows-english.ps1 -Keyboard USInternational
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('US', 'USInternational')]
    [string]$Keyboard = 'US'
)

function Test-JindaAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

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
        throw 'Gebruik de 64-bits Windows PowerShell 5.1 (powershell.exe), niet pwsh.exe of PowerShell (x86).'
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

# Dot-sourcing definieert alleen de functies, onder andere voor tests.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Set-JindaWindowsEnglish @PSBoundParameters
    }
    catch {
        Write-Error -Message $_.Exception.Message -ErrorAction Continue
        exit 1
    }
}
