. (Join-Path (Split-Path -Parent $PSScriptRoot) 'install-software.ps1')

function Invoke-JindaFakeWinget {
    $script:wingetSequence.Add($args[0])
    if ($args[0] -eq 'upgrade') {
        $script:wingetUpgradeCalls.Add(@($args))
        $global:LASTEXITCODE = $script:wingetUpgradeExitCode
        Write-Output 'Simulated WinGet self-update output'
        return
    }
    $script:wingetCalls.Add(@($args))
    $script:appOrder.Add($args[2])
    if ($script:throwChrome -and $args -contains 'Google.Chrome') { throw 'Simulated Chrome process error' }
    $global:LASTEXITCODE = $script:wingetExitCodes[$script:wingetCalls.Count - 1]
    Write-Output 'Simulated WinGet output'
}

function Invoke-JindaUpdatedFakeWinget {
    $script:updatedWingetUsed = $true
    Invoke-JindaFakeWinget @args
}

Describe 'All requested Jinda applications' {
    BeforeEach {
        $script:wingetCalls = New-Object 'System.Collections.Generic.List[object]'
        $script:wingetUpgradeCalls = New-Object 'System.Collections.Generic.List[object]'
        $script:wingetSequence = New-Object 'System.Collections.Generic.List[string]'
        $script:appOrder = New-Object 'System.Collections.Generic.List[string]'
        $script:wingetUpgradeExitCode = 0
        $script:wingetExitCodes = @(0) * 20
        $script:throwChrome = $false
        Mock Get-JindaSkippedApps { @() }
        Mock Install-JindaYodeck { $script:appOrder.Add('Yodeck'); $false }
        Mock Install-JindaOpenSSH { $false }
        Mock Install-JindaVSCodePowerShellExtension {}
        Mock Get-Command { [pscustomobject]@{ Source = 'Invoke-JindaFakeWinget' } } -ParameterFilter { $Name -eq 'winget.exe' }
    }

    It 'updates only WinGet before the apps without prompts, forced upgrades or reboots' {
        Install-JindaSoftware | Should Be $false
        $script:wingetSequence[0] | Should Be 'upgrade'
        $script:wingetSequence[1] | Should Be 'install'
        $script:wingetUpgradeCalls.Count | Should Be 1
        $call = $script:wingetUpgradeCalls[0]
        $call[[array]::IndexOf($call, '--id') + 1] | Should Be 'Microsoft.AppInstaller'
        $call[[array]::IndexOf($call, '--source') + 1] | Should Be 'winget'
        foreach ($flag in @('--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')) {
            ($call -contains $flag) | Should Be $true
        }
        foreach ($flag in @('--all', '--force', '--allow-reboot', '--include-unknown')) {
            ($call -contains $flag) | Should Be $false
        }
        $script:wingetCalls.Count | Should Be 20
    }

    It 'continues when WinGet itself has no newer version' {
        $script:wingetUpgradeExitCode = -1978335189
        Install-JindaSoftware | Should Be $false
        $script:wingetCalls.Count | Should Be 20
    }

    It 'stops before all apps when the WinGet self-update fails' {
        $script:wingetUpgradeExitCode = -1978335217
        { Install-JindaSoftware } | Should Throw 'WinGet self-update failed'
        $script:wingetCalls.Count | Should Be 0
        Assert-MockCalled Install-JindaYodeck -Times 0 -Exactly -Scope It
        Assert-MockCalled Install-JindaVSCodePowerShellExtension -Times 0 -Exactly -Scope It
    }

    It 'preserves a WinGet update restart requirement while installing the apps' {
        $script:wingetUpgradeExitCode = 3010
        Install-JindaSoftware | Should Be $true
        $script:wingetCalls.Count | Should Be 20
    }

    It 'uses the newly resolved WinGet executable for the apps after updating' {
        $script:wingetResolutions = 0
        $script:updatedWingetUsed = $false
        Mock Get-Command {
            $script:wingetResolutions++
            $path = if ($script:wingetResolutions -eq 1) { 'Invoke-JindaFakeWinget' } else { 'Invoke-JindaUpdatedFakeWinget' }
            [pscustomobject]@{ Source = $path }
        } -ParameterFilter { $Name -eq 'winget.exe' }
        Install-JindaSoftware | Should Be $false
        $script:updatedWingetUsed | Should Be $true
        $script:wingetResolutions | Should Be 2
        $script:wingetCalls.Count | Should Be 20
    }

    It 'stops if WinGet disappears after updating instead of using the old executable' {
        $script:wingetResolutions = 0
        Mock Get-Command {
            $script:wingetResolutions++
            if ($script:wingetResolutions -eq 1) { [pscustomobject]@{ Source = 'Invoke-JindaFakeWinget' } }
        } -ParameterFilter { $Name -eq 'winget.exe' }
        { Install-JindaSoftware } | Should Throw 'WinGet was not found after its update'
        $script:wingetCalls.Count | Should Be 0
    }

    It 'allows upgrades for every package and keeps the stable PowerShell machine MSI' {
        $result = Install-JindaSoftware
        $result | Should Be $false
        $script:wingetCalls.Count | Should Be 20
        ($script:wingetCalls[0] -contains 'Google.Chrome') | Should Be $true
        ($script:wingetCalls[1] -contains 'TeamViewer.TeamViewer') | Should Be $true
        ($script:wingetCalls[1] -contains 'nullsoft') | Should Be $true
        ($script:wingetCalls[2] -contains 'Microsoft.PowerShell') | Should Be $true
        ($script:wingetCalls[2] -contains 'Microsoft.PowerShell.Preview') | Should Be $false
        ($script:wingetCalls[2] -contains '--version') | Should Be $false
        ($script:wingetCalls[2] -contains 'wix') | Should Be $true
        foreach ($call in $script:wingetCalls) {
            ($call -contains '--silent') | Should Be $true
            ($call -contains '--no-upgrade') | Should Be $false
        }
    }

    It 'accepts already-installed and no-update-needed exit codes' {
        $script:wingetExitCodes = @(-1978335189, -1978335135, -1978335189) + (@(0) * 17)
        (Install-JindaSoftware) | Should Be $false
        $script:wingetCalls.Count | Should Be 20
    }

    It 'installs the extension immediately after an already-current VS Code' {
        $script:wingetExitCodes[3] = -1978335189
        Mock Install-JindaVSCodePowerShellExtension {
            $script:extensionInstallPosition = $script:wingetCalls.Count
        }
        Install-JindaSoftware | Should Be $false
        $script:extensionInstallPosition | Should Be 4
        Assert-MockCalled Install-JindaVSCodePowerShellExtension -Times 1 -Exactly -Scope It
        $script:wingetCalls.Count | Should Be 20
    }

    It 'stops the run if the PowerShell extension fails' {
        Mock Install-JindaVSCodePowerShellExtension { throw 'VS Code: PowerShell extension installation failed' }
        { Install-JindaSoftware } | Should Throw 'PowerShell extension installation failed'
        $script:wingetCalls.Count | Should Be 4
        Assert-MockCalled Install-JindaYodeck -Times 0 -Exactly -Scope It
    }





    It 'continues installing the remaining packages when the first requests a reboot' {
        $script:wingetExitCodes = @(3010) + (@(0) * 19)
        (Install-JindaSoftware) | Should Be $true
        $script:wingetCalls.Count | Should Be 20
    }

    It 'warns about the reported Chrome source error and still attempts every remaining app' {
        $script:wingetExitCodes[0] = -1978335217
        $warnings = @()
        Install-JindaSoftware -WarningVariable warnings | Should Be $false
        $script:wingetCalls.Count | Should Be 20
        ($script:wingetCalls[0] -contains 'Google.Chrome') | Should Be $true
        ($warnings -join ' ') | Should Match 'Google Chrome.*0x8A15000F.*continue'
        Assert-MockCalled Install-JindaYodeck -Times 1 -Exactly -Scope It
    }

    It 'also continues after a Chrome process exception' {
        $script:throwChrome = $true
        Install-JindaSoftware | Should Be $false
        $script:wingetCalls.Count | Should Be 20
        Assert-MockCalled Install-JindaYodeck -Times 1 -Exactly -Scope It
    }

    It 'stops on the same source error in TeamViewer after allowing the Chrome error' {
        $script:wingetExitCodes[0] = -1978335217
        $script:wingetExitCodes[1] = -1978335217
        { Install-JindaSoftware } | Should Throw 'TeamViewer: WinGet failed'
        $script:wingetCalls.Count | Should Be 2
        Assert-MockCalled Install-JindaYodeck -Times 0 -Exactly -Scope It
    }

    It 'still stops immediately for a failure in each earlier non-Chrome WinGet app' {
        foreach ($failedIndex in 1..18) {
            $script:wingetCalls = New-Object 'System.Collections.Generic.List[object]'
            $script:wingetExitCodes = @(0) * 20
            $script:wingetExitCodes[$failedIndex] = 1
            { Install-JindaSoftware } | Should Throw 'WinGet failed'
            $script:wingetCalls.Count | Should Be ($failedIndex + 1)
        }
        Assert-MockCalled Install-JindaYodeck -Times 0 -Exactly -Scope It
    }

    It 'preserves a later restart requirement after the Chrome error' {
        $script:wingetExitCodes[0] = 1
        $script:wingetExitCodes[2] = 3010
        Install-JindaSoftware | Should Be $true
        $script:wingetCalls.Count | Should Be 20
    }

    It 'reports a PowerShell installation failure after the other packages succeed' {
        $script:wingetExitCodes = @(0, 0, 1)
        { Install-JindaSoftware } | Should Throw 'PowerShell 7: WinGet failed'
        $script:wingetCalls.Count | Should Be 3
    }

    It 'does not run WinGet during WhatIf' {
        (Install-JindaSoftware -WhatIf) | Should Be $false
        $script:wingetCalls.Count | Should Be 0
        $script:wingetUpgradeCalls.Count | Should Be 0
    }

    It 'reports missing WinGet before attempting any package' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'winget.exe' }
        { Install-JindaSoftware } | Should Throw 'WinGet is missing'
        $script:wingetCalls.Count | Should Be 0
    }

    It 'skips configured apps and their related extension or direct-install steps' {
        Mock Get-JindaSkippedApps { @('Google.Chrome', 'TeamViewer.TeamViewer', 'Microsoft.VisualStudioCode', 'LastPass.LastPass', 'Yodeck.Player', '9NKSQGP7F2NH') }
        Install-JindaSoftware | Should Be $false
        $ids = @($script:wingetCalls | ForEach-Object { $_[2] })
        $ids.Count | Should Be 15
        foreach ($id in @('Google.Chrome', 'TeamViewer.TeamViewer', 'Microsoft.VisualStudioCode', 'LastPass.LastPass', '9NKSQGP7F2NH')) {
            ($ids -contains $id) | Should Be $false
        }
        $ids[-1] | Should Be 'Adobe.Acrobat.Reader.64-bit'
        Assert-MockCalled Install-JindaYodeck -Times 0 -Exactly -Scope It
        Assert-MockCalled Install-JindaVSCodePowerShellExtension -Times 0 -Exactly -Scope It
    }

    It 'does not require or update WinGet when every app is skipped' {
        Mock Get-JindaSkippedApps { Get-JindaSoftwarePackages | ForEach-Object { $_.Id } }
        Install-JindaSoftware | Should Be $false
        $script:wingetCalls.Count | Should Be 0
        $script:wingetUpgradeCalls.Count | Should Be 0
        Assert-MockCalled Get-Command -Times 0 -Exactly -Scope It -ParameterFilter { $Name -eq 'winget.exe' }
        Assert-MockCalled Install-JindaYodeck -Times 0 -Exactly -Scope It
    }

    It 'stops before WinGet or any app when skip configuration cannot be read or validated' {
        Mock Get-JindaSkippedApps { throw 'Invalid skip configuration' }
        { Install-JindaSoftware } | Should Throw 'Invalid skip configuration'
        $script:wingetCalls.Count | Should Be 0
        $script:wingetUpgradeCalls.Count | Should Be 0
        Assert-MockCalled Install-JindaYodeck -Times 0 -Exactly -Scope It
    }

    It 'includes all twenty active WinGet packages once, excluding Discord and Teams, and Yodeck once in the same run' {
        Install-JindaSoftware | Should Be $false
        $ids = @($script:wingetCalls | ForEach-Object { $_[2] })
        $expected = @('Google.Chrome','TeamViewer.TeamViewer','Microsoft.PowerShell','Microsoft.VisualStudioCode',
            'XPFFZHVGQWWLHB','Notepad++.Notepad++','Reolink.Reolink','dotPDN.PaintDotNet',
            'LastPass.LastPass','Git.Git','Zoom.Zoom','VideoLAN.VLC','voidtools.Everything','ScooterSoftware.BeyondCompare.5',
            '9NT1R1C2HH7J','OpenAI.ChatGPT','OpenWhisperSystems.Signal','OBSProject.OBSStudio','Adobe.Acrobat.Reader.64-bit','9NKSQGP7F2NH')
        @($ids | Select-Object -Unique).Count | Should Be 20
        ($ids -contains 'Discord.Discord') | Should Be $false
        ($ids -contains 'Microsoft.Teams') | Should Be $false
        ($ids -contains 'OpenAI.Codex') | Should Be $false
        foreach ($id in $expected) { ($ids -contains $id) | Should Be $true }
        Assert-MockCalled Install-JindaYodeck -Times 1 -Exactly -Scope It
    }

    It 'uses Store IDs and never forces unsupported scopes' {
        Install-JindaSoftware | Out-Null
        foreach ($call in $script:wingetCalls) {
            $id = $call[2]
            if ($id -in @('XPFFZHVGQWWLHB', '9NT1R1C2HH7J', '9NKSQGP7F2NH')) {
                $call[[array]::IndexOf($call, '--source') + 1] | Should Be 'msstore'
            } else {
                $call[[array]::IndexOf($call, '--source') + 1] | Should Be 'winget'
            }
            if ($id -in @('XPFFZHVGQWWLHB', '9NT1R1C2HH7J', 'OpenAI.ChatGPT', '9NKSQGP7F2NH', 'Reolink.Reolink', 'LastPass.LastPass')) {
                ($call -contains '--scope') | Should Be $false
            } elseif ($id -eq 'OpenWhisperSystems.Signal') {
                $call[[array]::IndexOf($call, '--scope') + 1] | Should Be 'user'
            } else {
                $call[[array]::IndexOf($call, '--scope') + 1] | Should Be 'machine'
            }
            if ($id -eq 'ScooterSoftware.BeyondCompare.5') {
                $call[[array]::IndexOf($call, '--locale') + 1] | Should Be 'en'
            }
            if ($id -eq 'OpenAI.ChatGPT') {
                $call[[array]::IndexOf($call, '--installer-type') + 1] | Should Be 'msix'
            }
            if ($id -eq 'OBSProject.OBSStudio') {
                $call[[array]::IndexOf($call, '--installer-type') + 1] | Should Be 'nullsoft'
            }
        }
    }

    It 'installs WhatsApp last, after the added desktop apps and the direct Yodeck installer' {
        Install-JindaSoftware | Should Be $false
        ($script:appOrder | Select-Object -Last 10) -join ',' | Should Be 'VideoLAN.VLC,voidtools.Everything,ScooterSoftware.BeyondCompare.5,9NT1R1C2HH7J,OpenAI.ChatGPT,OpenWhisperSystems.Signal,OBSProject.OBSStudio,Adobe.Acrobat.Reader.64-bit,Yodeck,9NKSQGP7F2NH'
        $script:appOrder.Count | Should Be 21
    }

    It 'preserves a fatal WhatsApp error after every other app has been attempted' {
        $script:wingetExitCodes[19] = -2147023584
        { Install-JindaSoftware } | Should Throw 'WhatsApp: WinGet failed'
        $script:wingetCalls.Count | Should Be 20
        ($script:appOrder | Select-Object -Last 10) -join ',' | Should Be 'VideoLAN.VLC,voidtools.Everything,ScooterSoftware.BeyondCompare.5,9NT1R1C2HH7J,OpenAI.ChatGPT,OpenWhisperSystems.Signal,OBSProject.OBSStudio,Adobe.Acrobat.Reader.64-bit,Yodeck,9NKSQGP7F2NH'
        Assert-MockCalled Install-JindaYodeck -Times 1 -Exactly -Scope It
    }

    It 'installs OpenSSH once through Windows features instead of WinGet' {
        Install-JindaSoftware -EnableOpenSSH | Should Be $false
        Assert-MockCalled Install-JindaOpenSSH -Times 1 -Exactly -Scope It
        (@($script:wingetCalls | ForEach-Object { $_[2] }) -contains 'Windows.OpenSSH') | Should Be $false
    }

    It 'skips OpenSSH setup when selected in skip-apps.conf' {
        Mock Get-JindaSkippedApps { @('Windows.OpenSSH') }
        Install-JindaSoftware -EnableOpenSSH | Should Be $false
        Assert-MockCalled Install-JindaOpenSSH -Times 0 -Exactly -Scope It
    }

    It 'propagates an OpenSSH restart requirement' {
        Mock Install-JindaOpenSSH { $true }
        Install-JindaSoftware -EnableOpenSSH | Should Be $true
        $script:wingetCalls.Count | Should Be 20
    }

    It 'stops on an OpenSSH installation failure before the next app' {
        Mock Install-JindaOpenSSH { throw 'OpenSSH installation failed' }
        { Install-JindaSoftware -EnableOpenSSH } | Should Throw 'OpenSSH installation failed'
        $script:wingetCalls.Count | Should Be 3
    }

    It 'leaves OpenSSH untouched unless explicitly enabled' {
        Install-JindaSoftware | Should Be $false
        Assert-MockCalled Install-JindaOpenSSH -Times 0 -Exactly -Scope It
        $script:wingetCalls.Count | Should Be 20
    }

    It 'installs only OpenSSH without requiring, updating or repairing WinGet when apps are skipped' {
        Mock Get-Command { throw 'WinGet must not be required for SSH-only setup' } -ParameterFilter { $Name -eq 'winget.exe' }
        Install-JindaSoftware -EnableOpenSSH -SkipApps | Should Be $false
        Assert-MockCalled Install-JindaOpenSSH -Times 1 -Exactly -Scope It
        Assert-MockCalled Install-JindaYodeck -Times 0 -Exactly -Scope It
        $script:wingetCalls.Count | Should Be 0
        $script:wingetUpgradeCalls.Count | Should Be 0
    }

    It 'respects the skip file even when SSH is the only selected component' {
        Mock Get-JindaSkippedApps { @('Windows.OpenSSH') }
        Install-JindaSoftware -EnableOpenSSH -SkipApps | Should Be $false
        Assert-MockCalled Install-JindaOpenSSH -Times 0 -Exactly -Scope It
        Assert-MockCalled Get-Command -Times 0 -Exactly -Scope It -ParameterFilter { $Name -eq 'winget.exe' }
    }

    It 'propagates a Yodeck restart requirement' {
        Mock Install-JindaYodeck { $true }
        Install-JindaSoftware | Should Be $true
    }

    It 'reports a Yodeck failure before attempting WhatsApp' {
        Mock Install-JindaYodeck { throw 'Yodeck: installation failed' }
        { Install-JindaSoftware } | Should Throw 'Yodeck: installation failed'
        $script:wingetCalls.Count | Should Be 19
        (@($script:wingetCalls | ForEach-Object { $_[2] }) -contains '9NKSQGP7F2NH') | Should Be $false
    }

}

