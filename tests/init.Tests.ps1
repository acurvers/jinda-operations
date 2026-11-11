. (Join-Path (Split-Path -Parent $PSScriptRoot) 'init.ps1')

Describe 'Initialization orchestrates the two existing scripts' {
    BeforeEach {
        $script:initEvents = New-Object 'System.Collections.Generic.List[string]'
        $script:initLaunches = New-Object 'System.Collections.Generic.List[object]'
        $script:initExitCodes = @(0, 0)
        Mock Get-JindaSetupOptions {
            $script:initEvents.Add('choices')
            [pscustomobject]@{ InstallApps = $true; RemoteDesktop = $false; PowerShellRemoting = $false; OpenSSH = $false; LanIPAddress = '' }
        }
        Mock New-Item {}
        Mock Repair-JindaWinGet { $script:initEvents.Add('repair') }
        Mock Test-Path { $script:initEvents.Add("validate:$LiteralPath"); $true }
        Mock Invoke-WebRequest { throw 'Unexpected download' }
        Mock Write-Host {}
        Mock Get-JindaPowerShell {
            if ($script:initLaunches.Count -eq 0) { 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
            else { 'C:\Program Files\PowerShell\7\pwsh.exe' }
        }
        Mock Invoke-JindaChildProcess {
            $script:initEvents.Add("run:$ScriptPath")
            $script:initLaunches.Add([pscustomobject]@{ Executable=$Executable; Path=$ScriptPath; Arguments=$ScriptArguments; Elevate=$Elevate; NonInteractive=$NonInteractive })
            $script:initExitCodes[$script:initLaunches.Count - 1]
        }
    }

    It 'validates both bundled scripts before installing and reselects PowerShell for configuration' {
        Invoke-JindaInitialization | Should Be 0
        Assert-MockCalled Write-Host -Times 1 -Exactly -Scope It -ParameterFilter { $Object -eq 'Jinda setup completed.' }
        Assert-MockCalled Write-Host -Times 0 -Exactly -Scope It -ParameterFilter { $Object -like '*Restart Windows*' }
        $script:initEvents[0] | Should Be 'choices'
        $script:initEvents[1] | Should Match '^validate:.*install-software.ps1$'
        $script:initEvents[2] | Should Match '^validate:.*set-windows-english.ps1$'
        $script:initEvents[3] | Should Match '^validate:.*skip-apps.conf$'
        $script:initEvents[4] | Should Match '^run:.*install-software.ps1$'
        $script:initEvents[5] | Should Match '^run:.*set-windows-english.ps1$'
        $script:initLaunches[0].Executable | Should Match 'WindowsPowerShell'
        $script:initLaunches[1].Executable | Should Be 'C:\Program Files\PowerShell\7\pwsh.exe'
        ($script:initLaunches[1].Arguments -join ' ') | Should Be '-Keyboard USInternational'
        ($script:initLaunches[0].Arguments -contains '-EnableOpenSSH') | Should Be $false
        ($script:initLaunches[0].Arguments -contains '-SshPublicKey') | Should Be $false
        foreach ($launch in $script:initLaunches) {
            [bool]$launch.Elevate | Should Be $false
            [bool]$launch.NonInteractive | Should Be $true
        }
    }

    It 'passes the optional normal US keyboard to configuration' {
        Invoke-JindaInitialization -Keyboard US | Should Be 0
        ($script:initLaunches[1].Arguments -join ' ') | Should Be '-Keyboard US'
    }

    It 'does not repair WinGet unless requested' {
        Invoke-JindaInitialization | Should Be 0
        Assert-MockCalled Repair-JindaWinGet -Times 0 -Exactly -Scope It
    }

    It 'repairs after validating both scripts and before starting either child script' {
        Invoke-JindaInitialization -RepairWinGet | Should Be 0
        $script:initEvents[0] | Should Be 'choices'
        $script:initEvents[1] | Should Match '^validate:.*install-software.ps1$'
        $script:initEvents[2] | Should Match '^validate:.*set-windows-english.ps1$'
        $script:initEvents[3] | Should Match '^validate:.*skip-apps.conf$'
        $script:initEvents[4] | Should Be 'repair'
        $script:initEvents[5] | Should Match '^run:.*install-software.ps1$'
        $script:initEvents[6] | Should Match '^run:.*set-windows-english.ps1$'
        Assert-MockCalled Repair-JindaWinGet -Times 1 -Exactly -Scope It
    }

    It 'starts neither installation nor configuration when repair fails' {
        Mock Repair-JindaWinGet { throw 'Repair failed' }
        { Invoke-JindaInitialization -RepairWinGet } | Should Throw 'Repair failed'
        $script:initLaunches.Count | Should Be 0
    }

    It 'continues with configuration after a software restart requirement and preserves code 3010' {
        $script:initExitCodes = @(3010, 0)
        Invoke-JindaInitialization | Should Be 3010
        $script:initLaunches.Count | Should Be 2
        Assert-MockCalled Write-Host -Times 1 -Exactly -Scope It -ParameterFilter { $Object -eq 'Jinda setup completed. Restart Windows to apply the changes.' }
    }

    It 'does not start configuration after an installation failure' {
        $script:initExitCodes = @(1, 0)
        { Invoke-JindaInitialization } | Should Throw 'Software installation failed'
        $script:initLaunches.Count | Should Be 1
    }

    It 'reports configuration failure instead of reporting success' {
        $script:initExitCodes = @(0, 1)
        { Invoke-JindaInitialization } | Should Throw 'Windows configuration failed'
    }

    It 'never installs when the configuration script is missing from the package' {
        Mock Test-Path {
            if ($LiteralPath -like '*/set-windows-english.ps1' -or $LiteralPath -like '*\set-windows-english.ps1') { return $false }
            $script:initEvents.Add("validate:$LiteralPath")
            $true
        }
        { Invoke-JindaInitialization } | Should Throw 'Incomplete script package'
        $script:initLaunches.Count | Should Be 0
    }

    It 'does not repair or launch anything when the app skip file is missing' {
        Mock Test-Path { $LiteralPath -notlike '*skip-apps.conf' }
        { Invoke-JindaInitialization -RepairWinGet } | Should Throw 'Incomplete script package'
        $script:initLaunches.Count | Should Be 0
        Assert-MockCalled Repair-JindaWinGet -Times 0 -Exactly -Scope It
    }

    It 'has no downloads, process launches or filesystem writes during WhatIf' {
        Invoke-JindaInitialization -RepairWinGet -WhatIf | Should Be 0
        Assert-MockCalled New-Item -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-JindaChildProcess -Times 0 -Exactly -Scope It
        Assert-MockCalled Repair-JindaWinGet -Times 0 -Exactly -Scope It
        Assert-MockCalled Get-JindaSetupOptions -Times 0 -Exactly -Scope It
    }

    It 'skips installer validation, execution and repair when apps are declined' {
        Mock Get-JindaSetupOptions {
            [pscustomobject]@{ InstallApps = $false; RemoteDesktop = $true; PowerShellRemoting = $false; OpenSSH = $false; LanIPAddress = '10.20.30.40' }
        }
        Invoke-JindaInitialization -RepairWinGet | Should Be 0
        $script:initLaunches.Count | Should Be 1
        $script:initLaunches[0].Path | Should Match 'set-windows-english.ps1$'
        ($script:initLaunches[0].Arguments -join ' ') | Should Be '-Keyboard USInternational -EnableRemoteDesktop -LanIPAddress 10.20.30.40'
        [bool]$script:initLaunches[0].NonInteractive | Should Be $true
        Assert-MockCalled Test-Path -Times 0 -Exactly -Scope It -ParameterFilter { $LiteralPath -like '*install-software.ps1' }
        Assert-MockCalled Test-Path -Times 0 -Exactly -Scope It -ParameterFilter { $LiteralPath -like '*skip-apps.conf' }
        Assert-MockCalled Repair-JindaWinGet -Times 0 -Exactly -Scope It
    }

    It 'can enable only SSH without app installation or WinGet repair' {
        Mock Get-JindaSetupOptions {
            [pscustomobject]@{ InstallApps = $false; RemoteDesktop = $false; PowerShellRemoting = $false; OpenSSH = $true; LanIPAddress = '10.20.30.40' }
        }
        Invoke-JindaInitialization -RepairWinGet | Should Be 0
        $script:initLaunches.Count | Should Be 2
        $script:initLaunches[0].Path | Should Match 'install-software.ps1$'
        ($script:initLaunches[0].Arguments -join ' ') |
            Should Match '^-EnableOpenSSH -LanIPAddress 10\.20\.30\.40 -SshPublicKey ssh-ed25519 [A-Za-z0-9+/]{68} salon-oss-admin -SkipApps$'
        ($script:initLaunches[1].Arguments -join ' ') | Should Be '-Keyboard USInternational'
        Assert-MockCalled Repair-JindaWinGet -Times 0 -Exactly -Scope It
        Assert-MockCalled Test-Path -Times 1 -Exactly -Scope It -ParameterFilter { $LiteralPath -like '*skip-apps.conf' }
    }

    It 'passes SSH opt-in to the installer alongside ordinary apps' {
        Mock Get-JindaSetupOptions {
            [pscustomobject]@{ InstallApps = $true; RemoteDesktop = $false; PowerShellRemoting = $false; OpenSSH = $true; LanIPAddress = '10.20.30.40' }
        }
        Invoke-JindaInitialization | Should Be 0
        ($script:initLaunches[0].Arguments -join ' ') |
            Should Match '^-EnableOpenSSH -LanIPAddress 10\.20\.30\.40 -SshPublicKey ssh-ed25519 [A-Za-z0-9+/]{68} salon-oss-admin$'
    }

    It 'uses an explicitly supplied key in place of the salon key' {
        Mock Get-JindaSetupOptions {
            [pscustomobject]@{ InstallApps = $false; RemoteDesktop = $false; PowerShellRemoting = $false; OpenSSH = $true; LanIPAddress = '10.20.30.40' }
        }
        $publicKey = 'ssh-ed25519 example-key salon pc'
        Invoke-JindaInitialization -SshPublicKey $publicKey | Should Be 0
        $script:initLaunches[0].Arguments[3] | Should Be '-SshPublicKey'
        $script:initLaunches[0].Arguments[4] | Should Be $publicKey
    }

    It 'rejects a missing installer before an SSH-only run' {
        Mock Get-JindaSetupOptions {
            [pscustomobject]@{ InstallApps = $false; RemoteDesktop = $false; PowerShellRemoting = $false; OpenSSH = $true; LanIPAddress = '' }
        }
        Mock Test-Path { $LiteralPath -notlike '*install-software.ps1' }
        { Invoke-JindaInitialization } | Should Throw 'Incomplete script package'
        $script:initLaunches.Count | Should Be 0
    }

    It 'passes both remote choices and the selected LAN to configuration' {
        Mock Get-JindaSetupOptions {
            [pscustomobject]@{ InstallApps = $true; RemoteDesktop = $true; PowerShellRemoting = $true; OpenSSH = $false; LanIPAddress = '10.20.30.40' }
        }
        Invoke-JindaInitialization | Should Be 0
        ($script:initLaunches[1].Arguments -join ' ') | Should Be '-Keyboard USInternational -EnableRemoteDesktop -EnableWinRM -LanIPAddress 10.20.30.40'
    }

    It 'does not download or start anything when initial choices cannot be resolved' {
        Mock Get-JindaSetupOptions { throw 'No LAN available' }
        { Invoke-JindaInitialization } | Should Throw 'No LAN available'
        Assert-MockCalled New-Item -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly -Scope It
        $script:initLaunches.Count | Should Be 0
    }
}

# Exercise the actual entry-point statements without terminating the test host.
$initAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSScriptRoot) 'init.ps1'), [ref]$null, [ref]$null)
$entryTry = $initAst.EndBlock.Statements[-1].Clauses[0].Item2.Statements[0]
$entryBody = ($entryTry.Body.Statements | Where-Object { $_ -isnot [Management.Automation.Language.ExitStatementAst] } | ForEach-Object { $_.Extent.Text }) -join "`n"
# An anonymous scriptblock has no PSCommandPath; supply the path a real file has.
$script:initEntry = [scriptblock]::Create($entryBody.Replace('$PSCommandPath', "'C:\Test Folder\init.ps1'"))

