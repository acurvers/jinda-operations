$projectPath = Split-Path -Parent $PSScriptRoot
$html = [IO.File]::ReadAllText((Join-Path $projectPath 'index.html'))
$code = [Net.WebUtility]::HtmlDecode([regex]::Match($html, '(?s)<code id="init-code">(.*?)</code>').Groups[1].Value)
$script:pageCode = [scriptblock]::Create($code)

function powershell.exe {
    $script:launches.Add(@($args))
    $global:LASTEXITCODE = 0
}

Describe 'Published initialization one-liner' {
    BeforeEach {
        $script:launches = New-Object 'System.Collections.Generic.List[object]'
        Mock Invoke-WebRequest {}
    }

    It 'downloads init and starts that exact file in a separate PowerShell process' {
        & $script:pageCode
        $script:launches.Count | Should Be 1
        ($script:launches[0] -join ' ') | Should Match 'jinda-init.ps1'
        ($script:launches[0] -contains '-NoProfile') | Should Be $true
        ($script:launches[0] -contains 'Bypass') | Should Be $true
        ($script:launches[0] -contains '-WhatIf') | Should Be $false
        Assert-MockCalled Invoke-WebRequest -Times 1 -Exactly -Scope It -ParameterFilter {
            $Uri -eq 'https://acurvers.github.io/jinda-operations/init.ps1' -and
            $OutFile -eq (Join-Path $env:TEMP 'jinda-init.ps1')
        }
    }

    It 'does not launch an old local init when its download fails' {
        $ErrorActionPreference = 'Continue'
        Mock Invoke-WebRequest { Write-Error 'Download failed' }
        { & $script:pageCode } | Should Throw 'Download failed'
        $script:launches.Count | Should Be 0
    }

    It 'uses the same single-line command in the page and README' {
        $code | Should Not BeNullOrEmpty
        $code | Should Not Match '\r|\n'
        ([IO.File]::ReadAllText((Join-Path $projectPath 'README.md')).Contains($code)) | Should Be $true
    }
}