Describe 'Complete installation preview' {
    It 'does not execute Yodeck side effects when the real combined flow receives WhatIf' {
        $script:wingetCalls = New-Object 'System.Collections.Generic.List[object]'
        Mock Get-Command { [pscustomobject]@{ Source = 'Invoke-JindaFakeWinget' } } -ParameterFilter { $Name -eq 'winget.exe' }
        Mock Invoke-WebRequest { throw 'Unexpected download in WhatIf' }
        Mock Start-Process { throw 'Unexpected installer in WhatIf' }
        Mock New-Item { throw 'Unexpected write in WhatIf' }
        Mock Get-WindowsCapability { throw 'Unexpected capability access in WhatIf' }
        Install-JindaSoftware -EnableOpenSSH -WhatIf | Should Be $false
        Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly -Scope It
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
        Assert-MockCalled New-Item -Times 0 -Exactly -Scope It
        Assert-MockCalled Get-WindowsCapability -Times 0 -Exactly -Scope It
        $script:wingetCalls.Count | Should Be 0
    }
}

# Run the installer entry-point statements with mocked work, never exit the test host.
$installerAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSScriptRoot) 'install-software.ps1'), [ref]$null, [ref]$null)
$installerTry = $installerAst.EndBlock.Statements[-1].Clauses[0].Item2.Statements[0]
$installerBody = ($installerTry.Body.Statements | Where-Object { $_ -isnot [Management.Automation.Language.ExitStatementAst] } | ForEach-Object { $_.Extent.Text }) -join "`n"
$script:installerEntry = [scriptblock]::Create($installerBody.Replace('$PSCommandPath', "'C:\Test Folder\install-software.ps1'"))

