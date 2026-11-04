# Offline tests, compatible with Windows' bundled Pester 3.4.0.
# Load function definitions only; all Windows reads/writes used below are mocked.
$setupScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'set-windows-english.ps1'
. $setupScript

Describe 'LAN subnet calculation' {
    It 'calculates the plan-PC subnet without assuming every network is /24' {
        Get-LanIPv4Subnet -Address '192.168.50.200' -PrefixLength 24 | Should Be '192.168.50.0/24'
        Get-LanIPv4Subnet -Address '192.168.51.200' -PrefixLength 23 | Should Be '192.168.50.0/23'
        Get-LanIPv4Subnet -Address '10.24.5.12' -PrefixLength 20 | Should Be '10.24.0.0/20'
    }
    It 'rejects IPv6 and a host-only prefix' {
        { Get-LanIPv4Subnet -Address '::1' -PrefixLength 24 } | Should Throw
        { Get-LanIPv4Subnet -Address '192.168.50.200' -PrefixLength 32 } | Should Throw
    }
}

Describe 'Preview and target validation without system changes' {
    BeforeEach {
        Mock Get-JindaPowerShell7RemotingRuntime { [pscustomobject]@{ Path = 'C:\Program Files\PowerShell\7\pwsh.exe'; Version = [version]'7.6.9' } }
        $global:LanRemoteAccessFixtureEdition = 'Professional'
        $global:LanRemoteAccessFixturePort = 3389
        $global:LanRemoteAccessFixtureDenyRdp = 0
        $global:LanRemoteAccessFixtureFirewallEnabled = 'True'
        $global:LanRemoteAccessFixtureAllowLocal = 'NotConfigured'
        $global:LanRemoteAccessFixtureGroupPolicy = $false
        $global:LanRemoteAccessFixturePingPolicy = $false
        $global:LanRemoteAccessFixtureAddresses = @(
            [pscustomobject]@{ AddressState = 'Preferred'; PrefixLength = 24; InterfaceIndex = 7; InterfaceAlias = 'Ethernet' }
        )
    }
    Mock Get-CimInstance { [pscustomobject]@{ ProductType = 1; BuildNumber = '26100' } }
    Mock Get-ItemProperty {
        if ($LiteralPath -like '*CurrentVersion') { return [pscustomobject]@{ EditionID = $global:LanRemoteAccessFixtureEdition } }
        if ($LiteralPath -like '*Policies*') { return [pscustomobject]@{ fDenyTSConnections = $global:LanRemoteAccessFixtureDenyRdp } }
        return [pscustomobject]@{ PortNumber = $global:LanRemoteAccessFixturePort }
    }
    Mock Get-NetIPAddress { $global:LanRemoteAccessFixtureAddresses }
    Mock Get-NetConnectionProfile { [pscustomobject]@{ NetworkCategory = 'Public' } }
    Mock Get-NetFirewallProfile { [pscustomobject]@{ Enabled = $global:LanRemoteAccessFixtureFirewallEnabled; AllowLocalFirewallRules = $global:LanRemoteAccessFixtureAllowLocal } }
    Mock Get-NetFirewallRule {
        foreach ($ruleName in @('WINRM-HTTP-In-TCP', 'WINRM-HTTP-In-TCP-PUBLIC',
            'RemoteDesktop-UserMode-In-TCP', 'RemoteDesktop-UserMode-In-UDP', 'RemoteDesktop-Shadow-In-TCP')) {
            if (-not @($Name | Where-Object { $ruleName -like $_ }).Count) { continue }
            $sourceType = if ($global:LanRemoteAccessFixtureGroupPolicy -and $PolicyStore -eq 'ActiveStore') { 'GroupPolicy' } else { 'Local' }
            [pscustomobject]@{ Name = $ruleName; Direction = 'Inbound'; PolicyStoreSourceType = $sourceType }
        }
        if ($Name -contains 'Jinda-LAN-WireGuard-ICMPv4-In' -and $global:LanRemoteAccessFixturePingPolicy) {
            [pscustomobject]@{ Name = 'Jinda-LAN-WireGuard-ICMPv4-In'; Direction = 'Inbound'; PolicyStoreSourceType = 'GroupPolicy' }
        }
    }
    Mock Enable-PSRemoting { throw 'Unexpected mutation in preview' }
    Mock Set-NetFirewallRule { throw 'Unexpected mutation in preview' }
    Mock New-NetFirewallRule { throw 'Unexpected mutation in preview' }
    Mock Set-ItemProperty { throw 'Unexpected mutation in preview' }
    Mock Set-Service { throw 'Unexpected mutation in preview' }
    Mock Start-Service { throw 'Unexpected mutation in preview' }
    Mock Set-Item { throw 'Unexpected mutation in preview' }
    Mock Set-WSManInstance { throw 'Unexpected mutation in preview' }

    It 'previews the public-profile LAN without changing its category' {
        $plan = Get-LanRemoteAccessPlan -EnableRemoteDesktop -EnableWinRM -Address '192.168.50.200'
        $plan.Address | Should Be '192.168.50.200'
        $plan.Subnet | Should Be '192.168.50.0/24'
        ($plan.RemoteAddresses -join ',') | Should Be '192.168.50.0/24,10.6.0.3'
        $plan.NetworkProfile | Should Be 'Public'
        $plan.RDPPort | Should Be 3389
        $plan.WinRMPort | Should Be 5985
        $plan.PowerShell7.Version | Should Be ([version]'7.6.9')
    }

    It 'requires PowerShell 7 before changing anything when WinRM is selected' {
        Mock Get-JindaPowerShell7RemotingRuntime { throw 'WinRM requires an installed stable 64-bit PowerShell 7' }
        { Get-LanRemoteAccessPlan -EnableWinRM -Address '192.168.50.200' } | Should Throw 'WinRM requires'
        Assert-MockCalled Set-NetFirewallRule -Times 0 -Exactly -Scope It
        Assert-MockCalled Enable-PSRemoting -Times 0 -Exactly -Scope It
    }
    
    It 'refuses the wrong computer' {
        $global:LanRemoteAccessFixtureAddresses = @()
        { Get-LanRemoteAccessPlan -EnableRemoteDesktop -EnableWinRM -Address '192.168.50.200' } | Should Throw
        Assert-MockCalled Set-NetFirewallRule -Times 0 -Exactly -Scope It
    }
    It 'refuses an ambiguous address on multiple interfaces' {
        $global:LanRemoteAccessFixtureAddresses = @(
            [pscustomobject]@{ AddressState = 'Preferred' },
            [pscustomobject]@{ AddressState = 'Preferred' }
        )
        { Get-LanRemoteAccessPlan -EnableRemoteDesktop -EnableWinRM -Address '192.168.50.200' } | Should Throw
    }
    It 'refuses an edition without an RDP host' {
        $global:LanRemoteAccessFixtureEdition = 'Core'
        { Get-LanRemoteAccessPlan -EnableRemoteDesktop -EnableWinRM -Address '192.168.50.200' } | Should Throw
    }
    It 'refuses a disabled active firewall' {
        $global:LanRemoteAccessFixtureFirewallEnabled = 'False'
        { Get-LanRemoteAccessPlan -EnableRemoteDesktop -EnableWinRM -Address '192.168.50.200' } | Should Throw
    }
    It 'does not bypass centrally disabled local firewall rules' {
        $global:LanRemoteAccessFixtureAllowLocal = 'False'
        { Get-LanRemoteAccessPlan -EnableRemoteDesktop -EnableWinRM -Address '192.168.50.200' } | Should Throw
    }
    It 'does not override an RDP-deny policy' {
        $global:LanRemoteAccessFixtureDenyRdp = 1
        { Get-LanRemoteAccessPlan -EnableRemoteDesktop -EnableWinRM -Address '192.168.50.200' } | Should Throw
    }
    It 'refuses to alter rules controlled by Group Policy' {
        $global:LanRemoteAccessFixtureGroupPolicy = $true
        { Get-LanRemoteAccessPlan -EnableRemoteDesktop -EnableWinRM -Address '192.168.50.200' } | Should Throw
    }
    It 'keeps an existing nonstandard RDP port' {
        $global:LanRemoteAccessFixturePort = 3390
        (Get-LanRemoteAccessPlan -EnableRemoteDesktop -EnableWinRM -Address '192.168.50.200').RDPPort | Should Be 3390
    }

    It 'refuses a ping rule controlled by Group Policy before making changes' {
        $global:LanRemoteAccessFixturePingPolicy = $true
        { Get-LanRemoteAccessPlan -EnableWinRM -Address '192.168.50.200' } | Should Throw 'centrally managed'
        Assert-MockCalled New-NetFirewallRule -Times 0 -Exactly -Scope It
    }
    It 'rejects an RDP port conflicting with WinRM' {
        $global:LanRemoteAccessFixturePort = 5985
        { Get-LanRemoteAccessPlan -EnableRemoteDesktop -EnableWinRM -Address '192.168.50.200' } | Should Throw
    }
    It 'prepares RDP alone without including WinRM rules' {
        $plan = Get-LanRemoteAccessPlan -EnableRemoteDesktop -Address '192.168.50.200'
        $plan.EnableRemoteDesktop | Should Be $true
        $plan.EnableWinRM | Should Be $false
        @($plan.Rules | Where-Object Name -like 'WINRM-*').Count | Should Be 0
        Assert-MockCalled Get-JindaPowerShell7RemotingRuntime -Times 0 -Exactly -Scope It
    }
    It 'prepares WinRM alone without RDP rules or RDP policy checks' {
        $global:LanRemoteAccessFixtureDenyRdp = 1
        $plan = Get-LanRemoteAccessPlan -EnableWinRM -Address '192.168.50.200'
        $plan.EnableRemoteDesktop | Should Be $false
        $plan.EnableWinRM | Should Be $true
        @($plan.Rules | Where-Object Name -like 'RemoteDesktop*').Count | Should Be 0
        Assert-MockCalled Get-ItemProperty -Times 0 -Exactly -Scope It -ParameterFilter { $LiteralPath -like '*Terminal Services' -or $LiteralPath -like '*RDP-Tcp' }
    }
}

