. (Join-Path (Split-Path -Parent $PSScriptRoot) 'install-software.ps1')

Describe 'Official Yodeck installer' {
    BeforeEach {
        $script:yodeckInstalled = $false
        Mock Test-JindaYodeckInstalled { $script:yodeckInstalled }
        Mock New-Item {}
        Mock Invoke-WebRequest {}
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Flipnode LLC, O=Flipnode LLC, C=US' } }
        }
        Mock Start-Process { $script:yodeckInstalled = $true; [pscustomobject]@{ ExitCode = 0 } }
        Mock Test-Path { $false }
        Mock Remove-Item {}
    }

    It 'downloads only from the official URL and installs the verified player silently' {
        Install-JindaYodeck | Should Be $false
        Assert-MockCalled Invoke-WebRequest -Times 1 -Exactly -Scope It -ParameterFilter { $Uri -eq 'https://yodeck.link/windowsv2' }
        Assert-MockCalled Start-Process -Times 1 -Exactly -Scope It -ParameterFilter {
            $Wait -and $PassThru -and $WindowStyle -eq 'Hidden' -and $ArgumentList -contains '/S' -and $ArgumentList -contains '/allusers'
        }
        Assert-MockCalled Test-JindaYodeckInstalled -Times 2 -Exactly -Scope It
    }

    It 'skips an existing installation without downloading or executing' {
        $script:yodeckInstalled = $true
        Install-JindaYodeck | Should Be $false
        Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly -Scope It
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }

    It 'does nothing for WhatIf' {
        Install-JindaYodeck -WhatIf | Should Be $false
        Assert-MockCalled New-Item -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly -Scope It
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }

    It 'stops when the download fails' {
        Mock Invoke-WebRequest { throw 'Download failed' }
        { Install-JindaYodeck } | Should Throw 'Download failed'
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }

    It 'refuses unsigned or invalid installers' {
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } }
        { Install-JindaYodeck } | Should Throw 'geen geldige handtekening'
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }

    It 'refuses a valid signature from a different publisher' {
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Another Publisher, O=Another Publisher' } }
        }
        { Install-JindaYodeck } | Should Throw 'geen geldige handtekening'
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }

    It 'reports a failed installer exit code' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 1 } }
        { Install-JindaYodeck } | Should Throw 'installatie mislukt (exitcode 1)'
    }

    It 'does not report success if the installer leaves no registered application' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        { Install-JindaYodeck } | Should Throw 'niet teruggevonden'
    }

    It 'propagates a restart requirement' {
        Mock Start-Process { $script:yodeckInstalled = $true; [pscustomobject]@{ ExitCode = 3010 } }
        Install-JindaYodeck | Should Be $true
    }

    It 'cleans up only the downloaded executable even on failure' {
        Mock Test-Path { $true }
        Mock Invoke-WebRequest { throw 'Download failed' }
        { Install-JindaYodeck } | Should Throw 'Download failed'
        Assert-MockCalled Remove-Item -Times 1 -Exactly -Scope It -ParameterFilter { $LiteralPath -like '*\jinda-yodeck-*\yodeck-player.exe' -and -not $Recurse }
    }
}

Describe 'Yodeck installation detection' {
    It 'detects the registered player while tolerating registry entries without DisplayName' {
        Mock Get-ItemProperty { [pscustomobject]@{ OtherValue = 'unrelated' }; [pscustomobject]@{ DisplayName = 'Yodeck Player 2.224.4' } }
        Test-JindaYodeckInstalled | Should Be $true
    }

    It 'does not mistake an unrelated application for the player' {
        Mock Get-ItemProperty { [pscustomobject]@{ DisplayName = 'Unrelated Player' } }
        Test-JindaYodeckInstalled | Should Be $false
    }
}