Describe 'Initialization entry point forwards the repair switch' {
    BeforeEach {
        Mock Get-JindaPowerShell { 'C:\Program Files\PowerShell\7\pwsh.exe' }
        Mock Get-JindaCurrentPowerShell { 'C:\Program Files\PowerShell\7\pwsh.exe' }
        Mock Test-JindaAdministrator { $true }
        Mock Invoke-JindaChildProcess { 0 }
        Mock New-Item {}
        Mock Start-Transcript {}
        Mock Stop-Transcript {}
        Mock Invoke-JindaInitialization { 0 }
    }

    It 'keeps the switch through an administrator relaunch' {
        Mock Test-JindaAdministrator { $false }
        $RepairWinGet = $true
        $Keyboard = 'US'
        $InstallApps = 'No'
        $RemoteDesktop = 'Yes'
        $PowerShellRemoting = 'No'
        $OpenSSH = 'Yes'
        $LanIPAddress = '10.20.30.40'
        & $script:initEntry
        Assert-MockCalled Invoke-JindaChildProcess -Times 1 -Exactly -Scope It -ParameterFilter {
            $Elevate -and $ScriptArguments -contains '-RepairWinGet' -and
            $ScriptArguments -contains '-RuntimeReady' -and $ScriptArguments -contains 'US' -and
            ($ScriptArguments -join ' ') -match '-InstallApps No -RemoteDesktop Yes -PowerShellRemoting No' -and
            ($ScriptArguments -join ' ') -match '-OpenSSH Yes' -and
            $ScriptArguments -contains '10.20.30.40'
        }
        Assert-MockCalled Invoke-JindaInitialization -Times 0 -Exactly -Scope It
    }

    It 'keeps the switch through a PowerShell runtime change' {
        Mock Get-JindaCurrentPowerShell { 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
        $RepairWinGet = $true
        $OpenSSH = 'No'
        & $script:initEntry
        Assert-MockCalled Invoke-JindaChildProcess -Times 1 -Exactly -Scope It -ParameterFilter {
            -not $Elevate -and $ScriptArguments -contains '-RepairWinGet' -and
            ($ScriptArguments -join ' ') -match '-OpenSSH No'
        }
    }

    It 'passes the switch into initialization once already elevated' {
        $RepairWinGet = $true
        $OpenSSH = 'Yes'
        & $script:initEntry
        Assert-MockCalled Invoke-JindaInitialization -Times 1 -Exactly -Scope It -ParameterFilter { $RepairWinGet -and $OpenSSH -eq 'Yes' }
    }
}
