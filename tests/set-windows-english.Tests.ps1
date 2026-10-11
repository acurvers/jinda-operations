# Run with the bundled Pester in Windows PowerShell 5.1.
# Every command that changes Windows or installs a language is mocked.
$projectPath = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectPath 'set-windows-english.ps1')
Import-Module International
Import-Module LanguagePackManagement

Describe 'Windows English system defaults' {
    BeforeEach {
        $script:packInstalled = $true
        $script:mutationOrder = New-Object 'System.Collections.Generic.List[string]'
        Mock Import-Module {}
        Mock Test-JindaAdministrator { $true }
        Mock Get-ItemProperty {
            [pscustomobject]@{ InstallationType = 'Client'; CurrentBuildNumber = '26100'; EditionID = 'Professional' }
        }
        Mock Get-Culture { [System.Globalization.CultureInfo]::GetCultureInfo('nl-NL') }
        Mock Get-InstalledLanguage {
            $result = New-Object 'System.Collections.Generic.List[object]'
            if ($script:packInstalled) {
                $result.Add([pscustomobject]@{ LanguageId = 'en-US'; LanguagePacks = 'LpCab' })
            }
            Write-Output -NoEnumerate $result
        }
        Mock Install-Language { $script:packInstalled = $true }
        Mock Get-WinUserLanguageList {
            $oldList = New-WinUserLanguageList -Language 'nl-NL'
            $english = New-WinUserLanguageList -Language 'en-US'
            $oldList.Add($english[0])
            Write-Output -NoEnumerate $oldList
        }
        Mock Set-WinCultureFromLanguageListOptOut { $script:mutationOrder.Add('PreserveCulture') }
        Mock Set-SystemPreferredUILanguage { $script:mutationOrder.Add('SystemUI') }
        Mock Set-WinSystemLocale { $script:mutationOrder.Add('SystemLocale') }
        Mock Set-WinUserLanguageList { $script:mutationOrder.Add('UserLanguages') }
        Mock Set-WinUILanguageOverride { $script:mutationOrder.Add('UserUI') }
        Mock Set-WinDefaultInputMethodOverride { $script:mutationOrder.Add('Keyboard') }
        Mock Copy-UserInternationalSettingsToSystem { $script:mutationOrder.Add('CopyDefaults') }
        Mock Get-SystemPreferredUILanguage { 'en-US' }
    }

    It 'makes no changes or downloads for WhatIf' {
        Set-JindaWindowsEnglish -Keyboard USInternational -WhatIf
        $script:mutationOrder.Count | Should Be 0
        Assert-MockCalled Install-Language -Times 0 -Exactly -Scope It
        Assert-MockCalled Get-InstalledLanguage -Times 0 -Exactly -Scope It
    }

    It 'sets system and new-user defaults with a normal US keyboard' {
        Set-JindaWindowsEnglish
        Assert-MockCalled Set-SystemPreferredUILanguage -Times 1 -Exactly -Scope It -ParameterFilter { $Language -eq 'en-US' }
        Assert-MockCalled Set-WinSystemLocale -Times 1 -Exactly -Scope It -ParameterFilter { $SystemLocale -eq 'en-US' }
        Assert-MockCalled Set-WinUILanguageOverride -Times 1 -Exactly -Scope It -ParameterFilter { $Language.Name -eq 'en-US' }
        Assert-MockCalled Set-WinDefaultInputMethodOverride -Times 1 -Exactly -Scope It -ParameterFilter { $InputTip -eq '0409:00000409' }
        Assert-MockCalled Copy-UserInternationalSettingsToSystem -Times 1 -Exactly -Scope It -ParameterFilter { $WelcomeScreen -eq $true -and $NewUser -eq $true }
        Assert-MockCalled Install-Language -Times 0 -Exactly -Scope It
        $script:mutationOrder[0] | Should Be 'PreserveCulture'
        $script:mutationOrder[$script:mutationOrder.Count - 1] | Should Be 'CopyDefaults'
    }

    It 'uses US-International and preserves other language preferences without duplicating English' {
        Set-JindaWindowsEnglish -Keyboard USInternational
        Assert-MockCalled Set-WinDefaultInputMethodOverride -Times 1 -Exactly -Scope It -ParameterFilter { $InputTip -eq '0409:00020409' }
        Assert-MockCalled Set-WinUserLanguageList -Times 1 -Exactly -Scope It -ParameterFilter {
            $LanguageList.Count -eq 2 -and
            $LanguageList[0].LanguageTag -eq 'en-US' -and
            $LanguageList[0].InputMethodTips.Count -eq 1 -and
            $LanguageList[0].InputMethodTips[0] -eq '0409:00020409' -and
            $LanguageList[1].LanguageTag -eq 'nl-NL'
        }
        Assert-MockCalled Set-WinCultureFromLanguageListOptOut -Times 1 -Exactly -Scope It -ParameterFilter { $OptOut -eq $true }
    }

    It 'installs a missing display pack before applying settings' {
        $script:packInstalled = $false
        Set-JindaWindowsEnglish
        Assert-MockCalled Install-Language -Times 1 -Exactly -Scope It -ParameterFilter { $Language -eq 'en-US' -and $ExcludeFeatures -and -not $CopyToSettings }
        Assert-MockCalled Get-InstalledLanguage -Times 2 -Exactly -Scope It
        $script:mutationOrder.Count | Should Be 7
    }

    It 'stops before changing settings when installation fails' {
        $script:packInstalled = $false
        Mock Install-Language { throw 'Language download failed' }
        { Set-JindaWindowsEnglish } | Should Throw 'Language download failed'
        $script:mutationOrder.Count | Should Be 0
    }

    It 'stops if installation returns without a usable display pack' {
        $script:packInstalled = $false
        Mock Install-Language {}
        { Set-JindaWindowsEnglish } | Should Throw 'weergavetaalpakket is nog niet beschikbaar'
        $script:mutationOrder.Count | Should Be 0
    }

    It 'requires administrator privileges before installing or changing settings' {
        Mock Test-JindaAdministrator { $false }
        { Set-JindaWindowsEnglish } | Should Throw 'Als administrator uitvoeren'
        $script:mutationOrder.Count | Should Be 0
        Assert-MockCalled Install-Language -Times 0 -Exactly -Scope It
    }

    It 'rejects unsupported Windows versions' {
        Mock Get-ItemProperty {
            [pscustomobject]@{ InstallationType = 'Client'; CurrentBuildNumber = '19045'; EditionID = 'Professional' }
        }
        { Set-JindaWindowsEnglish } | Should Throw 'vereist Windows 11'
        $script:mutationOrder.Count | Should Be 0
    }

    It 'rejects single-language editions before changing anything' {
        Mock Get-ItemProperty {
            [pscustomobject]@{ InstallationType = 'Client'; CurrentBuildNumber = '26100'; EditionID = 'CoreSingleLanguage' }
        }
        { Set-JindaWindowsEnglish } | Should Throw 'weergavetaal niet'
        $script:mutationOrder.Count | Should Be 0
    }

    It 'reports a system-language verification failure' {
        Mock Get-SystemPreferredUILanguage { 'nl-NL' }
        { Set-JindaWindowsEnglish } | Should Throw 'systeemvoorkeur is na het instellen niet en-US'
    }
}
