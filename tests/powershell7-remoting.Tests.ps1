. (Join-Path (Split-Path -Parent $PSScriptRoot) 'set-windows-english.ps1')

function Invoke-JindaFakeRemotingRuntime {
    $script:runtimeCalls.Add(@($args))
    $global:LASTEXITCODE = $script:runtimeExitCode
}

Describe 'Selecting the installed PowerShell 7 remoting runtime' {
    It 'chooses the newest version 7 from the existing stable native runtime discovery' {
        Mock Get-JindaPowerShellCandidates {
            [pscustomobject]@{ Path = 'C:\PowerShell\7.4\pwsh.exe'; Version = [version]'7.4.1' }
            [pscustomobject]@{ Path = 'C:\PowerShell\8\pwsh.exe'; Version = [version]'8.0.0' }
            [pscustomobject]@{ Path = 'C:\PowerShell\7\pwsh.exe'; Version = [version]'7.6.9' }
        }
        (Get-JindaPowerShell7RemotingRuntime).Path | Should Be 'C:\PowerShell\7\pwsh.exe'
    }

    It 'reports a missing version 7 without silently choosing Windows PowerShell' {
        Mock Get-JindaPowerShellCandidates {}
        { Get-JindaPowerShell7RemotingRuntime } | Should Throw 'Choose app installation first'
    }
}

Describe 'Launching the native PowerShell 7 worker without system changes in tests' {
    BeforeEach {
        $script:runtimeCalls = New-Object 'System.Collections.Generic.List[object]'
        $script:runtimeExitCode = 0
    }

    It 'passes a valid self-contained noninteractive command to the selected runtime' {
        Invoke-JindaPowerShell7Remoting -Executable 'Invoke-JindaFakeRemotingRuntime'
        $script:runtimeCalls.Count | Should Be 1
        $call = $script:runtimeCalls[0]
        ($call -contains '-NoProfile') | Should Be $true
        ($call -contains '-NonInteractive') | Should Be $true
        $encoded = $call[[array]::IndexOf($call, '-EncodedCommand') + 1]
        $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
        $tokens = $null
        $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseInput($command, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should Be 0
        $command | Should Match 'Enable-PSRemoting'
        $command | Should Match 'PowerShell\.7'
    }

    It 'propagates a worker failure instead of reporting successful configuration' {
        $script:runtimeExitCode = 1
        { Invoke-JindaPowerShell7Remoting -Executable 'Invoke-JindaFakeRemotingRuntime' } | Should Throw 'configuration failed'
    }

    It 'does not start the worker for WhatIf' {
        Invoke-JindaPowerShell7Remoting -Executable 'Invoke-JindaFakeRemotingRuntime' -WhatIf
        $script:runtimeCalls.Count | Should Be 0
    }
}

if ($PSVersionTable.PSEdition -eq 'Core') {
    Describe 'PowerShell 7 endpoint registration with all changes mocked' {
        BeforeEach {
            $script:endpointVersion = [version]('{0}.{1}' -f $PSVersionTable.PSVersion.Major, $PSVersionTable.PSVersion.Minor)
            $script:expectedPlugin = 'C:\Windows\System32\PowerShell\' + $PSVersionTable.PSVersion.ToString() + '\pwrshplugin.dll'
            $script:endpointPlugin = $script:expectedPlugin
            $script:endpointEnabled = $true
            $script:endpointSddl = 'O:BAG:BAD:P(A;;GA;;;BA)'
            Mock Enable-PSRemoting {}
            Mock Get-PSSessionConfiguration {
                [pscustomobject]@{ Name = 'PowerShell.7'; PSVersion = $script:endpointVersion; Enabled = $script:endpointEnabled; SecurityDescriptorSddl = $script:endpointSddl }
            }
            Mock Get-WSManInstance {
                if ($SelectorSet.Name -eq 'PowerShell.7') { [pscustomobject]@{ Filename = $script:endpointPlugin } }
                else { [pscustomobject]@{ Filename = $script:expectedPlugin } }
            }
            Mock Register-PSSessionConfiguration {
                $script:endpointVersion = [version]('{0}.{1}' -f $PSVersionTable.PSVersion.Major, $PSVersionTable.PSVersion.Minor)
                $script:endpointPlugin = $script:expectedPlugin
            }
        }

        It 'enables and verifies an already-current endpoint without replacing its configuration' {
            Enable-JindaPowerShell7Endpoint
            Assert-MockCalled Enable-PSRemoting -Times 1 -Exactly -Scope It -ParameterFilter { $Force -and $SkipNetworkProfileCheck -and -not $Confirm }
            Assert-MockCalled Get-PSSessionConfiguration -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'PowerShell.7' }
            Assert-MockCalled Register-PSSessionConfiguration -Times 0 -Exactly -Scope It
        }

        It 'refreshes an older PowerShell.7 endpoint and preserves its access permissions' {
            $script:endpointVersion = [version]'7.0.0'
            $script:endpointPlugin = 'C:\Windows\System32\PowerShell\7.0.0\pwrshplugin.dll'
            Enable-JindaPowerShell7Endpoint
            Assert-MockCalled Register-PSSessionConfiguration -Times 1 -Exactly -Scope It -ParameterFilter {
                $Name -eq 'PowerShell.7' -and $Force -and -not $Confirm -and $SecurityDescriptorSddl -eq $script:endpointSddl
            }
            Assert-MockCalled Get-PSSessionConfiguration -Times 2 -Exactly -Scope It
        }

        It 'refreshes an older patch even when the endpoint metadata reports the same major and minor version' {
            $script:endpointPlugin = 'C:\Windows\System32\PowerShell\older-patch\pwrshplugin.dll'
            Enable-JindaPowerShell7Endpoint
            Assert-MockCalled Register-PSSessionConfiguration -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'PowerShell.7' }
        }

        It 'does not replace an older endpoint when its access permissions cannot be preserved' {
            $script:endpointVersion = [version]'7.0.0'
            $script:endpointPlugin = 'C:\Windows\System32\PowerShell\7.0.0\pwrshplugin.dll'
            $script:endpointSddl = ''
            { Enable-JindaPowerShell7Endpoint } | Should Throw 'Cannot preserve'
            Assert-MockCalled Register-PSSessionConfiguration -Times 0 -Exactly -Scope It
        }

        It 'fails verification if registration still points to an older PowerShell version' {
            $script:endpointVersion = [version]'7.0.0'
            $script:endpointPlugin = 'C:\Windows\System32\PowerShell\7.0.0\pwrshplugin.dll'
            Mock Register-PSSessionConfiguration {}
            { Enable-JindaPowerShell7Endpoint } | Should Throw 'verification failed'
        }

        It 'does not report success for a disabled endpoint' {
            $script:endpointEnabled = $false
            { Enable-JindaPowerShell7Endpoint } | Should Throw 'verification failed'
        }

        It 'makes no changes for WhatIf' {
            Enable-JindaPowerShell7Endpoint -WhatIf
            Assert-MockCalled Enable-PSRemoting -Times 0 -Exactly -Scope It
            Assert-MockCalled Register-PSSessionConfiguration -Times 0 -Exactly -Scope It
        }
    }
}
else {
    Describe 'Rejecting the wrong endpoint-worker runtime' {
        It 'refuses to configure PowerShell 7 from Windows PowerShell 5.1' {
            Mock Enable-PSRemoting { throw 'Wrong runtime must not enable remoting' }
            { Enable-JindaPowerShell7Endpoint } | Should Throw 'must run in stable PowerShell 7'
            Assert-MockCalled Enable-PSRemoting -Times 0 -Exactly -Scope It
        }
    }
}