Describe 'Installer entry point preserves the OpenSSH choice' {
    BeforeEach {
        Mock Invoke-JindaManagedScript { & $Work }
        Mock Install-JindaSoftware { $false }
    }

    It 'forwards both opt-in and app-skip flags to runtime relaunch and installation' {
        $EnableOpenSSH = $true
        $SkipApps = $true
        $LanIPAddress = '192.168.50.40'
        & $script:installerEntry
        Assert-MockCalled Invoke-JindaManagedScript -Times 1 -Exactly -Scope It -ParameterFilter {
            ($ScriptArguments -join ' ') -eq '-EnableOpenSSH -SkipApps -LanIPAddress 192.168.50.40'
        }
        Assert-MockCalled Install-JindaSoftware -Times 1 -Exactly -Scope It -ParameterFilter {
            $EnableOpenSSH -and $SkipApps -and $LanIPAddress -eq '192.168.50.40'
        }
    }

    It 'keeps direct installation opt-out by default' {
        $EnableOpenSSH = $false
        $SkipApps = $false
        & $script:installerEntry
        Assert-MockCalled Invoke-JindaManagedScript -Times 1 -Exactly -Scope It -ParameterFilter { $ScriptArguments.Count -eq 0 }
        Assert-MockCalled Install-JindaSoftware -Times 1 -Exactly -Scope It -ParameterFilter { -not $EnableOpenSSH -and -not $SkipApps }
    }
}
