# Offline tests; CLI calls, services and browser launches are simulated.
if ($env:JINDA_TEST_TAILSCALE_REF) {
    $source = & git show ($env:JINDA_TEST_TAILSCALE_REF + ':configure-tailscale.ps1')
    if ($LASTEXITCODE) { throw 'Cannot load the candidate script from Git.' }
    . ([scriptblock]::Create(($source -join "`n")))
} else {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'configure-tailscale.ps1')
}

Describe 'Standalone Tailscale script and start command' {
    It 'captures native output, error output and nonzero exit codes without a visible console' {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("Write-Output 'test-output'; [Console]::Error.WriteLine('test-error'); exit 3"))
        $result = Invoke-JindaTailscaleCli -Path "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -Arguments @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)
        $result.ExitCode | Should Be 3
        $result.Output | Should Match 'test-output'
        $result.Error | Should Match 'test-error'
    }
    It 'requires an existing installation and does not install apps or configure Windows' {
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
