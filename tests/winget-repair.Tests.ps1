. (Join-Path (Split-Path -Parent $PSScriptRoot) 'init.ps1')

# Stubs keep all repair tests independent of installed modules and WinGet.
function Repair-WinGetPackageManager {
    [CmdletBinding()]
    param([switch]$Force, [switch]$Latest)
    throw 'Unmocked repair command must never run in tests.'
}
function winget.exe {
    $script:sourceArguments = @($args)
    $global:LASTEXITCODE = $script:sourceExitCode
    'Simulated Chrome package details'
}

Describe 'Optional WinGet repair' {
    BeforeEach {
        $script:repairEvents = New-Object 'System.Collections.Generic.List[string]'
        $script:sourceExitCode = 0
        $script:sourceArguments = @()
        Mock Get-PackageProvider { [pscustomobject]@{ Version = '2.8.5.208' } }
        Mock Install-PackageProvider { $script:repairEvents.Add('nuget') }
        Mock Install-Module { $script:repairEvents.Add('module') }
        Mock Import-Module { $script:repairEvents.Add('import') }
        Mock Repair-WinGetPackageManager { $script:repairEvents.Add('repair'); 'Simulated repair output' }
        Mock Get-Command { [pscustomobject]@{ Source = 'winget.exe' } } -ParameterFilter { $Name -eq 'winget.exe' }
    }

    It 'uses the official stable repair and verifies the winget source without returning command output' {
        @(Repair-JindaWinGet).Count | Should Be 0
        ($script:repairEvents -join ',') | Should Be 'module,import,repair'
        ($script:sourceArguments -join ' ') | Should Be 'show --id Google.Chrome --exact --source winget --accept-source-agreements --disable-interactivity'
        Assert-MockCalled Install-Module -Times 1 -Exactly -Scope It -ParameterFilter {
            $Name -eq 'Microsoft.WinGet.Client' -and $Repository -eq 'PSGallery' -and $Scope -eq 'CurrentUser' -and $Force
        }
        Assert-MockCalled Repair-WinGetPackageManager -Times 1 -Exactly -Scope It -ParameterFilter { $Force -and $Latest }
    }

    It 'bootstraps missing NuGet only on Windows PowerShell 5.1' {
        Mock Get-PackageProvider {}
        Repair-JindaWinGet
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            $script:repairEvents[0] | Should Be 'nuget'
            Assert-MockCalled Install-PackageProvider -Times 1 -Exactly -Scope It -ParameterFilter {
                $Name -eq 'NuGet' -and $Scope -eq 'CurrentUser' -and $Force
            }
        } else {
            Assert-MockCalled Install-PackageProvider -Times 0 -Exactly -Scope It
        }
    }

    It 'stops if the module download fails' {
        Mock Install-Module { throw 'Module download failed' }
        { Repair-JindaWinGet } | Should Throw 'Module download failed'
        Assert-MockCalled Repair-WinGetPackageManager -Times 0 -Exactly -Scope It
        $script:sourceArguments.Count | Should Be 0
    }

    It 'stops if Microsoft repair fails' {
        Mock Repair-WinGetPackageManager { throw 'Repair failed' }
        { Repair-JindaWinGet } | Should Throw 'Repair failed'
        $script:sourceArguments.Count | Should Be 0
    }

    It 'rejects a still broken source even when repair reported success' {
        $script:sourceExitCode = -1978335217
        { Repair-JindaWinGet } | Should Throw 'WinGet-bron blijft onbruikbaar na herstel'
    }

    It 'does not install modules or touch WinGet during WhatIf' {
        Repair-JindaWinGet -WhatIf
        Assert-MockCalled Install-Module -Times 0 -Exactly -Scope It
        Assert-MockCalled Install-PackageProvider -Times 0 -Exactly -Scope It
        Assert-MockCalled Repair-WinGetPackageManager -Times 0 -Exactly -Scope It
        $script:sourceArguments.Count | Should Be 0
    }
}
