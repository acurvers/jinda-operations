# Run with the bundled Pester in Windows PowerShell 5.1.
# Every command that changes Windows or installs a language is mocked.
$projectPath = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectPath 'set-windows-english.ps1')
Import-Module International
Import-Module LanguagePackManagement

Describe 'Microsoft Store updates' {
    BeforeEach {
        $script:storePolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
        $script:storePolicyExists = $false
        $script:autoDownload = 2
        $script:policyAtScan = $null
        Mock Test-JindaAdministrator { $true }
        Mock Test-Path { $script:storePolicyExists } -ParameterFilter { $LiteralPath -eq $script:storePolicyPath }
        Mock New-Item { $script:storePolicyExists = $true }
        Mock New-ItemProperty { $script:autoDownload = $Value }
        Mock Get-ItemProperty { [pscustomobject]@{ AutoDownload = $script:autoDownload } }
        Mock Start-ScheduledTask { $script:policyAtScan = $script:autoDownload }
    }

    It 'enables and verifies the device policy before requesting the Windows background scan' {
        Set-JindaStoreUpdates
        Assert-MockCalled New-Item -Times 1 -Exactly -Scope It -ParameterFilter { $Path -eq $script:storePolicyPath }
        Assert-MockCalled New-ItemProperty -Times 1 -Exactly -Scope It -ParameterFilter {
            $LiteralPath -eq $script:storePolicyPath -and $Name -eq 'AutoDownload' -and $PropertyType -eq 'DWord' -and $Value -eq 4
        }
        Assert-MockCalled Get-ItemProperty -Times 1 -Exactly -Scope It -ParameterFilter {
            $LiteralPath -eq $script:storePolicyPath -and $Name -eq 'AutoDownload'
        }
        Assert-MockCalled Start-ScheduledTask -Times 1 -Exactly -Scope It -ParameterFilter {
            $TaskPath -eq '\Microsoft\Windows\InstallService\' -and $TaskName -eq 'ScanForUpdates'
        }
        $script:policyAtScan | Should Be 4
    }

    It 'preserves the existing Store policy key when configuring updates' {
        $script:storePolicyExists = $true
        Set-JindaStoreUpdates
        Assert-MockCalled New-Item -Times 0 -Exactly -Scope It
        $script:policyAtScan | Should Be 4
    }

    It 'does not request the scan when the policy cannot be verified' {
        Mock New-ItemProperty {}
        { Set-JindaStoreUpdates } | Should Throw 'Could not verify the automatic Microsoft Store update policy'
        Assert-MockCalled Start-ScheduledTask -Times 0 -Exactly -Scope It
    }

    It 'warns if the scan cannot start and keeps the verified policy applied' {
        Mock Start-ScheduledTask { throw 'Simulated scheduled task failure' }
        Set-JindaStoreUpdates -WarningVariable warnings
        ($warnings -join ' ') | Should Match 'Could not start the Microsoft Store background update scan: Simulated scheduled task failure'
        $script:autoDownload | Should Be 4
    }

    It 'leaves policy and task alone in WhatIf mode' {
        Set-JindaStoreUpdates -WhatIf
        Assert-MockCalled New-Item -Times 0 -Exactly -Scope It
        Assert-MockCalled New-ItemProperty -Times 0 -Exactly -Scope It
        Assert-MockCalled Start-ScheduledTask -Times 0 -Exactly -Scope It
    }
}

