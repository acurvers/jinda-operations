. (Join-Path (Split-Path -Parent $PSScriptRoot) 'install-software.ps1')

function Invoke-JindaFakeCode {
    $script:codeCalls.Add(@($args))
    if ($args -contains '--install-extension') {
        $global:LASTEXITCODE = $script:codeInstallExit
    }
    else {
        $global:LASTEXITCODE = $script:codeListExit
        $script:codeExtensions
    }
}

Describe 'Finding VS Code after installation' {
    BeforeEach {
        Mock Test-Path { $false }
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'code.cmd' }
    }

    It 'finds a new machine installation without a refreshed PATH' {
        $script:expectedCli = Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd'
        Mock Test-Path { $LiteralPath -eq $script:expectedCli }
        Get-JindaVSCodeCliPath | Should Be $script:expectedCli
        Assert-MockCalled Get-Command -Times 0 -Exactly -Scope It -ParameterFilter { $Name -eq 'code.cmd' }
    }

    It 'finds an existing user installation' {
        $script:expectedCli = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'
        Mock Test-Path { $LiteralPath -eq $script:expectedCli }
        Get-JindaVSCodeCliPath | Should Be $script:expectedCli
    }

    It 'accepts a custom installation exposed through PATH' {
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\Custom VS Code\bin\code.cmd' } } -ParameterFilter { $Name -eq 'code.cmd' }
        Get-JindaVSCodeCliPath | Should Be 'C:\Custom VS Code\bin\code.cmd'
    }

    It 'fails clearly if no VS Code CLI is available' {
        { Get-JindaVSCodeCliPath } | Should Throw 'code.cmd is na installatie niet gevonden'
    }
}

Describe 'Installing the Microsoft PowerShell extension' {
    BeforeEach {
        $script:codeCalls = New-Object 'System.Collections.Generic.List[object]'
        $script:codeInstallExit = 0
        $script:codeListExit = 0
        $script:codeExtensions = @('ms-vscode.powershell', 'another.publisher')
        Mock Get-JindaVSCodeCliPath { 'Invoke-JindaFakeCode' }
    }

    It 'installs or updates without prompts and verifies the installed extension' {
        Install-JindaVSCodePowerShellExtension
        $script:codeCalls.Count | Should Be 2
        ($script:codeCalls[0] -join ' ') | Should Be '--install-extension ms-vscode.PowerShell --force'
        ($script:codeCalls[1] -join ' ') | Should Be '--list-extensions'
    }

    It 'stops when installation fails even if an older extension was present' {
        $script:codeInstallExit = 1
        { Install-JindaVSCodePowerShellExtension } | Should Throw 'installeren is mislukt (exitcode 1)'
        $script:codeCalls.Count | Should Be 1
    }

    It 'rejects a failed verification command' {
        $script:codeListExit = 2
        { Install-JindaVSCodePowerShellExtension } | Should Throw 'extensies controleren is mislukt (exitcode 2)'
    }

    It 'rejects success without the requested extension in the installed list' {
        $script:codeExtensions = @('another.publisher')
        { Install-JindaVSCodePowerShellExtension } | Should Throw 'niet teruggevonden'
    }

    It 'does not locate or execute VS Code during WhatIf' {
        Install-JindaVSCodePowerShellExtension -WhatIf
        $script:codeCalls.Count | Should Be 0
        Assert-MockCalled Get-JindaVSCodeCliPath -Times 0 -Exactly -Scope It
    }
}
