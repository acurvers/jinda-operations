# Offline tests; CLI calls, services and browser launches are simulated.
if ($env:JINDA_TEST_TAILSCALE_REF) {
    $source = & git show ($env:JINDA_TEST_TAILSCALE_REF + ':configure-tailscale.ps1')
    if ($LASTEXITCODE) { throw 'Cannot load the candidate script from Git.' }
    . ([scriptblock]::Create(($source -join "`n")))
} else {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'configure-tailscale.ps1')
}

Describe 'Optional single-host Tailscale subnet router' {
    BeforeEach {
        $script:routerAddresses = @(
            [pscustomobject]@{ IPAddress = '192.168.40.20'; PrefixLength = 24; InterfaceIndex = 7; InterfaceAlias = 'Ethernet'; AddressState = 'Preferred' }
            [pscustomobject]@{ IPAddress = '100.77.66.55'; PrefixLength = 32; InterfaceIndex = 9; InterfaceAlias = 'Tailscale'; AddressState = 'Preferred' }
            [pscustomobject]@{ IPAddress = '10.8.0.5'; PrefixLength = 24; InterfaceIndex = 11; InterfaceAlias = 'Other LAN'; AddressState = 'Preferred' }
        )
        $script:routerForwarding = @{}
        foreach ($index in @(7,9,11)) { foreach ($store in @('ActiveStore','PersistentStore')) { $script:routerForwarding["${store}:$index"] = 'Disabled' } }
        $script:routerRoutes = '10.20.0.0/16'
        $script:routerSetExit = 0
        $script:routerUnattended = $false
        $script:routerRouteNextHop = '0.0.0.0'
        $script:routerRunning = 'Running'
        Mock Get-JindaTailscaleCliPath { 'fake-tailscale.exe' }
        Mock Get-JindaTailscaleStatus { [pscustomobject]@{ BackendState = $script:routerRunning; TailscaleIPs = @('100.77.66.55') } }
        Mock Get-NetIPAddress { $script:routerAddresses }
        Mock Find-NetRoute { [pscustomobject]@{ NextHop = $script:routerRouteNextHop; InterfaceIndex = 7; DestinationPrefix = '192.168.40.0/24' } }
        Mock Get-NetIPInterface {
            [pscustomobject]@{ InterfaceIndex = $InterfaceIndex; Forwarding = $script:routerForwarding["${PolicyStore}:$InterfaceIndex"] }
        }
        Mock Set-NetIPInterface {
            foreach ($store in @('ActiveStore','PersistentStore')) { $script:routerForwarding["${store}:$InterfaceIndex"] = 'Enabled' }
        }
        Mock Initialize-JindaTailscale {}
        Mock Test-JindaSubnetTargetRdp { $true }
        Mock Invoke-JindaTailscaleCli {
            if ($Arguments[0] -eq 'get') {
                return [pscustomobject]@{ ExitCode = 0; Output = (@{ 'accept-dns' = $false; 'accept-routes' = $false; 'exit-node' = ''; 'advertise-routes' = $script:routerRoutes; 'unattended' = $script:routerUnattended } | ConvertTo-Json -Compress); Error = '' }
            }
            if ($Arguments[0] -eq 'set' -and $Arguments[1] -like '--advertise-routes=*') {
                if ($script:routerSetExit -eq 0) {
                    $script:routerRoutes = $Arguments[1].Substring('--advertise-routes='.Length)
                    if ($Arguments -contains '--unattended=true') { $script:routerUnattended = $true }
                }
                return [pscustomobject]@{ ExitCode = $script:routerSetExit; Output = ''; Error = 'simulated route error' }
            }
            throw 'Unexpected router CLI call'
        }
    }
    It 'adds only the requested /32 and preserves existing advertisements' {
        Enable-JindaSubnetRouter
        $script:routerRoutes | Should Be '10.20.0.0/16,192.168.40.13/32'
        Assert-MockCalled Set-NetIPInterface -Times 2 -Exactly -Scope It -ParameterFilter { $InterfaceIndex[0] -in @(7,9) -and $Forwarding -eq 'Enabled' -and -not $PolicyStore }
        Assert-MockCalled Set-NetIPInterface -Times 0 -Exactly -Scope It -ParameterFilter { $InterfaceIndex -eq 11 }
        Assert-MockCalled Initialize-JindaTailscale -Times 1 -Exactly -Scope It
    }
    It 'refuses to run on the target Server 2012 host itself' {
        $script:routerAddresses[0].IPAddress = '192.168.40.13'
        { Enable-JindaSubnetRouter } | Should Throw 'not on 192.168.40.13 itself'
        Assert-MockCalled Set-NetIPInterface -Times 0 -Exactly -Scope It
        Assert-MockCalled Initialize-JindaTailscale -Times 0 -Exactly -Scope It
    }
    It 'requires a directly connected LAN and does not use an unrelated gateway' {
        $script:routerRouteNextHop = '192.168.40.1'
        { Enable-JindaSubnetRouter } | Should Throw 'reachable directly'
        Assert-MockCalled Set-NetIPInterface -Times 0 -Exactly -Scope It
    }
    It 'does not configure forwarding without an active Tailscale login' {
        $script:routerRunning = 'NeedsLogin'
        { Enable-JindaSubnetRouter } | Should Throw 'Sign in to Tailscale first'
        Assert-MockCalled Set-NetIPInterface -Times 0 -Exactly -Scope It
    }
    It 'requires an explicit LAN address when multiple LAN addresses match' {
        $script:routerAddresses += [pscustomobject]@{ IPAddress = '192.168.40.21'; PrefixLength = 24; InterfaceIndex = 12; InterfaceAlias = 'Second LAN'; AddressState = 'Preferred' }
        { Get-JindaSubnetRouterPlan -Path 'fake.exe' } | Should Throw 'Supply -LanIPAddress'
        (Get-JindaSubnetRouterPlan -Path 'fake.exe' -LanIPAddress '192.168.40.20').Lan.IPAddress | Should Be '192.168.40.20'
    }
    It 'does not duplicate an already advertised /32 on a later run' {
        $script:routerRoutes = '10.20.0.0/16,192.168.40.13/32'
        Enable-JindaSubnetRouter
        $script:routerRoutes | Should Be '10.20.0.0/16,192.168.40.13/32'
    }
    It 'fails if forwarding did not persist rather than claiming success' {
        Mock Set-NetIPInterface { $script:routerForwarding["ActiveStore:$InterfaceIndex"] = 'Enabled' }
        { Enable-JindaSubnetRouter } | Should Throw 'not enabled in PersistentStore'
    }
    It 'fails when Tailscale rejects advertising the route' {
        $script:routerSetExit = 1
        { Enable-JindaSubnetRouter } | Should Throw 'Could not advertise'
    }
    It 'can verify persisted settings after a restart without reapplying anything' {
        foreach ($index in @(7,9)) { foreach ($store in @('ActiveStore','PersistentStore')) { $script:routerForwarding["${store}:$index"] = 'Enabled' } }
        $script:routerRoutes = '192.168.40.13/32'
        $script:routerUnattended = $true
        Enable-JindaSubnetRouter -VerifyOnly
        Assert-MockCalled Set-NetIPInterface -Times 0 -Exactly -Scope It
        Assert-MockCalled Initialize-JindaTailscale -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-JindaTailscaleCli -Times 0 -Exactly -Scope It -ParameterFilter { $Arguments[0] -eq 'set' }
    }
    It 'reports an RDP reachability problem on the destination separately from the route setup' {
        Mock Test-JindaSubnetTargetRdp { $false }
        Enable-JindaSubnetRouter -WarningVariable warning
        ($warning -join ' ') | Should Match 'Windows Firewall with Advanced Security on 192.168.40.13, allowing source 192.168.40.20'
    }
    It 'does not inspect or change routing in WhatIf' {
        Enable-JindaSubnetRouter -WhatIf
        Assert-MockCalled Get-NetIPAddress -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-NetIPInterface -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-JindaTailscaleCli -Times 0 -Exactly -Scope It
    }
}