Describe 'Applying the plan with every mutating command mocked' {
    BeforeEach {
        Mock Assert-LanRemoteAccessAdministrator {}
        Mock Enable-PSRemoting {}
        Mock Invoke-JindaPowerShell7Remoting {}
        Mock Set-WSManInstance {}
        $script:pingRuleExists = $false
        $script:winrmAllowUnencrypted = 'false'
        $script:winrmBasic = 'false'
        $script:testPlan = [pscustomobject]@{
            Address = '192.168.50.200'; Subnet = '192.168.50.0/24'; InterfaceAlias = 'Ethernet'
            RemoteAddresses = @('192.168.50.0/24', '10.6.0.3')
            PingRuleName = 'Jinda-LAN-WireGuard-ICMPv4-In'
            RDPPort = 3390; WinRMPort = 5985; EnableRemoteDesktop = $true; EnableWinRM = $true
            PowerShell7 = [pscustomobject]@{ Path = 'C:\Program Files\PowerShell\7\pwsh.exe'; Version = [version]'7.6.9' }
            RuleNames = @('WINRM-*', 'RemoteDesktop*')
            Rules = @(
                [pscustomobject]@{ Name = 'WINRM-HTTP-In-TCP' },
                [pscustomobject]@{ Name = 'RemoteDesktop-UserMode-In-TCP' },
                [pscustomobject]@{ Name = 'RemoteDesktop-UserMode-In-UDP' },
                [pscustomobject]@{ Name = 'RemoteDesktop-Shadow-In-TCP' }
            )
        }
    }
    Mock Get-NetFirewallRule {
        if ($Name -contains $script:testPlan.PingRuleName) {
            if ($script:pingRuleExists) { [pscustomobject]@{ Name = $script:testPlan.PingRuleName; Direction = 'Inbound' } }
            return
        }
        foreach ($rule in $script:testPlan.Rules) {
            [pscustomobject]@{ Name = $rule.Name; Direction = 'Inbound' }
        }
    }
    Mock Set-NetFirewallRule {}
    Mock New-NetFirewallRule { $script:pingRuleExists = $true }
    Mock Set-ItemProperty {}
    Mock Set-Service {}
    Mock Start-Service {}
    Mock Restart-Service { throw 'Must never restart TermService' }
    Mock Set-Item { throw 'WinRM firewall exception will not work since one of the network connection types on this machine is set to Public.' }
    Mock Get-WSManInstance {
        if ($ResourceURI -eq 'winrm/config/service') { return [pscustomobject]@{ AllowUnencrypted = $script:winrmAllowUnencrypted } }
        if ($ResourceURI -eq 'winrm/config/service/auth') { return [pscustomobject]@{ Basic = $script:winrmBasic } }
        throw "Unexpected WSMan resource: $ResourceURI"
    }
    Mock Test-WSMan { [pscustomobject]@{ ProductVersion = 'mock' } }
    Mock Get-Service { [pscustomobject]@{ Name = 'WinRM'; Status = 'Running'; StartType = 'Automatic' } }
    Mock Get-NetTCPConnection {
        [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 5985; State = 'Listen' }
        [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 3390; State = 'Listen' }
    }

    It 'scopes every managed rule before and after enabling remoting' {
        Invoke-LanRemoteAccessSetup -Plan $script:testPlan | Out-Null
        Assert-MockCalled Set-NetFirewallRule -Times 8 -Exactly -Scope It -ParameterFilter {
            @($RemoteAddress).Count -eq 2 -and $RemoteAddress -contains '192.168.50.0/24' -and
            $RemoteAddress -contains '10.6.0.3' -and $LocalAddress -eq '192.168.50.200' -and
            (@($InterfaceAlias)[0]).IsMatch('Ethernet') -and -not (@($InterfaceAlias)[0]).IsMatch('Ethernet 2') -and
            $Profile -eq 'Any' -and $EdgeTraversalPolicy -eq 'Block'
        }
        Assert-MockCalled Enable-PSRemoting -Times 1 -Exactly -Scope It -ParameterFilter { $Force -and $SkipNetworkProfileCheck }
        Assert-MockCalled Invoke-JindaPowerShell7Remoting -Times 1 -Exactly -Scope It -ParameterFilter { $Executable -eq 'C:\Program Files\PowerShell\7\pwsh.exe' }
        Assert-MockCalled Set-NetFirewallRule -Times 0 -Exactly -Scope It -ParameterFilter { $RemoteAddress -eq 'Any' }
    }
    It 'treats special characters in interface names literally' {
        $script:testPlan.InterfaceAlias = 'LAN [1]'
        Set-LanRemoteAccessRuleScope -Plan $script:testPlan
        Assert-MockCalled Set-NetFirewallRule -Times 4 -Exactly -Scope It -ParameterFilter {
            (@($InterfaceAlias)[0]).IsMatch('LAN [1]') -and -not (@($InterfaceAlias)[0]).IsMatch('LAN 1')
        }
    }

    It 'allows only IPv4 echo requests from the LAN and this WireGuard client' {
        Invoke-LanRemoteAccessSetup -Plan $script:testPlan | Out-Null
        Assert-MockCalled New-NetFirewallRule -Times 1 -Exactly -Scope It -ParameterFilter {
            $Name -eq 'Jinda-LAN-WireGuard-ICMPv4-In' -and $PolicyStore -eq 'PersistentStore' -and
            $Direction -eq 'Inbound' -and $Enabled -eq 'True' -and $Action -eq 'Allow' -and
            $Protocol -eq 'ICMPv4' -and @($IcmpType).Count -eq 1 -and $IcmpType -contains '8' -and
            $LocalAddress -eq '192.168.50.200' -and @($RemoteAddress).Count -eq 2 -and
            $RemoteAddress -contains '192.168.50.0/24' -and $RemoteAddress -contains '10.6.0.3' -and
            (@($InterfaceAlias)[0]).IsMatch('Ethernet') -and $EdgeTraversalPolicy -eq 'Block'
        }
    }

    It 'updates the same ping rule on repeat runs while retaining both source addresses' {
        Invoke-LanRemoteAccessSetup -Plan $script:testPlan | Out-Null
        Invoke-LanRemoteAccessSetup -Plan $script:testPlan | Out-Null
        Assert-MockCalled New-NetFirewallRule -Times 1 -Exactly -Scope It
        Assert-MockCalled Set-NetFirewallRule -Times 1 -Exactly -Scope It -ParameterFilter {
            $Name -eq 'Jinda-LAN-WireGuard-ICMPv4-In' -and $Protocol -eq 'ICMPv4' -and
            $IcmpType -contains '8' -and @($RemoteAddress).Count -eq 2 -and
            $RemoteAddress -contains '192.168.50.0/24' -and $RemoteAddress -contains '10.6.0.3'
        }
    }
    It 'enables only needed rules and preserves the RDP port' {
        Invoke-LanRemoteAccessSetup -Plan $script:testPlan | Out-Null
        Assert-MockCalled Set-NetFirewallRule -Times 1 -Exactly -Scope It -ParameterFilter {
            $Name -eq 'RemoteDesktop-UserMode-In-TCP' -and $LocalPort -eq 3390 -and $Enabled -eq 'True'
        }
        Assert-MockCalled Set-NetFirewallRule -Times 1 -Exactly -Scope It -ParameterFilter {
            $Name -eq 'RemoteDesktop-UserMode-In-UDP' -and $LocalPort -eq 3390 -and $Enabled -eq 'True'
        }
        Assert-MockCalled Set-NetFirewallRule -Times 0 -Exactly -Scope It -ParameterFilter {
            $Name -eq 'RemoteDesktop-Shadow-In-TCP' -and $Enabled -eq 'True'
        }
        Assert-MockCalled Restart-Service -Times 0 -Exactly -Scope It
    }
    It 'requires NLA and verifies disabled WinRM plaintext/Basic without using the failing WSMan provider' {
        Invoke-LanRemoteAccessSetup -Plan $script:testPlan | Out-Null
        Assert-MockCalled Set-ItemProperty -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'UserAuthentication' -and $Value -eq 1 }
        Assert-MockCalled Set-Item -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-WSManInstance -Times 1 -Exactly -Scope It -ParameterFilter { $ResourceURI -eq 'winrm/config/service' -and $ValueSet.Count -eq 1 -and $ValueSet.AllowUnencrypted -ceq 'false' -and -not $ComputerName }
        Assert-MockCalled Set-WSManInstance -Times 1 -Exactly -Scope It -ParameterFilter { $ResourceURI -eq 'winrm/config/service/auth' -and $ValueSet.Count -eq 1 -and $ValueSet.Basic -ceq 'false' -and -not $ComputerName }
        Assert-MockCalled Get-WSManInstance -Times 2 -Exactly -Scope It
    }
    It 'stops if WinRM security settings cannot be saved' {
        Mock Set-WSManInstance { throw 'Simulated WSMan configuration write failure' }
        { Invoke-LanRemoteAccessSetup -Plan $script:testPlan } | Should Throw 'Simulated WSMan configuration write failure'
        Assert-MockCalled Test-WSMan -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-ItemProperty -Times 0 -Exactly -Scope It
    }
    It 'stops if either insecure WinRM setting remains enabled' {
        $script:winrmAllowUnencrypted = 'true'
        { Invoke-LanRemoteAccessSetup -Plan $script:testPlan } | Should Throw 'WinRM security verification failed'
        $script:winrmAllowUnencrypted = 'false'
        $script:winrmBasic = 'true'
        { Invoke-LanRemoteAccessSetup -Plan $script:testPlan } | Should Throw 'WinRM security verification failed'
        Assert-MockCalled Test-WSMan -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-ItemProperty -Times 0 -Exactly -Scope It
    }
    It 'restores the scope even if enabling WinRM fails' {
        Mock Enable-PSRemoting { throw 'Simulated WinRM setup failure' }
        { Invoke-LanRemoteAccessSetup -Plan $script:testPlan } | Should Throw
        Assert-MockCalled Set-NetFirewallRule -Times 8 -Exactly -Scope It -ParameterFilter {
            @($RemoteAddress).Count -eq 2 -and $RemoteAddress -contains '192.168.50.0/24' -and $RemoteAddress -contains '10.6.0.3'
        }
        Assert-MockCalled Set-ItemProperty -Times 0 -Exactly -Scope It
    }
    It 'restores LAN and WireGuard firewall scope even if the PowerShell 7 worker fails' {
        Mock Invoke-JindaPowerShell7Remoting { throw 'PowerShell 7 WinRM configuration failed' }
        { Invoke-LanRemoteAccessSetup -Plan $script:testPlan } | Should Throw 'PowerShell 7 WinRM'
        Assert-MockCalled Set-NetFirewallRule -Times 8 -Exactly -Scope It -ParameterFilter {
            @($RemoteAddress).Count -eq 2 -and $RemoteAddress -contains '192.168.50.0/24' -and $RemoteAddress -contains '10.6.0.3'
        }
        Assert-MockCalled Set-ItemProperty -Times 0 -Exactly -Scope It
    }
    It 'refuses mutation without administrator rights' {
        Mock Assert-LanRemoteAccessAdministrator { throw 'Not elevated' }
        { Invoke-LanRemoteAccessSetup -Plan $script:testPlan } | Should Throw
        Assert-MockCalled Set-NetFirewallRule -Times 0 -Exactly -Scope It
        Assert-MockCalled Enable-PSRemoting -Times 0 -Exactly -Scope It
        Assert-MockCalled New-NetFirewallRule -Times 0 -Exactly -Scope It
    }
    It 'also scopes a standard rule newly created by Windows setup' {
        Mock Assert-LanRemoteAccessAdministrator {}
        Mock Enable-PSRemoting {
            $script:testPlan.Rules += [pscustomobject]@{ Name = 'WINRM-HTTP-In-TCP-PUBLIC' }
        }
        Invoke-LanRemoteAccessSetup -Plan $script:testPlan | Out-Null
        Assert-MockCalled Set-NetFirewallRule -Times 1 -Exactly -Scope It -ParameterFilter {
            $Name -eq 'WINRM-HTTP-In-TCP-PUBLIC' -and @($RemoteAddress).Count -eq 2 -and
            $RemoteAddress -contains '192.168.50.0/24' -and $RemoteAddress -contains '10.6.0.3'
        }
    }
    It 'leaves WinRM untouched when only RDP was chosen' {
        $script:testPlan.EnableWinRM = $false
        $script:testPlan.RuleNames = @('RemoteDesktop*')
        $script:testPlan.Rules = @($script:testPlan.Rules | Where-Object Name -like 'RemoteDesktop*')
        Invoke-LanRemoteAccessSetup -Plan $script:testPlan | Out-Null
        Assert-MockCalled Enable-PSRemoting -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-JindaPowerShell7Remoting -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-Item -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-WSManInstance -Times 0 -Exactly -Scope It
        Assert-MockCalled Get-WSManInstance -Times 0 -Exactly -Scope It
        Assert-MockCalled Test-WSMan -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-NetFirewallRule -Times 0 -Exactly -Scope It -ParameterFilter { $Name -like 'WINRM-*' }
        Assert-MockCalled Start-Service -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'TermService' }
    }
    It 'leaves RDP untouched when only WinRM was chosen' {
        $script:testPlan.EnableRemoteDesktop = $false
        $script:testPlan.RuleNames = @('WINRM-*')
        $script:testPlan.Rules = @($script:testPlan.Rules | Where-Object Name -like 'WINRM-*')
        Invoke-LanRemoteAccessSetup -Plan $script:testPlan | Out-Null
        Assert-MockCalled Enable-PSRemoting -Times 1 -Exactly -Scope It -ParameterFilter { $Force -and $SkipNetworkProfileCheck -and -not $Confirm }
        Assert-MockCalled Set-NetFirewallRule -Times 0 -Exactly -Scope It -ParameterFilter { $Name -like 'RemoteDesktop*' }
        Assert-MockCalled Set-ItemProperty -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-Service -Times 0 -Exactly -Scope It
        Assert-MockCalled Start-Service -Times 0 -Exactly -Scope It
    }
    It 'makes no changes in a direct WhatIf preview' {
        Invoke-LanRemoteAccessSetup -Plan $script:testPlan -WhatIf
        Assert-MockCalled Enable-PSRemoting -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-JindaPowerShell7Remoting -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-NetFirewallRule -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-ItemProperty -Times 0 -Exactly -Scope It
        Assert-MockCalled Start-Service -Times 0 -Exactly -Scope It
        Assert-MockCalled New-NetFirewallRule -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-WSManInstance -Times 0 -Exactly -Scope It
        Assert-MockCalled Get-WSManInstance -Times 0 -Exactly -Scope It
    }
}