Describe 'Optional removal of bundled Windows apps' {
    BeforeEach {
        Mock Test-JindaAdministrator { $true }
        Mock Get-AppxProvisionedPackage {}
        Mock Get-AppxPackage {}
        Mock Remove-AppxProvisionedPackage { [pscustomobject]@{ RestartNeeded = $false } }
        Mock Remove-AppxPackage {}
    }

    It 'deprovisions only the two targeted apps and removes installed bundle parents once' {
        Mock Get-AppxProvisionedPackage {
            [pscustomobject]@{ DisplayName = 'Microsoft.MicrosoftSolitaireCollection'; PackageName = 'SolitaireProvisioned' }
            [pscustomobject]@{ DisplayName = '7EE7776C.LinkedInforWindows'; PackageName = 'LinkedInProvisioned' }
            [pscustomobject]@{ DisplayName = 'Microsoft.WindowsCalculator'; PackageName = 'CalculatorProvisioned' }
        }
        Mock Get-AppxPackage {
            $registered = @([pscustomobject]@{ InstallState = 'Installed' })
            $staged = @([pscustomobject]@{ InstallState = 'Staged' })
            [pscustomobject]@{ Name = 'Microsoft.MicrosoftSolitaireCollection'; PackageFullName = 'SolitaireBundle'; IsBundle = $true; Version = [version]'4.27'; PackageUserInformation = $registered }
            [pscustomobject]@{ Name = 'Microsoft.MicrosoftSolitaireCollection'; PackageFullName = 'SolitaireMain'; IsBundle = $false; Version = [version]'4.27'; PackageUserInformation = $registered }
            [pscustomobject]@{ Name = '7EE7776C.LinkedInforWindows'; PackageFullName = 'LinkedInStaged'; IsBundle = $false; Version = [version]'1.0'; PackageUserInformation = $staged }
            [pscustomobject]@{ Name = '7EE7776C.LinkedInforWindows'; PackageFullName = 'LinkedInMain'; IsBundle = $false; Version = [version]'2.0'; PackageUserInformation = $registered }
            [pscustomobject]@{ Name = 'Microsoft.WindowsCalculator'; PackageFullName = 'CalculatorMain'; IsBundle = $false; Version = [version]'1.0'; PackageUserInformation = $registered }
        }

        Uninstall-JindaBundledApps | Should Be $false
        Assert-MockCalled Remove-AppxProvisionedPackage -Times 2 -Exactly -Scope It
        Assert-MockCalled Remove-AppxProvisionedPackage -Times 1 -Exactly -Scope It -ParameterFilter { $Online -and $PackageName -eq 'SolitaireProvisioned' }
        Assert-MockCalled Remove-AppxProvisionedPackage -Times 1 -Exactly -Scope It -ParameterFilter { $Online -and $PackageName -eq 'LinkedInProvisioned' }
        Assert-MockCalled Remove-AppxPackage -Times 2 -Exactly -Scope It
        Assert-MockCalled Remove-AppxPackage -Times 1 -Exactly -Scope It -ParameterFilter { $AllUsers -and $Package -eq 'SolitaireBundle' }
        Assert-MockCalled Remove-AppxPackage -Times 1 -Exactly -Scope It -ParameterFilter { $AllUsers -and $Package -eq 'LinkedInMain' }
    }

    It 'returns a restart requirement when deprovisioning reports one' {
        Mock Get-AppxProvisionedPackage {
            [pscustomobject]@{ DisplayName = 'Microsoft.MicrosoftSolitaireCollection'; PackageName = 'SolitaireProvisioned' }
        }
        Mock Remove-AppxProvisionedPackage { [pscustomobject]@{ RestartNeeded = $true } }
        Uninstall-JindaBundledApps | Should Be $true
        Assert-MockCalled Remove-AppxPackage -Times 0 -Exactly -Scope It
    }

    It 'succeeds without changes when the apps are absent' {
        Uninstall-JindaBundledApps | Should Be $false
        Assert-MockCalled Remove-AppxProvisionedPackage -Times 0 -Exactly -Scope It
        Assert-MockCalled Remove-AppxPackage -Times 0 -Exactly -Scope It
    }
}

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
        { Set-JindaWindowsEnglish } | Should Throw 'display language pack is not available yet'
        $script:mutationOrder.Count | Should Be 0
    }

    It 'requires administrator privileges before installing or changing settings' {
        Mock Test-JindaAdministrator { $false }
        { Set-JindaWindowsEnglish } | Should Throw 'Run as administrator'
        $script:mutationOrder.Count | Should Be 0
        Assert-MockCalled Install-Language -Times 0 -Exactly -Scope It
    }

    It 'rejects unsupported Windows versions' {
        Mock Get-ItemProperty {
            [pscustomobject]@{ InstallationType = 'Client'; CurrentBuildNumber = '19045'; EditionID = 'Professional' }
        }
        { Set-JindaWindowsEnglish } | Should Throw 'requires Windows 11'
        $script:mutationOrder.Count | Should Be 0
    }

    It 'rejects single-language editions before changing anything' {
        Mock Get-ItemProperty {
            [pscustomobject]@{ InstallationType = 'Client'; CurrentBuildNumber = '26100'; EditionID = 'CoreSingleLanguage' }
        }
        { Set-JindaWindowsEnglish } | Should Throw 'does not support changing the display language'
        $script:mutationOrder.Count | Should Be 0
    }

    It 'reports a system-language verification failure' {
        Mock Get-SystemPreferredUILanguage { 'nl-NL' }
        { Set-JindaWindowsEnglish } | Should Throw 'system language preference is not en-US after configuration'
    }
}
