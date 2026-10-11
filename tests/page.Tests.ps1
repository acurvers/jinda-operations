$projectPath = Split-Path -Parent $PSScriptRoot
$html = [IO.File]::ReadAllText((Join-Path $projectPath 'index.html'))
$code = [Net.WebUtility]::HtmlDecode([regex]::Match($html, '(?s)<code id="combined-setup-code">(.*?)</code>').Groups[1].Value)
$script:pageCode = [scriptblock]::Create($code)

function powershell.exe {
    $script:launches.Add(@($args))
    $global:LASTEXITCODE = $script:exitCodes[$script:launches.Count - 1]
}

Describe 'Published combined example' {
    BeforeEach {
        $script:launches = New-Object 'System.Collections.Generic.List[object]'
        $script:exitCodes = @(0, 0)
        Mock New-Item {}
        Mock Invoke-WebRequest {}
    }

    It 'downloads both files and runs installation before configuration' {
        & $script:pageCode
        $script:launches.Count | Should Be 2
        ($script:launches[0] -join ' ') | Should Match 'install-software.ps1'
        ($script:launches[1] -join ' ') | Should Match 'set-windows-english.ps1 -Keyboard USInternational'
        Assert-MockCalled Invoke-WebRequest -Times 2 -Exactly -Scope It
    }

    It 'continues with configuration after installer exit code 3010' {
        $script:exitCodes = @(3010, 0)
        { & $script:pageCode } | Should Not Throw
        $script:launches.Count | Should Be 2
    }

    It 'does not configure Windows if installation fails' {
        $script:exitCodes = @(1, 0)
        { & $script:pageCode } | Should Throw 'Software-installatie mislukt'
        $script:launches.Count | Should Be 1
    }

    It 'reports configuration failure' {
        $script:exitCodes = @(0, 1)
        { & $script:pageCode } | Should Throw 'Windows-configuratie mislukt'
    }

    It 'never starts the scripts when a download fails' {
        Mock Invoke-WebRequest { throw 'Download failed' }
        { & $script:pageCode } | Should Throw 'Download failed'
        $script:launches.Count | Should Be 0
    }
}