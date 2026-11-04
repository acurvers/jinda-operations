$projectPath = Split-Path -Parent $PSScriptRoot
$html = [IO.File]::ReadAllText((Join-Path $projectPath 'index.html'))
$code = [Net.WebUtility]::HtmlDecode([regex]::Match($html, '(?s)<code id="init-code">(.*?)</code>').Groups[1].Value)
$repairCode = [Net.WebUtility]::HtmlDecode([regex]::Match($html, '(?s)<code id="repair-code">(.*?)</code>').Groups[1].Value)
$script:pageCode = [scriptblock]::Create($code)
$script:repairPageCode = [scriptblock]::Create($repairCode)

function powershell.exe {
    $script:launches.Add(@($args))
    $global:LASTEXITCODE = 0
}

Describe 'Published archive initialization one-liner' {
    BeforeEach {
        $script:launches = New-Object 'System.Collections.Generic.List[object]'
        $script:downloadPath = ''
        $script:packagePath = ''
        Mock Invoke-WebRequest { $script:downloadPath = $OutFile }
        Mock Expand-Archive { $script:packagePath = $DestinationPath }
        Mock Invoke-RestMethod { throw 'Setup must not use the GitHub API' }
    }

    It 'downloads one archive and starts init from that same extracted package' {
        & $script:pageCode
        $script:launches.Count | Should Be 1
        ($script:launches[0] -contains (Join-Path $script:packagePath 'jinda-operations-main\init.ps1')) | Should Be $true
        ($script:launches[0] -contains '-NoProfile') | Should Be $true
        ($script:launches[0] -contains 'Bypass') | Should Be $true
        ($script:launches[0] -contains '-WhatIf') | Should Be $false
        Assert-MockCalled Invoke-WebRequest -Times 1 -Exactly -Scope It -ParameterFilter {
            $Uri -eq 'https://github.com/acurvers/jinda-operations/archive/refs/heads/main.zip' -and
            $OutFile -eq "$script:packagePath.zip"
        }
        Assert-MockCalled Expand-Archive -Times 1 -Exactly -Scope It -ParameterFilter {
            $LiteralPath -eq $script:downloadPath -and $DestinationPath -eq $script:packagePath
        }
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
    }

    It 'does not extract or launch an old script when the download fails' {
        Mock Invoke-WebRequest { Write-Error 'Download failed' }
        { & $script:pageCode } | Should Throw 'Download failed'
        Assert-MockCalled Expand-Archive -Times 0 -Exactly -Scope It
        $script:launches.Count | Should Be 0
    }

    It 'does not launch a partial package when extraction fails' {
        Mock Expand-Archive { Write-Error 'Invalid archive' }
        { & $script:pageCode } | Should Throw 'Invalid archive'
        $script:launches.Count | Should Be 0
    }

    It 'uses the same single-line commands in the page and README' {
        foreach ($command in @($code, $repairCode)) {
            $command | Should Not BeNullOrEmpty
            $command | Should Not Match '\r|\n'
            ([IO.File]::ReadAllText((Join-Path $projectPath 'README.md')).Contains($command)) | Should Be $true
        }
    }

    It 'retains the repair switch and uses a fresh directory on each run' {
        & $script:pageCode
        $firstPackage = $script:packagePath
        & $script:repairPageCode
        $script:launches.Count | Should Be 2
        ($script:launches[1] -contains '-RepairWinGet') | Should Be $true
        $script:packagePath | Should Not Be $firstPackage
    }
}
