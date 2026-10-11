. (Join-Path (Split-Path -Parent $PSScriptRoot) 'install-software.ps1')

function Invoke-JindaFakeWinget {
    $script:wingetCalls.Add(@($args))
    $global:LASTEXITCODE = $script:wingetExitCodes[$script:wingetCalls.Count - 1]
    Write-Output 'Simulated WinGet output'
}

Describe 'Chrome and TeamViewer installation' {
    BeforeEach {
        $script:wingetCalls = New-Object 'System.Collections.Generic.List[object]'
        $script:wingetExitCodes = @(0, 0)
        Mock Get-Command { [pscustomobject]@{ Source = 'Invoke-JindaFakeWinget' } } -ParameterFilter { $Name -eq 'winget.exe' }
    }

    It 'installs both packages with the full TeamViewer EXE and reports no reboot on success' {
        $result = Install-JindaSoftware
        $result | Should Be $false
        $script:wingetCalls.Count | Should Be 2
        ($script:wingetCalls[0] -contains 'Google.Chrome') | Should Be $true
        ($script:wingetCalls[1] -contains 'TeamViewer.TeamViewer') | Should Be $true
        ($script:wingetCalls[1] -contains 'nullsoft') | Should Be $true
        foreach ($call in $script:wingetCalls) {
            ($call -contains '--no-upgrade') | Should Be $true
            ($call -contains '--silent') | Should Be $true
            ($call -contains 'machine') | Should Be $true
        }
    }

    It 'accepts already-installed exit codes for both packages' {
        $script:wingetExitCodes = @(-1978335189, -1978335135)
        (Install-JindaSoftware) | Should Be $false
        $script:wingetCalls.Count | Should Be 2
    }

    It 'continues installing the second package when the first requests a reboot' {
        $script:wingetExitCodes = @(3010, 0)
        (Install-JindaSoftware) | Should Be $true
        $script:wingetCalls.Count | Should Be 2
    }

    It 'stops and reports a failed package' {
        $script:wingetExitCodes = @(1, 0)
        { Install-JindaSoftware } | Should Throw 'Google Chrome: WinGet is mislukt'
        $script:wingetCalls.Count | Should Be 1
    }

    It 'does not run WinGet during WhatIf' {
        (Install-JindaSoftware -WhatIf) | Should Be $false
        $script:wingetCalls.Count | Should Be 0
    }

    It 'reports missing WinGet before attempting either package' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'winget.exe' }
        { Install-JindaSoftware } | Should Throw 'WinGet ontbreekt'
        $script:wingetCalls.Count | Should Be 0
    }
}
