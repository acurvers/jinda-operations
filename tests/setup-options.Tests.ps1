. (Join-Path (Split-Path -Parent $PSScriptRoot) 'init.ps1')

Describe 'Choices are collected once before unattended setup' {
    BeforeEach {
        $script:answers = New-Object 'System.Collections.Generic.Queue[string]'
        $script:prompts = New-Object 'System.Collections.Generic.List[string]'
        Mock Read-Host { $script:prompts.Add($Prompt); $script:answers.Dequeue() }
        Mock Select-JindaLanAddress { '10.20.30.40' }
    }

    It 'asks apps first, then RDP and WinRM, with apps yes and remote no as defaults' {
        foreach ($answer in @('', '', '')) { $script:answers.Enqueue($answer) }
        $options = Get-JindaSetupOptions
        $options.InstallApps | Should Be $true
        $options.RemoteDesktop | Should Be $false
        $options.PowerShellRemoting | Should Be $false
        $script:prompts.Count | Should Be 3
        $script:prompts[0] | Should Match 'Apps.*\[Y/n\]'
        $script:prompts[1] | Should Match 'Remote Desktop.*\[y/N\]'
        $script:prompts[2] | Should Match 'WinRM.*\[y/N\]'
        Assert-MockCalled Select-JindaLanAddress -Times 0 -Exactly -Scope It
    }

    It 'accepts independent yes/no choices and selects the LAN before returning' {
        foreach ($answer in @('n', 'y', 'n')) { $script:answers.Enqueue($answer) }
        $options = Get-JindaSetupOptions
        $options.InstallApps | Should Be $false
        $options.RemoteDesktop | Should Be $true
        $options.PowerShellRemoting | Should Be $false
        $options.LanIPAddress | Should Be '10.20.30.40'
        Assert-MockCalled Select-JindaLanAddress -Times 1 -Exactly -Scope It
    }

    It 'reprompts invalid answers and accepts Dutch yes' {
        foreach ($answer in @('maybe', ' JA ')) { $script:answers.Enqueue($answer) }
        Read-JindaYesNo -Prompt 'Test' | Should Be $true
        $script:prompts.Count | Should Be 2
    }

    It 'uses explicit parameter choices without prompts' {
        $options = Get-JindaSetupOptions -InstallApps No -RemoteDesktop No -PowerShellRemoting Yes -LanIPAddress '10.20.30.40'
        $options.InstallApps | Should Be $false
        $options.RemoteDesktop | Should Be $false
        $options.PowerShellRemoting | Should Be $true
        Assert-MockCalled Read-Host -Times 0 -Exactly -Scope It
        Assert-MockCalled Select-JindaLanAddress -Times 1 -Exactly -Scope It -ParameterFilter { $Address -eq '10.20.30.40' }
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