Describe 'Standalone Tailscale script and start command' {
    It 'captures native output, error output and nonzero exit codes without a visible console' {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("Write-Output 'test-output'; [Console]::Error.WriteLine('test-error'); exit 3"))
        $result = Invoke-JindaTailscaleCli -Path "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -Arguments @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)
        $result.ExitCode | Should Be 3
        $result.Output | Should Match 'test-output'
        $result.Error | Should Match 'test-error'
    }
    It 'requires an existing installation without app, password or RDP setup' {
        $text = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'configure-tailscale.ps1'))
        $text | Should Not Match 'winget|Install-Language|Enable-PSRemoting|New-NetFirewallRule|LimitBlankPasswordUse|--auth-key'
        $text | Should Match '#Requires -Version 5.1'
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
        $errors.Count | Should Be 0
    }
    It 'verifies the downloaded script hash before running the one-liner' {
        $root = Split-Path $PSScriptRoot -Parent
        $page = [IO.File]::ReadAllText((Join-Path $root 'tailscale.html'))
        $command = [Net.WebUtility]::HtmlDecode([regex]::Match($page, '<code id="tailscale-code">(.*?)</code>').Groups[1].Value)
        $hash = (Get-FileHash (Join-Path $root 'configure-tailscale.ps1') -Algorithm SHA256).Hash
        $command | Should Match $hash
        $command.IndexOf('Get-FileHash') | Should BeLessThan $command.IndexOf('powershell.exe')
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseInput($command, [ref]$tokens, [ref]$errors)
        $errors.Count | Should Be 0
    }
    It 'provides a separate copied command for only the subnet-router option' {
        $root = Split-Path $PSScriptRoot -Parent
        $page = [IO.File]::ReadAllText((Join-Path $root 'tailscale.html'))
        $command = [Net.WebUtility]::HtmlDecode([regex]::Match($page, '<code id="subnetrouter-code">(.*?)</code>').Groups[1].Value)
        $command | Should Match '-File \$p -SubnetRouter'
        $hash = (Get-FileHash (Join-Path $root 'configure-tailscale.ps1') -Algorithm SHA256).Hash
        $command | Should Match $hash
        $page | Should Match "bindCopy\('copy-subnetrouter-command', 'subnetrouter-code', 'copy-subnetrouter-status'\)"
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseInput($command, [ref]$tokens, [ref]$errors)
        $errors.Count | Should Be 0
    }
}

$entryFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'configure-tailscale.ps1'
$entryAst = [Management.Automation.Language.Parser]::ParseFile($entryFile, [ref]$null, [ref]$null)
$entryTry = $entryAst.EndBlock.Statements[-1].Clauses[0].Item2.Statements[0]
$entryBody = ($entryTry.Body.Statements | Where-Object { $_ -isnot [Management.Automation.Language.ExitStatementAst] } | ForEach-Object { $_.Extent.Text }) -join "`n"
$script:tailscaleEntry = [scriptblock]::Create($entryBody.Replace('$PSCommandPath', "'C:\Test Folder\configure-tailscale.ps1'"))

Describe 'Subnet-router flags survive runtime relaunch' {
    BeforeEach {
        $SubnetRouter = $false; $VerifySubnetRouter = $false; $LanIPAddress = ''; $RuntimeReady = $false
        Mock Invoke-JindaManagedScript { & $Work }
        Mock Initialize-JindaTailscale {}
        Mock Enable-JindaSubnetRouter {}
    }
    It 'forwards the explicit subnet-router option and local LAN address' {
        $SubnetRouter = $true; $LanIPAddress = '192.168.40.20'
        & $script:tailscaleEntry
        Assert-MockCalled Invoke-JindaManagedScript -Times 1 -Exactly -Scope It -ParameterFilter { ($ScriptArguments -join ' ') -eq '-SubnetRouter -LanIPAddress 192.168.40.20' }
        Assert-MockCalled Enable-JindaSubnetRouter -Times 1 -Exactly -Scope It -ParameterFilter { -not $VerifyOnly -and $LanIPAddress -eq '192.168.40.20' }
    }
    It 'forwards verify-only mode without applying the normal preferences' {
        $VerifySubnetRouter = $true
        & $script:tailscaleEntry
        Assert-MockCalled Invoke-JindaManagedScript -Times 1 -Exactly -Scope It -ParameterFilter { ($ScriptArguments -join ' ') -eq '-VerifySubnetRouter' }
        Assert-MockCalled Enable-JindaSubnetRouter -Times 1 -Exactly -Scope It -ParameterFilter { $VerifyOnly }
        Assert-MockCalled Initialize-JindaTailscale -Times 0 -Exactly -Scope It
    }
    It 'keeps ordinary setup free of subnet-router changes' {
        & $script:tailscaleEntry
        Assert-MockCalled Initialize-JindaTailscale -Times 1 -Exactly -Scope It
        Assert-MockCalled Enable-JindaSubnetRouter -Times 0 -Exactly -Scope It
    }
    It 'rejects conflicting routing modes before any work' {
        $SubnetRouter = $true; $VerifySubnetRouter = $true
        { & $script:tailscaleEntry } | Should Throw 'not both'
        Assert-MockCalled Invoke-JindaManagedScript -Times 0 -Exactly -Scope It
    }
}

