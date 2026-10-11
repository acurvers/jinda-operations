. (Join-Path (Split-Path -Parent $PSScriptRoot) 'install-software.ps1')

function Invoke-JindaFakeWinget {
    $script:wingetCalls.Add(@($args))
    $global:LASTEXITCODE = $script:wingetExitCodes[$script:wingetCalls.Count - 1]
    Write-Output 'Simulated WinGet output'
}

Describe 'Chrome, TeamViewer and PowerShell installation' {
    BeforeEach {
        $script:wingetCalls = New-Object 'System.Collections.Generic.List[object]'
        $script:wingetExitCodes = @(0, 0, 0)
        Mock Get-Command { [pscustomobject]@{ Source = 'Invoke-JindaFakeWinget' } } -ParameterFilter { $Name -eq 'winget.exe' }
    }

    It 'installs all packages and allows stable PowerShell upgrades with the machine MSI' {
        $result = Install-JindaSoftware
        $result | Should Be $false
        $script:wingetCalls.Count | Should Be 3
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
            ($call -contains 'machine') | Should Be $true
        }
    }

    It 'accepts already-installed and no-update-needed exit codes' {
        $script:wingetExitCodes = @(-1978335189, -1978335135, -1978335189)
        (Install-JindaSoftware) | Should Be $false
        $script:wingetCalls.Count | Should Be 3
    }

    It 'continues installing the remaining packages when the first requests a reboot' {
        $script:wingetExitCodes = @(3010, 0, 0)
        (Install-JindaSoftware) | Should Be $true
        $script:wingetCalls.Count | Should Be 3
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
}
