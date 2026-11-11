. (Join-Path (Split-Path -Parent $PSScriptRoot) 'install-software.ps1')

Describe 'Windows OpenSSH installation and local subnet access' {
    BeforeEach {
        $script:sshStates = @{
            'OpenSSH.Client~~~~0.0.1.0' = 'NotPresent'
            'OpenSSH.Server~~~~0.0.1.0' = 'NotPresent'
        }
        $script:sshStatus = 'Stopped'
        $script:sshEvents = New-Object 'System.Collections.Generic.List[string]'
        $script:sshAddresses = @(
            [pscustomobject]@{ IPAddress = '192.168.50.40'; PrefixLength = 27; InterfaceAlias = 'Ethernet'; AddressState = 'Preferred' }
        )
        # NetSecurity exposes the raw CIM fields as named values in Windows PowerShell.
        $script:sshRule = New-CimInstance -Namespace root/standardcimv2 -ClassName MSFT_NetFirewallRule -ClientOnly -Property @{
            Enabled = [uint16]1; Profiles = [uint16]0; Direction = [uint16]1
            Action = [uint16]2; EdgeTraversalPolicy = [uint16]0
            PrimaryStatus = [uint16]1; EnforcementStatus = [uint16[]]@(1)
        }
        Mock Get-NetIPAddress { $script:sshAddresses }
        Mock Get-WindowsCapability { [pscustomobject]@{ State = $script:sshStates[$Name] } }
        Mock Add-WindowsCapability {
            $script:sshStates[$Name] = 'Installed'
            [pscustomobject]@{ RestartNeeded = $false }
        }
        Mock Get-NetFirewallRule { [pscustomobject]@{ Name = 'OpenSSH-Server-In-TCP' } }
        Mock Get-NetFirewallRule { $script:sshRule } -ParameterFilter { $PolicyStore -eq 'ActiveStore' }
        Mock Get-NetFirewallAddressFilter {
            [pscustomobject]@{ LocalAddress = '192.168.50.40'; RemoteAddress = '192.168.50.32/255.255.255.224' }
        }
        Mock Get-NetFirewallPortFilter { [pscustomobject]@{ Protocol = 'TCP'; LocalPort = '22' } }
        Mock Get-NetFirewallInterfaceFilter { [pscustomobject]@{ InterfaceAlias = 'Ethernet' } }
        Mock Set-NetFirewallRule { $script:sshEvents.Add('firewall') }
        Mock New-NetFirewallRule { $script:sshEvents.Add('firewall') }
        Mock Get-Service { [pscustomobject]@{ Status = $script:sshStatus } }
        Mock Set-Service {}
        Mock Start-Service { $script:sshEvents.Add('start'); $script:sshStatus = 'Running' }
        Mock Get-CimInstance { [pscustomobject]@{ ProcessId = 42 } }
        Mock Get-NetTCPConnection {
            [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 22; State = 'Listen'; OwningProcess = 42 }
        }
        Mock Start-Sleep {}
        Mock Write-Warning {}
        Mock Add-JindaOpenSSHManagementKey {}
    }

    It 'installs both stable Windows features without rebooting and scopes the standard rule before starting SSH' {
        Install-JindaOpenSSH | Should Be $false
        foreach ($capabilityName in @('OpenSSH.Client~~~~0.0.1.0', 'OpenSSH.Server~~~~0.0.1.0')) {
            Assert-MockCalled Add-WindowsCapability -Times 1 -Exactly -Scope It -ParameterFilter {
                $Online -and $Name -eq $capabilityName
            }
        }
        Assert-MockCalled Set-NetFirewallRule -Times 1 -Exactly -Scope It -ParameterFilter {
            $Name -eq 'OpenSSH-Server-In-TCP' -and $PolicyStore -eq 'PersistentStore' -and
            $RemoteAddress -eq '192.168.50.32/27' -and $LocalAddress -eq '192.168.50.40' -and
            $InterfaceAlias.Count -eq 1 -and $InterfaceAlias[0].IsMatch('Ethernet') -and
            -not $InterfaceAlias[0].IsMatch('Ethernet 2') -and $EdgeTraversalPolicy -eq 'Block' -and
            $LocalPort -eq 22 -and $Protocol -eq 'TCP' -and $Action -eq 'Allow' -and
            $Direction -eq 'Inbound' -and $Enabled -eq 'True' -and [string]$Profile -eq 'Any'
        }
        ($script:sshEvents -join ',') | Should Be 'firewall,start'
        Assert-MockCalled Set-Service -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'sshd' -and $StartupType -eq 'Automatic' }
        Assert-MockCalled New-NetFirewallRule -Times 0 -Exactly -Scope It
        Assert-MockCalled Get-NetTCPConnection -Times 1 -Exactly -Scope It -ParameterFilter {
            $State -eq 'Listen' -and $LocalPort -eq 22
        }
        Assert-MockCalled Get-NetFirewallRule -Times 1 -Exactly -Scope It -ParameterFilter {
            $PolicyStore -eq 'ActiveStore' -and $Name -eq 'OpenSSH-Server-In-TCP'
        }
    }

    It 'warns when the IPv4 listener on TCP 22 belongs to a different process' {
        Mock Get-NetTCPConnection {
            [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 22; State = 'Listen'; OwningProcess = 99 }
        }
        Install-JindaOpenSSH | Should Be $false
        Assert-MockCalled Get-NetTCPConnection -Times 3 -Exactly -Scope It
        Assert-MockCalled Write-Warning -Times 1 -Exactly -Scope It -ParameterFilter {
            $Message -like '*no IPv4 listener owned by sshd*'
        }
    }

    It 'fails when the effective firewall policy disables the rule' {
        $script:sshRule.CimInstanceProperties['Enabled'].Value = [uint16]2
        { Install-JindaOpenSSH } | Should Throw 'Active OpenSSH firewall rule'
    }

    It 'fails when the scoped rule is present but not enforced' {
        $script:sshRule.CimInstanceProperties['PrimaryStatus'].Value = [uint16]2
        $script:sshRule.CimInstanceProperties['EnforcementStatus'].Value = [uint16[]]@(5)
        { Install-JindaOpenSSH } | Should Throw 'not enforced: ProfileInactive'
    }

    It 'fails if the effective address filter is broader than the selected LAN' {
        Mock Get-NetFirewallAddressFilter {
            [pscustomobject]@{ LocalAddress = '192.168.50.40'; RemoteAddress = 'LocalSubnet' }
        }
        { Install-JindaOpenSSH } | Should Throw 'does not match the selected LAN'
    }

    It 'requires an explicit LAN address when several active addresses are present' {
        $script:sshAddresses += [pscustomobject]@{
            IPAddress = '10.20.30.40'; PrefixLength = 24; InterfaceAlias = 'Wi-Fi'; AddressState = 'Preferred'
        }
        { Install-JindaOpenSSH } | Should Throw 'requires one active IPv4 LAN address'
        Assert-MockCalled Add-WindowsCapability -Times 0 -Exactly -Scope It
        Install-JindaOpenSSH -LanIPAddress '192.168.50.40' | Should Be $false
    }

    It 'does not reinstall features or restart an already running server' {
        $script:sshStates['OpenSSH.Client~~~~0.0.1.0'] = 'Installed'
        $script:sshStates['OpenSSH.Server~~~~0.0.1.0'] = 'Installed'
        $script:sshStatus = 'Running'
        Install-JindaOpenSSH | Should Be $false
        Assert-MockCalled Add-WindowsCapability -Times 0 -Exactly -Scope It
        Assert-MockCalled Start-Service -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-NetFirewallRule -Times 1 -Exactly -Scope It
        Assert-MockCalled Add-JindaOpenSSHManagementKey -Times 0 -Exactly -Scope It
    }

    It 'provisions the optional public key after OpenSSH is running' {
        Install-JindaOpenSSH -SshPublicKey 'ssh-ed25519 example-key' | Should Be $false
        Assert-MockCalled Add-JindaOpenSSHManagementKey -Times 1 -Exactly -Scope It -ParameterFilter {
            $PublicKey -eq 'ssh-ed25519 example-key' -and $script:sshStatus -eq 'Running'
        }
    }

    It 'creates a restricted rule if Windows did not supply one' {
        Mock Get-NetFirewallRule { $null }
        Install-JindaOpenSSH | Should Be $false
        Assert-MockCalled New-NetFirewallRule -Times 1 -Exactly -Scope It -ParameterFilter {
            $Name -eq 'OpenSSH-Server-In-TCP' -and $RemoteAddress -eq '192.168.50.32/27' -and
            $LocalAddress -eq '192.168.50.40' -and $InterfaceAlias[0].IsMatch('Ethernet') -and
            $LocalPort -eq 22 -and [string]$Profile -eq 'Any'
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

Describe 'OpenSSH management public key' {
    BeforeEach {
        $header = [byte[]]@(0,0,0,11,115,115,104,45,101,100,50,53,53,49,57,0,0,0,32)
        $script:managementKey = 'ssh-ed25519 ' + [Convert]::ToBase64String($header + [byte[]](1..32))
        $script:adminUserSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1001')
        $script:standardUserSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1002')
        $script:disabledUserSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1003')
    }

    It 'accepts one Ed25519 public key and strips the comment' {
        ConvertTo-JindaEd25519PublicKey "$script:managementKey salon admin" | Should Be $script:managementKey
    }

    It 'rejects a private key, extra lines and an invalid Ed25519 blob' {
        { ConvertTo-JindaEd25519PublicKey '-----BEGIN OPENSSH PRIVATE KEY-----' } | Should Throw 'one OpenSSH Ed25519 public key'
        { ConvertTo-JindaEd25519PublicKey ($script:managementKey + [Environment]::NewLine + $script:managementKey) } |
            Should Throw 'one OpenSSH Ed25519 public key'
        { ConvertTo-JindaEd25519PublicKey ('ssh-ed25519 ' + ('A' * 68)) } | Should Throw 'invalid OpenSSH key blob'
    }

    It 'appends once and keeps the previous key text and options' {
        Mock Set-Acl {}
        $path = Join-Path $TestDrive 'authorized_keys'
        $existing = 'restrict ssh-ed25519 previous-key existing comment'
        [IO.File]::WriteAllText($path, $existing)
        Set-JindaSshAuthorizedKey -Path $path -PublicKey $script:managementKey -UserSid $script:standardUserSid
        Set-JindaSshAuthorizedKey -Path $path -PublicKey $script:managementKey -UserSid $script:standardUserSid
        [IO.File]::ReadAllText($path) | Should Be ($existing + [Environment]::NewLine + $script:managementKey + [Environment]::NewLine)
        Assert-MockCalled Set-Acl -Times 2 -Exactly -Scope It -ParameterFilter {
            $AclObject.AreAccessRulesProtected -and
            $AclObject.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544' -and
            (($AclObject.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]).IdentityReference.Value |
                Sort-Object) -join ',') -eq 'S-1-5-18,S-1-5-21-1-2-3-1002,S-1-5-32-544'
        }
    }

    It 'preserves restrictions on a copy of the same key that already exists' {
        Mock Set-Acl {}
        $path = Join-Path $TestDrive 'restricted_authorized_keys'
        $existing = 'restrict,command="cmd /c echo example" ' + $script:managementKey + ' old comment'
        [IO.File]::WriteAllText($path, $existing)
        Set-JindaSshAuthorizedKey -Path $path -PublicKey $script:managementKey
        [IO.File]::ReadAllText($path) | Should Be $existing
    }

    It 'uses the administrator file once and the enabled standard user profile' {
        Mock Get-LocalUser {
            [pscustomobject]@{ Name = 'admin'; Enabled = $true; SID = $script:adminUserSid }
            [pscustomobject]@{ Name = 'employee'; Enabled = $true; SID = $script:standardUserSid }
            [pscustomobject]@{ Name = 'disabled'; Enabled = $false; SID = $script:disabledUserSid }
        }
        Mock Get-LocalGroupMember { [pscustomobject]@{ SID = $script:adminUserSid } }
        Mock Get-JindaSshProfilePath { $TestDrive }
        Mock Set-JindaSshAuthorizedKey {}
        Add-JindaOpenSSHManagementKey -PublicKey $script:managementKey
        Assert-MockCalled Set-JindaSshAuthorizedKey -Times 2 -Exactly -Scope It
        Assert-MockCalled Set-JindaSshAuthorizedKey -Times 1 -Exactly -Scope It -ParameterFilter {
            $Path -eq (Join-Path $env:ProgramData 'ssh\administrators_authorized_keys') -and -not $UserSid
        }
        Assert-MockCalled Set-JindaSshAuthorizedKey -Times 1 -Exactly -Scope It -ParameterFilter {
            $Path -eq (Join-Path $TestDrive '.ssh\authorized_keys') -and $UserSid -eq $script:standardUserSid
        }
        Assert-MockCalled Get-JindaSshProfilePath -Times 1 -Exactly -Scope It
    }
}