Describe 'Tailscale preferences and browser sign-in' {
    BeforeEach {
        $script:tailscaleCalls = New-Object 'System.Collections.Generic.List[object]'
        $script:tailscaleState = 'Running'
        $script:tailscaleAfterUp = 'NeedsLogin'
        $script:tailscaleAuthURL = 'https://login.tailscale.com/a/example-test-only'
        $script:tailscalePrefs = '{"accept-dns":false,"accept-routes":false,"exit-node":""}'
        $script:tailscaleSetExit = 0
        $script:tailscaleUpExit = 1
        $script:tailscaleUpError = 'timeout waiting for Tailscale service to enter a Running state'
        Mock Get-JindaTailscaleCliPath { 'fake-tailscale.exe' }
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock Start-Service { throw 'Unexpected service change' }
        Mock Get-Process { [pscustomobject]@{ SessionId = 1 } } -ParameterFilter { $Id -contains $PID }
        Mock Start-Process {}
        Mock Invoke-JindaTailscaleCli {
            $script:tailscaleCalls.Add(@($Arguments))
            switch ($Arguments[0]) {
                'set' { return [pscustomobject]@{ ExitCode = $script:tailscaleSetExit; Output = ''; Error = 'simulated set failure' } }
                'get' { return [pscustomobject]@{ ExitCode = 0; Output = $script:tailscalePrefs; Error = '' } }
                'status' {
                    return [pscustomobject]@{ ExitCode = 0; Output = (@{ BackendState = $script:tailscaleState; AuthURL = $script:tailscaleAuthURL } | ConvertTo-Json -Compress); Error = '' }
                }
                'up' {
                    $script:tailscaleState = $script:tailscaleAfterUp
                    return [pscustomobject]@{ ExitCode = $script:tailscaleUpExit; Output = ''; Error = $script:tailscaleUpError }
                }
                default { throw 'Unexpected Tailscale command' }
            }
        }
    }

    It 'sets exactly DNS off, subnet routes off and no exit node without replacing an existing login' {
        Initialize-JindaTailscale
        ($script:tailscaleCalls[0] -join ' ') | Should Be 'set --accept-dns=false --accept-routes=false --exit-node='
        (@($script:tailscaleCalls | ForEach-Object { $_ -join ' ' }) -join ';') | Should Not Match '\blogin\b|logout|force-reauth|--reset|--auth-key|--login-server'
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
        @($script:tailscaleCalls | Where-Object { $_[0] -eq 'up' }).Count | Should Be 0
    }
    It 'opens the official browser sign-in without waiting for the customer to authenticate' {
        $script:tailscaleState = 'NeedsLogin'
        Initialize-JindaTailscale
        Assert-MockCalled Start-Process -Times 1 -Exactly -Scope It -ParameterFilter { $FilePath -eq 'https://login.tailscale.com/a/example-test-only' }
        $up = @($script:tailscaleCalls | Where-Object { $_[0] -eq 'up' })
        ($up[0] -join ' ') | Should Be 'up --json --timeout=5s --accept-dns=false --accept-routes=false --exit-node='
    }
    It 'does not treat missing preference values or policy-enforced values as success' {
        $script:tailscalePrefs = '{"accept-dns":true,"accept-routes":false,"exit-node":""}'
        { Initialize-JindaTailscale } | Should Throw 'could not be verified'
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }
    It 'rejects an exit node left enabled after configuration' {
        $script:tailscalePrefs = '{"accept-dns":false,"accept-routes":false,"exit-node":"100.64.0.5"}'
        { Initialize-JindaTailscale } | Should Throw 'could not be verified'
    }
    It 'stops before authentication when applying preferences fails' {
        $script:tailscaleSetExit = 1
        { Initialize-JindaTailscale } | Should Throw 'Could not configure Tailscale'
        $script:tailscaleCalls.Count | Should Be 1
    }
    It 'rejects a non-Tailscale authentication URL' {
        $script:tailscaleState = 'NeedsLogin'
        $script:tailscaleAuthURL = 'https://login.tailscale.com.attacker.example/a/test'
        { Initialize-JindaTailscale } | Should Throw 'valid official browser sign-in URL'
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }
    It 'reports pending device approval without claiming a completed connection' {
        $script:tailscaleState = 'NeedsLogin'
        $script:tailscaleAfterUp = 'NeedsMachineAuth'
        Initialize-JindaTailscale -WarningVariable pending
        ($pending -join ' ') | Should Match 'requires device approval'
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }
    It 'does not hide non-timeout connection errors behind a pending login' {
        $script:tailscaleState = 'NeedsLogin'
        $script:tailscaleUpError = 'permission denied'
        { Initialize-JindaTailscale } | Should Throw 'connection setup failed'
    }
    It 'shows the sign-in URL rather than opening a browser in a service session' {
        $script:tailscaleState = 'NeedsLogin'
        Mock Get-Process { [pscustomobject]@{ SessionId = 0 } } -ParameterFilter { $Id -contains $PID }
        Initialize-JindaTailscale -WarningVariable pending
        ($pending -join ' ') | Should Match 'Open this URL in a browser'
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }
    It 'provides the URL if Windows cannot launch the default browser' {
        $script:tailscaleState = 'NeedsLogin'
        Mock Start-Process { throw 'No browser configured' }
        Initialize-JindaTailscale -WarningVariable pending
        ($pending -join ' ') | Should Match 'Open this sign-in URL yourself'
    }
    It 'does not probe the CLI, start a service or launch a browser during WhatIf' {
        Initialize-JindaTailscale -WhatIf
        Assert-MockCalled Invoke-JindaTailscaleCli -Times 0 -Exactly -Scope It
        Assert-MockCalled Start-Service -Times 0 -Exactly -Scope It
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }
}
