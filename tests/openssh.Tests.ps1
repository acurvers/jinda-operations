. (Join-Path (Split-Path -Parent $PSScriptRoot) 'install-software.ps1')

Describe 'Windows OpenSSH installation and local subnet access' {
    BeforeEach {
        $script:sshStates = @{
            'OpenSSH.Client~~~~0.0.1.0' = 'NotPresent'
            'OpenSSH.Server~~~~0.0.1.0' = 'NotPresent'
        }
        $script:sshStatus = 'Stopped'
        $script:sshEvents = New-Object 'System.Collections.Generic.List[string]'
        Mock Get-WindowsCapability { [pscustomobject]@{ State = $script:sshStates[$Name] } }
        Mock Add-WindowsCapability {
            $script:sshStates[$Name] = 'Installed'
            [pscustomobject]@{ RestartNeeded = $false }
        }
        Mock Get-NetFirewallRule { [pscustomobject]@{ Name = 'OpenSSH-Server-In-TCP' } }
        Mock Set-NetFirewallRule { $script:sshEvents.Add('firewall') }
        Mock New-NetFirewallRule { $script:sshEvents.Add('firewall') }
        Mock Get-Service { [pscustomobject]@{ Status = $script:sshStatus } }
        Mock Set-Service {}
        Mock Start-Service { $script:sshEvents.Add('start'); $script:sshStatus = 'Running' }
    }

    It 'installs both stable Windows features without rebooting and scopes the standard rule before starting SSH' {
        Install-JindaOpenSSH | Should Be $false
        foreach ($capabilityName in @('OpenSSH.Client~~~~0.0.1.0', 'OpenSSH.Server~~~~0.0.1.0')) {
            Assert-MockCalled Add-WindowsCapability -Times 1 -Exactly -Scope It -ParameterFilter {
                $Online -and $Name -eq $capabilityName
            }
        }
        Assert-MockCalled Set-NetFirewallRule -Times 1 -Exactly -Scope It -ParameterFilter {
            $Name -eq 'OpenSSH-Server-In-TCP' -and $RemoteAddress -eq 'LocalSubnet' -and
            $LocalPort -eq 22 -and $Protocol -eq 'TCP' -and $Action -eq 'Allow' -and
            $Direction -eq 'Inbound' -and $Enabled -eq 'True' -and
            [int]$Profile -eq 3 # NetSecurity binds Domain (1) + Private (2) as flags.
        }
        ($script:sshEvents -join ',') | Should Be 'firewall,start'
        Assert-MockCalled Set-Service -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'sshd' -and $StartupType -eq 'Automatic' }
        Assert-MockCalled New-NetFirewallRule -Times 0 -Exactly -Scope It
    }

    It 'does not reinstall features or restart an already running server' {
        $script:sshStates['OpenSSH.Client~~~~0.0.1.0'] = 'Installed'
        $script:sshStates['OpenSSH.Server~~~~0.0.1.0'] = 'Installed'
        $script:sshStatus = 'Running'
        Install-JindaOpenSSH | Should Be $false
        Assert-MockCalled Add-WindowsCapability -Times 0 -Exactly -Scope It
        Assert-MockCalled Start-Service -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-NetFirewallRule -Times 1 -Exactly -Scope It
    }

    It 'creates a restricted rule if Windows did not supply one' {
        Mock Get-NetFirewallRule { $null }
        Install-JindaOpenSSH | Should Be $false
        Assert-MockCalled New-NetFirewallRule -Times 1 -Exactly -Scope It -ParameterFilter {
            $Name -eq 'OpenSSH-Server-In-TCP' -and $RemoteAddress -eq 'LocalSubnet' -and
            $LocalPort -eq 22 -and [int]$Profile -eq 3
        }
        Assert-MockCalled Set-NetFirewallRule -Times 0 -Exactly -Scope It
    }

    It 'reports a Windows restart requirement and postpones service activation' {
        Mock Add-WindowsCapability {
            $script:sshStates[$Name] = 'InstallPending'
            [pscustomobject]@{ RestartNeeded = $true }
        }
        Install-JindaOpenSSH | Should Be $true
        Assert-MockCalled Set-NetFirewallRule -Times 1 -Exactly -Scope It
        Assert-MockCalled Start-Service -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-Service -Times 0 -Exactly -Scope It
    }

    It 'stops on an installation error without opening the firewall or starting services' {
        Mock Add-WindowsCapability { throw 'Windows Update capability download failed' }
        { Install-JindaOpenSSH } | Should Throw 'capability download failed'
        Assert-MockCalled Set-NetFirewallRule -Times 0 -Exactly -Scope It
        Assert-MockCalled Start-Service -Times 0 -Exactly -Scope It
    }

    It 'rejects an unsuccessful installation even if the installer returned normally' {
        Mock Add-WindowsCapability { [pscustomobject]@{ RestartNeeded = $false } }
        { Install-JindaOpenSSH } | Should Throw 'was not installed successfully'
        Assert-MockCalled Start-Service -Times 0 -Exactly -Scope It
    }

    It 'asks for completion of pending servicing instead of retrying an incompatible feature state' {
        $script:sshStates['OpenSSH.Client~~~~0.0.1.0'] = 'InstallPending'
        { Install-JindaOpenSSH } | Should Throw 'pending Windows servicing'
        Assert-MockCalled Add-WindowsCapability -Times 0 -Exactly -Scope It
    }

    It 'does not start SSH if the firewall restriction fails' {
        Mock Set-NetFirewallRule { throw 'Firewall configuration failed' }
        { Install-JindaOpenSSH } | Should Throw 'Firewall configuration failed'
        Assert-MockCalled Start-Service -Times 0 -Exactly -Scope It
    }

    It 'does not report success if the service fails to run' {
        Mock Start-Service {}
        { Install-JindaOpenSSH } | Should Throw 'sshd service is not running'
    }

    It 'makes no capability, firewall or service calls in WhatIf' {
        Install-JindaOpenSSH -WhatIf | Should Be $false
        Assert-MockCalled Get-WindowsCapability -Times 0 -Exactly -Scope It
        Assert-MockCalled Add-WindowsCapability -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-NetFirewallRule -Times 0 -Exactly -Scope It
        Assert-MockCalled New-NetFirewallRule -Times 0 -Exactly -Scope It
        Assert-MockCalled Start-Service -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-Service -Times 0 -Exactly -Scope It
    }
}
