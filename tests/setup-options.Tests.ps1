. (Join-Path (Split-Path -Parent $PSScriptRoot) 'init.ps1')

Describe 'Choices are collected once before unattended setup' {
    BeforeEach {
        $script:answers = New-Object 'System.Collections.Generic.Queue[string]'
        $script:prompts = New-Object 'System.Collections.Generic.List[string]'
        Mock Read-Host { $script:prompts.Add($Prompt); $script:answers.Dequeue() }
        Mock Select-JindaLanAddress { '10.20.30.40' }
    }

    It 'defaults to essential apps only and prompts for both groups before other options' {
        foreach ($answer in @('', '', '', '', '', '')) { $script:answers.Enqueue($answer) }
        $options = Get-JindaSetupOptions
        $options.InstallEssentialApps | Should Be $true
        $options.InstallOptionalApps | Should Be $false
        $options.RemoteDesktop | Should Be $false
        $options.PowerShellRemoting | Should Be $false
        $options.OpenSSH | Should Be $false
        $options.RemoveBundledApps | Should Be $false
        $script:prompts.Count | Should Be 6
        $script:prompts[0] | Should Be 'Install essential apps (VS Code, Everything, Notepad++, Chrome and LastPass)? [Y/n]'
        $script:prompts[1] | Should Be 'Install optional apps? [y/N]'
        $script:prompts[2] | Should Be 'Enable Remote Desktop (RDP) on the LAN? (N = skip; leave existing settings unchanged) [y/N]'
        $script:prompts[3] | Should Be 'Enable PowerShell remoting (WinRM) on the LAN? (N = skip; leave existing settings unchanged) [y/N]'
        $script:prompts[4] | Should Be 'Install OpenSSH for the selected LAN and authorize the salon SSH key for local users? (N = skip) [y/N]'
        $script:prompts[5] | Should Be 'Uninstall LinkedIn and Microsoft Solitaire Collection? [y/N]'
        Assert-MockCalled Select-JindaLanAddress -Times 0 -Exactly -Scope It
    }

    It 'accepts independent yes/no choices and selects the LAN before returning' {
        foreach ($answer in @('n', 'y', 'y', 'n', 'y', 'y')) { $script:answers.Enqueue($answer) }
        $options = Get-JindaSetupOptions
        $options.InstallEssentialApps | Should Be $false
        $options.InstallOptionalApps | Should Be $true
        $options.RemoteDesktop | Should Be $true
        $options.PowerShellRemoting | Should Be $false
        $options.LanIPAddress | Should Be '10.20.30.40'
        $options.OpenSSH | Should Be $true
        $options.RemoveBundledApps | Should Be $true
        Assert-MockCalled Select-JindaLanAddress -Times 1 -Exactly -Scope It
    }

    It 'reprompts invalid answers and accepts Dutch yes' {
        foreach ($answer in @('maybe', ' JA ')) { $script:answers.Enqueue($answer) }
        Read-JindaYesNo -Prompt 'Test' | Should Be $true
        $script:prompts.Count | Should Be 2
    }

    It 'selects the LAN when SSH is the only remote access option' {
        $options = Get-JindaSetupOptions -InstallApps No -RemoteDesktop No -PowerShellRemoting No -OpenSSH Yes -RemoveBundledApps No
        $options.LanIPAddress | Should Be '10.20.30.40'
        Assert-MockCalled Select-JindaLanAddress -Times 1 -Exactly -Scope It
    }

    It 'uses explicit parameter choices without prompts' {
        $options = Get-JindaSetupOptions -InstallEssentialApps No -InstallOptionalApps Yes -RemoteDesktop No -PowerShellRemoting Yes -OpenSSH Yes -RemoveBundledApps Yes -LanIPAddress '10.20.30.40'
        $options.InstallEssentialApps | Should Be $false
        $options.InstallOptionalApps | Should Be $true
        $options.RemoteDesktop | Should Be $false
        $options.PowerShellRemoting | Should Be $true
        $options.OpenSSH | Should Be $true
        $options.RemoveBundledApps | Should Be $true
        Assert-MockCalled Read-Host -Times 0 -Exactly -Scope It
        Assert-MockCalled Select-JindaLanAddress -Times 1 -Exactly -Scope It -ParameterFilter { $Address -eq '10.20.30.40' }
    }

    It 'uses the legacy app choice for both groups unless a group is explicitly set' {
        $options = Get-JindaSetupOptions -InstallApps Yes -RemoteDesktop No -PowerShellRemoting No -OpenSSH No -RemoveBundledApps No
        $options.InstallEssentialApps | Should Be $true
        $options.InstallOptionalApps | Should Be $true
        $options = Get-JindaSetupOptions -InstallApps No -InstallEssentialApps Yes -RemoteDesktop No -PowerShellRemoting No -OpenSSH No -RemoveBundledApps No
        $options.InstallEssentialApps | Should Be $true
        $options.InstallOptionalApps | Should Be $false
        Assert-MockCalled Read-Host -Times 0 -Exactly -Scope It
    }
}

Describe 'LAN selection at startup' {
    BeforeEach {
        $script:addresses = @(
            [pscustomobject]@{ IPAddress='10.20.30.40'; PrefixLength=24; InterfaceAlias='Ethernet'; InterfaceIndex=7; AddressState='Preferred' }
        )
        Mock Get-NetIPAddress { $script:addresses }
        Mock Read-Host { '2' }
    }

    It 'selects the only active address without another question' {
        Select-JindaLanAddress | Should Be '10.20.30.40'
        Assert-MockCalled Read-Host -Times 0 -Exactly -Scope It
    }

    It 'asks which interface when multiple addresses are active' {
        $script:addresses += [pscustomobject]@{ IPAddress='10.40.50.60'; PrefixLength=24; InterfaceAlias='Wi-Fi'; InterfaceIndex=9; AddressState='Preferred' }
        Select-JindaLanAddress | Should Be '10.40.50.60'
        Assert-MockCalled Read-Host -Times 1 -Exactly -Scope It
    }

    It 'uses an explicit active IPv4 address without asking' {
        Select-JindaLanAddress -Address '10.20.30.40' | Should Be '10.20.30.40'
        Assert-MockCalled Read-Host -Times 0 -Exactly -Scope It
    }

    It 'rejects inactive addresses and IPv6' {
        { Select-JindaLanAddress -Address '10.20.30.99' } | Should Throw 'exactly one active interface'
        { Select-JindaLanAddress -Address '::1' } | Should Throw 'IPv4'
    }

    It 'does not select loopback or APIPA as the LAN' {
        $script:addresses[0].IPAddress = '127.0.0.1'
        { Select-JindaLanAddress } | Should Throw 'No active IPv4 LAN'
        $script:addresses[0].IPAddress = '169.254.1.2'
        { Select-JindaLanAddress } | Should Throw 'No active IPv4 LAN'
    }
}
