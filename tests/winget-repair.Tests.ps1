. (Join-Path (Split-Path -Parent $PSScriptRoot) 'init.ps1')

# Stubs keep all repair tests independent of installed modules and WinGet.
function Repair-WinGetPackageManager {
    [CmdletBinding()]
    param([switch]$Force, [switch]$Latest)
    throw 'Unmocked repair command must never run in tests.'
}
Describe 'Optional WinGet repair' {
    BeforeEach {
        $script:repairEvents = New-Object 'System.Collections.Generic.List[string]'
        Mock Get-PackageProvider { [pscustomobject]@{ Version = '2.8.5.208' } }
        Mock Install-PackageProvider { $script:repairEvents.Add('nuget') }
        Mock Install-Module { $script:repairEvents.Add('module') }
        Mock Import-Module { $script:repairEvents.Add('import') }
        Mock Repair-WinGetPackageManager { $script:repairEvents.Add('repair'); 'Simulated repair output' }
    }

    It 'uses the official stable repair without returning command output' {
        @(Repair-JindaWinGet).Count | Should Be 0
        ($script:repairEvents -join ',') | Should Be 'module,import,repair'
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
    }

    It 'stops if Microsoft repair fails' {
        Mock Repair-WinGetPackageManager { throw 'Repair failed' }
        { Repair-JindaWinGet } | Should Throw 'Repair failed'
    }

    It 'does not install modules or touch WinGet during WhatIf' {
        Repair-JindaWinGet -WhatIf
        Assert-MockCalled Install-Module -Times 0 -Exactly -Scope It
        Assert-MockCalled Install-PackageProvider -Times 0 -Exactly -Scope It
        Assert-MockCalled Repair-WinGetPackageManager -Times 0 -Exactly -Scope It
    }
}
