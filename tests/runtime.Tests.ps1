$projectPath = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectPath 'set-windows-english.ps1')

Describe 'Administrator and runtime selection' {
    BeforeEach {
        Mock Get-JindaPowerShell { 'C:\Program Files\PowerShell\7\pwsh.exe' }
        Mock Get-JindaCurrentPowerShell { 'C:\Program Files\PowerShell\7\pwsh.exe' }
        Mock Test-JindaAdministrator { $true }
        Mock Invoke-JindaChildProcess { 0 }
        Mock New-Item {}
        Mock Start-Transcript {}
        Mock Stop-Transcript {}
        $script:workRan = $false
    }

    It 'requests UAC and forwards keyboard, runtime marker and restart exit code' {
        Mock Test-JindaAdministrator { $false }
        Mock Invoke-JindaChildProcess { 3010 }
        $result = Invoke-JindaManagedScript -ScriptPath 'C:\Test Folder\config.ps1' -ScriptArguments @('-Keyboard', 'USInternational') -Work { $script:workRan = $true; 0 }
        $result | Should Be 3010
        $script:workRan | Should Be $false
        Assert-MockCalled Invoke-JindaChildProcess -Times 1 -Exactly -Scope It -ParameterFilter {
            $Elevate -and $Executable -eq 'C:\Program Files\PowerShell\7\pwsh.exe' -and
            $ScriptPath -eq 'C:\Test Folder\config.ps1' -and
            $ScriptArguments -contains '-RuntimeReady' -and $ScriptArguments -contains 'USInternational'
        }
    }

    It 'switches an already elevated process to the selected runtime without UAC' {
        Mock Get-JindaCurrentPowerShell { 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
        Invoke-JindaManagedScript -ScriptPath 'C:\install.ps1' -Work { $script:workRan = $true; 0 } | Should Be 0
        $script:workRan | Should Be $false
        Assert-MockCalled Invoke-JindaChildProcess -Times 1 -Exactly -Scope It -ParameterFilter { -not $Elevate }
    }

    It 'executes work once when runtime and administrator rights are already correct' {
        Invoke-JindaManagedScript -ScriptPath 'C:\install.ps1' -RuntimeReady -Work { $script:workRan = $true; 3010 } | Should Be 3010
        $script:workRan | Should Be $true
        Assert-MockCalled Invoke-JindaChildProcess -Times 0 -Exactly -Scope It
        Assert-MockCalled Start-Transcript -Times 1 -Exactly -Scope It
        Assert-MockCalled Stop-Transcript -Times 1 -Exactly -Scope It
    }

    It 'does not repeatedly request UAC if relaunch failed to acquire rights' {
        Mock Test-JindaAdministrator { $false }
        { Invoke-JindaManagedScript -ScriptPath 'C:\install.ps1' -RuntimeReady -Work { $script:workRan = $true; 0 } } | Should Throw 'vereiste beheerrechten'
        $script:workRan | Should Be $false
        Assert-MockCalled Invoke-JindaChildProcess -Times 0 -Exactly -Scope It
    }

    It 'does not elevate, create logs or execute work for WhatIf' {
        Mock Test-JindaAdministrator { $false }
        Invoke-JindaManagedScript -ScriptPath 'C:\install.ps1' -WhatIf -Work { $script:workRan = $true; 0 } | Should Be 0
        $script:workRan | Should Be $false
        Assert-MockCalled Invoke-JindaChildProcess -Times 0 -Exactly -Scope It
        Assert-MockCalled New-Item -Times 0 -Exactly -Scope It
        Assert-MockCalled Get-JindaPowerShell -Times 0 -Exactly -Scope It
    }

    It 'turns a work failure into exit code one and closes the log' {
        Invoke-JindaManagedScript -ScriptPath 'C:\config.ps1' -Work { throw 'Simulated configuration failure' } | Should Be 1
        Assert-MockCalled Stop-Transcript -Times 1 -Exactly -Scope It
    }
}

Describe 'Runtime discovery and Windows language compatibility' {
    BeforeEach {
        Mock Get-JindaPowerShellCandidates {
            [pscustomobject]@{ Path = 'C:\PowerShell\old\pwsh.exe'; Version = [version]'7.4.1' }
            [pscustomobject]@{ Path = 'C:\PowerShell\latest\pwsh.exe'; Version = [version]'7.10.1' }
            [pscustomobject]@{ Path = 'C:\PowerShell\other\pwsh.exe'; Version = [version]'7.9.9' }
        }
        Mock Get-JindaWindowsPowerShell { 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
        Mock Invoke-JindaChildProcess { 0 }
        Mock Set-JindaWindowsEnglish {}
    }

    It 'selects the highest installed version numerically rather than the first PATH entry' {
        Get-JindaPowerShell | Should Be 'C:\PowerShell\latest\pwsh.exe'
    }

    It 'falls back to Windows PowerShell when no suitable stable version is installed' {
        Mock Get-JindaPowerShellCandidates {}
        Get-JindaPowerShell | Should Be 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    }

    It 'keeps the language worker on Windows PowerShell even when version 7 is installed' {
        Get-JindaPowerShell -WindowsPowerShell | Should Be 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        Assert-MockCalled Get-JindaPowerShellCandidates -Times 0 -Exactly -Scope It
    }

    It 'runs native language commands locally in 5.1 or delegates from PowerShell 7 without UAC' {
        Invoke-JindaConfiguration -ScriptPath 'C:\config.ps1' -Keyboard USInternational | Should Be 0
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            Assert-MockCalled Set-JindaWindowsEnglish -Times 1 -Exactly -Scope It -ParameterFilter { $Keyboard -eq 'USInternational' }
            Assert-MockCalled Invoke-JindaChildProcess -Times 0 -Exactly -Scope It
        } else {
            Assert-MockCalled Set-JindaWindowsEnglish -Times 0 -Exactly -Scope It
            Assert-MockCalled Invoke-JindaChildProcess -Times 1 -Exactly -Scope It -ParameterFilter {
                -not $Elevate -and $Executable -like '*WindowsPowerShell*' -and
                $ScriptArguments -contains '-WindowsLanguageWorker' -and
                $ScriptArguments -contains '-RuntimeReady' -and $ScriptArguments -contains 'USInternational'
            }
        }
    }
}

Describe 'Starting an elevated child safely' {
    BeforeEach {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 3010 } }
    }

    It 'quotes paths with spaces, waits for UAC completion and preserves the exit code' {
        $result = Invoke-JindaChildProcess -Executable 'C:\Program Files\PowerShell\7\pwsh.exe' -ScriptPath "C:\Test Folder\Alex's config.ps1" -ScriptArguments @('-Keyboard', 'USInternational', '-RuntimeReady') -Elevate
        $result | Should Be 3010
        Assert-MockCalled Start-Process -Times 1 -Exactly -Scope It -ParameterFilter {
            $Verb -eq 'RunAs' -and $Wait -and $PassThru -and
            $ArgumentList -like '*"C:\Test Folder\Alex''s config.ps1"*' -and
            $ArgumentList -like '*"-Keyboard" "USInternational" "-RuntimeReady"*'
        }
    }

    It 'reports rejected UAC and never starts a second process' {
        Mock Start-Process { throw 'The operation was canceled by the user' }
        { Invoke-JindaChildProcess -Executable 'C:\pwsh.exe' -ScriptPath 'C:\config.ps1' -Elevate } | Should Throw 'Accepteer de Windows UAC-vraag'
        Assert-MockCalled Start-Process -Times 1 -Exactly -Scope It
    }

    It 'keeps both self-contained entry scripts on identical runtime code' {
        $pattern = '(?s)# BEGIN shared runtime.*?# END shared runtime\.'
        $install = [regex]::Match([IO.File]::ReadAllText((Join-Path $projectPath 'install-software.ps1')), $pattern).Value
        $config = [regex]::Match([IO.File]::ReadAllText((Join-Path $projectPath 'set-windows-english.ps1')), $pattern).Value
        $install.Length | Should BeGreaterThan 100
        $install | Should Be $config
    }
}