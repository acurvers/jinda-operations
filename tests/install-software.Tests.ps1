. (Join-Path (Split-Path -Parent $PSScriptRoot) 'install-software.ps1')

function Invoke-JindaFakeWinget {
    $script:wingetCalls.Add(@($args))
    $global:LASTEXITCODE = $script:wingetExitCodes[$script:wingetCalls.Count - 1]
    Write-Output 'Simulated WinGet output'
}

Describe 'All requested Jinda applications' {
    BeforeEach {
        $script:wingetCalls = New-Object 'System.Collections.Generic.List[object]'
        $script:wingetExitCodes = @(0) * 15
        Mock Install-JindaYodeck { $false }
        Mock Get-Command { [pscustomobject]@{ Source = 'Invoke-JindaFakeWinget' } } -ParameterFilter { $Name -eq 'winget.exe' }
    }

    It 'installs all packages and allows stable PowerShell upgrades with the machine MSI' {
        $result = Install-JindaSoftware
        $result | Should Be $false
        $script:wingetCalls.Count | Should Be 15
        ($script:wingetCalls[0] -contains 'Google.Chrome') | Should Be $true
        ($script:wingetCalls[1] -contains 'TeamViewer.TeamViewer') | Should Be $true
        ($script:wingetCalls[1] -contains 'nullsoft') | Should Be $true
        ($script:wingetCalls[0] -contains '--no-upgrade') | Should Be $true
        ($script:wingetCalls[1] -contains '--no-upgrade') | Should Be $true
        ($script:wingetCalls[2] -contains 'Microsoft.PowerShell') | Should Be $true
        ($script:wingetCalls[2] -contains 'Microsoft.PowerShell.Preview') | Should Be $false
        ($script:wingetCalls[2] -contains '--no-upgrade') | Should Be $false
        ($script:wingetCalls[2] -contains '--version') | Should Be $false
        ($script:wingetCalls[2] -contains 'wix') | Should Be $true
        foreach ($call in $script:wingetCalls) {
            ($call -contains '--silent') | Should Be $true
        }
    }

    It 'accepts already-installed and no-update-needed exit codes' {
        $script:wingetExitCodes = @(-1978335189, -1978335135, -1978335189) + (@(0) * 12)
        (Install-JindaSoftware) | Should Be $false
        $script:wingetCalls.Count | Should Be 15
    }

    It 'continues installing the remaining packages when the first requests a reboot' {
        $script:wingetExitCodes = @(3010) + (@(0) * 14)
        (Install-JindaSoftware) | Should Be $true
        $script:wingetCalls.Count | Should Be 15
    }

    It 'stops and reports a failed package' {
        $script:wingetExitCodes = @(1, 0, 0)
        { Install-JindaSoftware } | Should Throw 'Google Chrome: WinGet is mislukt'
        $script:wingetCalls.Count | Should Be 1
    }

    It 'reports a PowerShell installation failure after the other packages succeed' {
        $script:wingetExitCodes = @(0, 0, 1)
        { Install-JindaSoftware } | Should Throw 'PowerShell 7: WinGet is mislukt'
        $script:wingetCalls.Count | Should Be 3
    }

    It 'does not run WinGet during WhatIf' {
        (Install-JindaSoftware -WhatIf) | Should Be $false
        $script:wingetCalls.Count | Should Be 0
    }

    It 'reports missing WinGet before attempting any package' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'winget.exe' }
        { Install-JindaSoftware } | Should Throw 'WinGet ontbreekt'
        $script:wingetCalls.Count | Should Be 0
    }

    It 'includes all fifteen WinGet packages once and Yodeck once in the same run' {
        Install-JindaSoftware | Should Be $false
        $ids = @($script:wingetCalls | ForEach-Object { $_[2] })
        $expected = @('Google.Chrome','TeamViewer.TeamViewer','Microsoft.PowerShell','Microsoft.VisualStudioCode',
            'XPFFZHVGQWWLHB','Notepad++.Notepad++','Discord.Discord','Reolink.Reolink','dotPDN.PaintDotNet',
            'LastPass.LastPass','Git.Git','Zoom.Zoom','Microsoft.Teams','9NKSQGP7F2NH','VideoLAN.VLC')
        @($ids | Select-Object -Unique).Count | Should Be 15
        foreach ($id in $expected) { ($ids -contains $id) | Should Be $true }
        Assert-MockCalled Install-JindaYodeck -Times 1 -Exactly -Scope It
    }

    It 'uses Store IDs and never forces unsupported scopes' {
        Install-JindaSoftware | Out-Null
        foreach ($call in $script:wingetCalls) {
            $id = $call[2]
            if ($id -in @('XPFFZHVGQWWLHB', '9NKSQGP7F2NH')) {
                $call[[array]::IndexOf($call, '--source') + 1] | Should Be 'msstore'
            } else {
                $call[[array]::IndexOf($call, '--source') + 1] | Should Be 'winget'
            }
            if ($id -in @('XPFFZHVGQWWLHB', '9NKSQGP7F2NH', 'Reolink.Reolink', 'LastPass.LastPass')) {
                ($call -contains '--scope') | Should Be $false
            } elseif ($id -in @('Discord.Discord', 'Microsoft.Teams')) {
                $call[[array]::IndexOf($call, '--scope') + 1] | Should Be 'user'
            } else {
                $call[[array]::IndexOf($call, '--scope') + 1] | Should Be 'machine'
            }
        }
    }

    It 'propagates a Yodeck restart requirement' {
        Mock Install-JindaYodeck { $true }
        Install-JindaSoftware | Should Be $true
    }

    It 'reports a Yodeck failure after the WinGet apps finish' {
        Mock Install-JindaYodeck { throw 'Yodeck: installation failed' }
        { Install-JindaSoftware } | Should Throw 'Yodeck: installation failed'
        $script:wingetCalls.Count | Should Be 15
    }

}

Describe 'Complete installation preview' {
    It 'does not execute Yodeck side effects when the real combined flow receives WhatIf' {
        $script:wingetCalls = New-Object 'System.Collections.Generic.List[object]'
        Mock Get-Command { [pscustomobject]@{ Source = 'Invoke-JindaFakeWinget' } } -ParameterFilter { $Name -eq 'winget.exe' }
        Mock Invoke-WebRequest { throw 'Unexpected download in WhatIf' }
        Mock Start-Process { throw 'Unexpected installer in WhatIf' }
        Mock New-Item { throw 'Unexpected write in WhatIf' }
        Install-JindaSoftware -WhatIf | Should Be $false
        Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly -Scope It
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
        Assert-MockCalled New-Item -Times 0 -Exactly -Scope It
        $script:wingetCalls.Count | Should Be 0
    }
}
