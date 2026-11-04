$projectPath = Split-Path -Parent $PSScriptRoot
$html = [IO.File]::ReadAllText((Join-Path $projectPath 'index.html'))
$code = [Net.WebUtility]::HtmlDecode([regex]::Match($html, '(?s)<code id="init-code">(.*?)</code>').Groups[1].Value)
$script:pageCode = [scriptblock]::Create($code)
$repairCode = [Net.WebUtility]::HtmlDecode([regex]::Match($html, '(?s)<code id="repair-code">(.*?)</code>').Groups[1].Value)
$script:repairPageCode = [scriptblock]::Create($repairCode)

function powershell.exe {
    $script:launches.Add(@($args))
    $global:LASTEXITCODE = 0
}

Describe 'Published initialization one-liner' {
    BeforeEach {
        $script:launches = New-Object 'System.Collections.Generic.List[object]'
        Mock Invoke-WebRequest {}
        Mock Invoke-RestMethod { @{ sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' } }
    }

    It 'downloads init and starts that exact file in a separate PowerShell process' {
        & $script:pageCode
        $script:launches.Count | Should Be 1
        ($script:launches[0] -join ' ') | Should Match 'jinda-init.ps1'
        ($script:launches[0] -contains '-NoProfile') | Should Be $true
        ($script:launches[0] -contains 'Bypass') | Should Be $true
        ($script:launches[0] -contains '-WhatIf') | Should Be $false
        ($script:launches[0] -join ' ') | Should Match '-SourceCommit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        Assert-MockCalled Invoke-RestMethod -Times 1 -Exactly -Scope It
        Assert-MockCalled Invoke-WebRequest -Times 1 -Exactly -Scope It -ParameterFilter {
            $Uri -eq 'https://raw.githubusercontent.com/acurvers/jinda-operations/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/init.ps1' -and
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
        $repairCode | Should Not Match '\r|\n'
        ([IO.File]::ReadAllText((Join-Path $projectPath 'README.md')).Contains($repairCode)) | Should Be $true
    }

    It 'pins the repair command to the same version and retains the repair switch' {
        & $script:repairPageCode
        $script:launches.Count | Should Be 1
        ($script:launches[0] -join ' ') | Should Match '-SourceCommit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -RepairWinGet'
        Assert-MockCalled Invoke-WebRequest -Times 1 -Exactly -Scope It -ParameterFilter {
            $Uri -eq 'https://raw.githubusercontent.com/acurvers/jinda-operations/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/init.ps1'
        }
    }

    It 'does not download or launch a stale local script when the version lookup fails' {
        Mock Invoke-RestMethod { Write-Error 'GitHub unavailable' }
        { & $script:pageCode } | Should Throw 'GitHub unavailable'
        Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly -Scope It
        $script:launches.Count | Should Be 0
    }
}
