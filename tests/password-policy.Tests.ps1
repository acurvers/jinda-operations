. (Join-Path (Split-Path -Parent $PSScriptRoot) 'set-windows-english.ps1')

function Invoke-JindaFakeAccountNet {
    $script:accountPolicyCalls.Add(@($args))
    $global:LASTEXITCODE = if ($args.Count -gt 1) { $script:policySetExitCode } else { $script:policyQueryExitCode }
    Write-Output 'Simulated local account policy output'
}

Describe 'Local Windows password expiration policy' {
    BeforeEach {
        $script:accountPolicyCalls = New-Object 'System.Collections.Generic.List[object]'
        $script:policySetExitCode = 0
        $script:policyQueryExitCode = 0
        Mock Test-JindaAdministrator { $true }
        Mock Get-Command { [pscustomobject]@{ Source = 'Invoke-JindaFakeAccountNet' } } -ParameterFilter { $Name -eq 'net.exe' }
    }

    It 'changes only local maximum password age and then displays the policy' {
        Set-JindaLocalPasswordAgePolicy
        $script:accountPolicyCalls.Count | Should Be 2
        ($script:accountPolicyCalls[0] -join ' ') | Should Be 'accounts /maxpwage:unlimited'
        ($script:accountPolicyCalls[1] -join ' ') | Should Be 'accounts'
    }

    It 'does not change or query policy for WhatIf' {
        Set-JindaLocalPasswordAgePolicy -WhatIf
        $script:accountPolicyCalls.Count | Should Be 0
        Assert-MockCalled Get-Command -Times 0 -Exactly -Scope It -ParameterFilter { $Name -eq 'net.exe' }
    }

    It 'requires administrator rights before any policy command' {
        Mock Test-JindaAdministrator { $false }
        { Set-JindaLocalPasswordAgePolicy } | Should Throw 'requires administrator privileges'
        $script:accountPolicyCalls.Count | Should Be 0
    }

    It 'reports a failed policy update and does not continue with a misleading query' {
        $script:policySetExitCode = 5
        { Set-JindaLocalPasswordAgePolicy } | Should Throw 'Could not disable local password expiration'
        $script:accountPolicyCalls.Count | Should Be 1
    }

    It 'reports separately when reading back the policy fails after an accepted change' {
        $script:policyQueryExitCode = 2
        { Set-JindaLocalPasswordAgePolicy } | Should Throw 'Password policy was applied, but displaying the current policy failed'
        $script:accountPolicyCalls.Count | Should Be 2
    }
}
