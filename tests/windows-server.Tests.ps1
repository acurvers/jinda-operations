# Offline tests only: no server settings or services are changed.
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'windows-server\Enable-ServerRemoteAccess.ps1')

Describe 'Server 2012 input and compatibility' {
    It 'calculates LAN subnets without signed integer overflow' {
        Get-ServerSubnet '192.168.40.20' 24 | Should Be '192.168.40.0/24'
        Get-ServerSubnet '10.6.0.3' 32 | Should Be '10.6.0.3/32'
        Get-ServerSubnet '172.19.244.1' 20 | Should Be '172.19.240.0/20'
    }
    It 'accepts explicit IPv4 addresses and subnets from a command line or prompt' {
        (@(ConvertTo-ServerAllowedAddresses @('192.168.40.0/24, 10.6.0.3', '10.6.0.3')) -join ',') | Should Be '192.168.40.0/24,10.6.0.3'
    }
    It 'rejects unrestricted, malformed and IPv6 sources' {
        foreach ($badAddress in @('Any', '0.0.0.0/0', '::/0', '999.1.1.1', '10.1', '10.1.1.1/33', 'server.local', '')) {
            { ConvertTo-ServerAllowedAddresses @($badAddress) } | Should Throw
        }
    }
    It 'explains that N skips configuration and leaves existing settings alone' {
        Mock Read-Host { 'n' }
        Read-ServerYesNo 'Enable RDP?' | Should Be $false
        Assert-MockCalled Read-Host -ParameterFilter { $Prompt -like '*N = skip; leave existing settings unchanged*' } -Times 1 -Exactly
    }
    It 'does not prompt when all choices are explicit' {
        Mock Read-Host { throw 'Unexpected prompt' }
        Read-ServerYesNo 'RDP?' 'Yes' | Should Be $true
        Read-ServerYesNo 'WinRM?' 'No' | Should Be $false
        Assert-MockCalled Read-Host -Times 0 -Exactly -Scope It
    }
    It 'has no post-PowerShell-3 syntax or dependencies in the server entry point' {
        $text = [IO.File]::ReadAllText((Join-Path $root 'windows-server\Enable-ServerRemoteAccess.ps1'))
        $text | Should Match '#Requires -Version 3.0'
        $text | Should Not Match '::new\(|\[Parameter\(DontShow|Expand-Archive|Get-FileHash|Get-LocalUser|Install-Module|winget|Install-Language|Set-WinUserLanguageList|LimitBlankPasswordUse|net\.exe accounts'
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
        $errors.Count | Should Be 0
    }
    It 'previews setup without elevation, logs, network or settings changes' {
        Mock Test-ServerAdministrator { throw 'Unexpected probe in WhatIf' }
        Mock New-Item { throw 'Unexpected write' }
        Mock Start-Process { throw 'Unexpected process' }
        Start-ServerRemoteAccess -Options @{} -ScriptPath 'example.ps1' -WhatIf
        Assert-MockCalled Start-Process -Times 0 -Exactly
        Assert-MockCalled New-Item -Times 0 -Exactly
    }
}

Describe 'Server 2012 preflight' {
    $lan = [pscustomobject]@{ IPAddress = '192.168.40.20'; PrefixLength = 24; InterfaceIndex = 12; InterfaceAlias = 'Ethernet' }
    BeforeEach {
    Mock Get-NetConnectionProfile { [pscustomobject]@{ NetworkCategory = 'DomainAuthenticated' } }
    Mock Get-NetFirewallProfile { [pscustomobject]@{ Enabled = 'True'; AllowLocalFirewallRules = 'NotConfigured' } }
    Mock Get-NetFirewallRule {
        foreach ($n in @('RemoteDesktop-UserMode-In-TCP', 'RemoteDesktop-UserMode-In-UDP', 'WINRM-HTTP-In-TCP')) {
            if (@($Name | Where-Object { $n -like $_ }).Count) {
                [pscustomobject]@{ Name = $n; Direction = 'Inbound'; PolicyStoreSourceType = 'Local' }
            }
        }
    }
    Mock Get-ItemProperty {
        if ($LiteralPath -like '*Policies*') { return $null }
        [pscustomobject]@{ PortNumber = 3390 }
    }
    Mock Set-NetFirewallRule { throw 'Unexpected write in preflight' }
    }
    It 'preserves a nonstandard RDP port and accepts an explicit VPN source' {
        $plan = Get-ServerAccessPlan $lan @('192.168.40.0/24', '10.6.0.3') $true $true $true
        $plan.RdpPort | Should Be 3390
        ($plan.Sources -join ',') | Should Be '192.168.40.0/24,10.6.0.3'
        $plan.Rules.Count | Should Be 3
        Assert-MockCalled Set-NetFirewallRule -Times 0 -Exactly
    }
    It 'refuses centrally managed Windows Firewall rules on the target server' {
        Mock Get-NetFirewallRule { [pscustomobject]@{ Name = 'Jinda-Server-ICMPv4-In'; Direction = 'Inbound'; PolicyStoreSourceType = 'GroupPolicy' } }
        { Get-ServerAccessPlan $lan @('192.168.40.0/24') $false $false $true } | Should Throw 'centrally managed'
    }
    It 'refuses a disabled Windows Firewall profile on the target server' {
        Mock Get-NetFirewallProfile { [pscustomobject]@{ Enabled = 'False' } }
        { Get-ServerAccessPlan $lan @('192.168.40.0/24') $true $true $true } | Should Throw 'must be enabled'
    }
    It 'refuses domain policy denying RDP before writes' {
        Mock Get-ItemProperty { [pscustomobject]@{ fDenyTSConnections = 1 } }
        { Get-ServerAccessPlan $lan @('192.168.40.0/24') $true $false $false } | Should Throw 'denied by policy'
    }
}

