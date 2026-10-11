. (Join-Path (Split-Path -Parent $PSScriptRoot) 'init.ps1')

Describe 'Initialization orchestrates the two existing scripts' {
    BeforeEach {
        $script:initEvents = New-Object 'System.Collections.Generic.List[string]'
        $script:initLaunches = New-Object 'System.Collections.Generic.List[object]'
        $script:initExitCodes = @(0, 0)
        Mock New-Item {}
        Mock Invoke-WebRequest { $script:initEvents.Add("download:$Uri") }
        Mock Get-JindaPowerShell {
            if ($script:initLaunches.Count -eq 0) { 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
            else { 'C:\Program Files\PowerShell\7\pwsh.exe' }
        }
        Mock Invoke-JindaChildProcess {
            $script:initEvents.Add("run:$ScriptPath")
            $script:initLaunches.Add([pscustomobject]@{ Executable=$Executable; Path=$ScriptPath; Arguments=$ScriptArguments; Elevate=$Elevate })
            $script:initExitCodes[$script:initLaunches.Count - 1]
        }
    }

    It 'downloads both scripts before installing and reselects PowerShell for configuration' {
        Invoke-JindaInitialization | Should Be 0
        $script:initEvents[0] | Should Match '^download:.*install-software.ps1$'
        $script:initEvents[1] | Should Match '^download:.*set-windows-english.ps1$'
        $script:initEvents[2] | Should Match '^run:.*install-software.ps1$'
        $script:initEvents[3] | Should Match '^run:.*set-windows-english.ps1$'
        $script:initLaunches[0].Executable | Should Match 'WindowsPowerShell'
        $script:initLaunches[1].Executable | Should Be 'C:\Program Files\PowerShell\7\pwsh.exe'
        ($script:initLaunches[1].Arguments -join ' ') | Should Be '-Keyboard USInternational'
        foreach ($launch in $script:initLaunches) { [bool]$launch.Elevate | Should Be $false }
    }

    It 'passes the optional normal US keyboard to configuration' {
        Invoke-JindaInitialization -Keyboard US | Should Be 0
        ($script:initLaunches[1].Arguments -join ' ') | Should Be '-Keyboard US'
    }

    It 'continues with configuration after a software restart requirement and preserves code 3010' {
        $script:initExitCodes = @(3010, 0)
        Invoke-JindaInitialization | Should Be 3010
        $script:initLaunches.Count | Should Be 2
    }

    It 'does not start configuration after an installation failure' {
        $script:initExitCodes = @(1, 0)
        { Invoke-JindaInitialization } | Should Throw 'Software-installatie mislukt'
        $script:initLaunches.Count | Should Be 1
    }

    It 'reports configuration failure instead of reporting success' {
        $script:initExitCodes = @(0, 1)
        { Invoke-JindaInitialization } | Should Throw 'Windows-configuratie mislukt'
    }

    It 'never installs when downloading either script fails' {
        Mock Invoke-WebRequest { throw 'Download failed' } -ParameterFilter { $Uri -like '*/set-windows-english.ps1' }
        { Invoke-JindaInitialization } | Should Throw 'Download failed'
        $script:initLaunches.Count | Should Be 0
    }

    It 'has no downloads, process launches or filesystem writes during WhatIf' {
        Invoke-JindaInitialization -WhatIf | Should Be 0
        Assert-MockCalled New-Item -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-JindaChildProcess -Times 0 -Exactly -Scope It
    }
}
