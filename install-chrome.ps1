#Requires -Version 5.1
<#
.SYNOPSIS
Installeert Google Chrome via WinGet op Windows 11.
.DESCRIPTION
Installeert Google.Chrome voor alle gebruikers via de winget-bron.
Een bestaande installatie wordt overgeslagen. Windows kan om beheerrechten
vragen. De pakket- en bronvoorwaarden worden automatisch geaccepteerd.
.EXAMPLE
.\install-chrome.ps1
.EXAMPLE
.\install-chrome.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# PowerShell 7: verwerk de exitcode zelf, ook bij een bestaande installatie.
$PSNativeCommandUseErrorActionPreference = $false

try {
    $winget = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'WinGet ontbreekt. Installeer of werk App Installer bij via de Microsoft Store en open PowerShell opnieuw.'
    }

    $wingetArguments = @(
        'install'
        '--id', 'Google.Chrome'
        '--exact'
        '--source', 'winget'
        '--scope', 'machine'
        '--silent'
        '--no-upgrade'
        '--accept-package-agreements'
        '--accept-source-agreements'
        '--disable-interactivity'
    )

    if (-not $PSCmdlet.ShouldProcess('Google Chrome (alle gebruikers)', 'Installeren via WinGet')) {
        return
    }

    Write-Host 'Google Chrome installeren via WinGet...'
    & $winget.Source @wingetArguments
    $wingetExitCode = $LASTEXITCODE
    # HRESULT kan door PowerShell als een negatief getal worden teruggegeven.
    $exitCodeHex = '{0:X8}' -f ($wingetExitCode -band 0xFFFFFFFFL)

    switch ($exitCodeHex) {
        '00000000' {
            Write-Host 'Klaar: Google Chrome is beschikbaar.'
        }
        '8A15002B' {
            Write-Host 'Google Chrome is al aanwezig; geen installatie of update nodig.'
        }
        '8A150061' {
            Write-Host 'Google Chrome is al geinstalleerd; overgeslagen.'
        }
        '00000BC2' {
            Write-Warning 'Google Chrome is geinstalleerd. Start Windows opnieuw op om de installatie af te ronden.'
            exit 3010
        }
        default {
            throw "WinGet is mislukt (exitcode $wingetExitCode / 0x$exitCodeHex). Bekijk de WinGet-uitvoer hierboven."
        }
    }
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