Describe 'Server 2012 apply using simulated Windows services' {
    function New-TestServerPlan {
        param([bool]$Rdp, [bool]$Remoting, [bool]$Echo)
        [pscustomobject]@{
            Lan = [pscustomobject]@{ IPAddress = '192.168.40.20'; InterfaceAlias = 'Ethernet' }
            Sources = @('192.168.40.0/24', '10.6.0.3'); Rdp = $Rdp; Remoting = $Remoting; Echo = $Echo; RdpPort = 3390
            Rules = @(); Patterns = @('WINRM-HTTP-In-TCP*')
        }
    }
    BeforeEach {
    Mock Set-NetFirewallRule {}
    Mock New-NetFirewallRule {}
    Mock Set-ItemProperty {}
    Mock Set-Service {}
    Mock Start-Service {}
    Mock Test-WSMan {}
    Mock Get-Item { [pscustomobject]@{ Value = 'false' } }
    Mock Set-Item { throw 'Unneeded WSMan write' }
    Mock Enable-PSRemoting {}
    Mock Get-ServerRuleAddressFilter { [pscustomobject]@{ LocalAddress = @('192.168.40.20'); RemoteAddress = @('192.168.40.0/255.255.255.0', '10.6.0.3') } }
    Mock Get-NetFirewallRule {
        if ($Name -eq 'Jinda-Server-ICMPv4-In' -and $PolicyStore -eq 'PersistentStore') { return }
        [pscustomobject]@{ Name = 'WINRM-HTTP-In-TCP'; Direction = 'Inbound'; Enabled = 'True'; Action = 'Allow' }
    }
    }
    It 'configures ping alone without enabling RDP or WinRM' {
        Invoke-ServerAccessPlan (New-TestServerPlan $false $false $true)
        Assert-MockCalled New-NetFirewallRule -ParameterFilter { $Protocol -eq 'ICMPv4' -and $IcmpType -eq 8 -and $LocalAddress -eq '192.168.40.20' -and $RemoteAddress -contains '10.6.0.3' } -Times 1 -Exactly
        Assert-MockCalled Enable-PSRemoting -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-ItemProperty -Times 0 -Exactly -Scope It
    }
    It 'keeps RDP NLA and the existing port without restarting TermService' {
        Invoke-ServerAccessPlan (New-TestServerPlan $true $false $false)
        Assert-MockCalled Set-NetFirewallRule -ParameterFilter { $LocalPort -eq 3390 } -Times 2 -Exactly -Scope It
        Assert-MockCalled Set-ItemProperty -ParameterFilter { $Name -eq 'UserAuthentication' -and $Value -eq 1 } -Times 1 -Exactly -Scope It
        Assert-MockCalled Enable-PSRemoting -Times 0 -Exactly -Scope It
    }
    It 'reapplies source limits after Enable-PSRemoting and retains secure WSMan defaults' {
        Invoke-ServerAccessPlan (New-TestServerPlan $false $true $false)
        Assert-MockCalled Enable-PSRemoting -Times 1 -Exactly -Scope It
        Assert-MockCalled Set-NetFirewallRule -ParameterFilter { $RemoteAddress -contains '10.6.0.3' -and $InterfaceAlias[0].IsMatch('Ethernet') } -Times 1 -Exactly -Scope It
        Assert-MockCalled Set-Item -Times 0 -Exactly -Scope It
    }
    It 'still reapplies source limits when Enable-PSRemoting fails' {
        Mock Enable-PSRemoting { throw 'simulated remoting failure' }
        { Invoke-ServerAccessPlan (New-TestServerPlan $false $true $false) } | Should Throw 'simulated remoting failure'
        Assert-MockCalled Set-NetFirewallRule -ParameterFilter { $RemoteAddress -contains '10.6.0.3' } -Times 1 -Exactly -Scope It
    }
    It 'fails when effective Windows Firewall sources on the server are broader than requested' {
        Mock Get-ServerRuleAddressFilter { [pscustomobject]@{ LocalAddress = @('192.168.40.20'); RemoteAddress = @('0.0.0.0/0') } }
        { Invoke-ServerAccessPlan (New-TestServerPlan $false $true $false) } | Should Throw 'differ from the plan'
    }
}

Describe 'Server ZIP and start command' {
    It 'packages exactly the reviewed source script and README' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $root 'windows-server.zip'))
        try {
            $zip.Entries.Count | Should Be 2
            foreach ($name in @('Enable-ServerRemoteAccess.ps1', 'README.md')) {
                $stream = $zip.GetEntry($name).Open(); $reader = New-Object IO.StreamReader($stream)
                try { $reader.ReadToEnd() | Should Be ([IO.File]::ReadAllText((Join-Path $root "windows-server\$name"))) }
                finally { $reader.Dispose() }
            }
        } finally { $zip.Dispose() }
    }
    It 'uses TLS, verifies the actual ZIP hash and avoids post-PS3 bootstrap dependencies' {
        $page = [IO.File]::ReadAllText((Join-Path $root 'windows-server.html'))
        $command = [Net.WebUtility]::HtmlDecode([regex]::Match($page, '<code id="server-code">(.*?)</code>').Groups[1].Value)
        $hash = (Get-FileHash (Join-Path $root 'windows-server.zip') -Algorithm SHA256).Hash.ToLowerInvariant()
        $command | Should Match $hash
        $command | Should Match 'SecurityProtocol.*3072'
        $command | Should Match 'ComputeHash'
        $command | Should Match 'ExtractToDirectory'
        $command | Should Not Match 'Expand-Archive|Get-FileHash|::new\('
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseInput($command, [ref]$tokens, [ref]$errors)
        $errors.Count | Should Be 0
    }
}
