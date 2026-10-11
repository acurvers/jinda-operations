#Requires -Version 5.1
<#
.SYNOPSIS
Installeert Google Chrome, TeamViewer en de nieuwste stabiele PowerShell 7 via WinGet.
.DESCRIPTION
Installeert voor alle gebruikers. Bestaande Chrome/TeamViewer-installaties
worden overgeslagen; een oudere PowerShell 7 wordt bijgewerkt.
De pakket- en bronvoorwaarden worden automatisch geaccepteerd.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param()

function Install-JindaSoftware {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    $winget = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'WinGet ontbreekt. Installeer of werk App Installer bij via de Microsoft Store en open PowerShell opnieuw.'
    }

    $packages = @(
        @{ Id = 'Google.Chrome'; Name = 'Google Chrome'; Extra = @('--no-upgrade') }
        # Selecteer de volledige EXE-installer, niet het MSI-updatepakket.
        @{ Id = 'TeamViewer.TeamViewer'; Name = 'TeamViewer'; Extra = @('--no-upgrade', '--installer-type', 'nullsoft') }
        # Stabiele MSI voor alle gebruikers; laat WinGet oudere versies bijwerken.
        @{ Id = 'Microsoft.PowerShell'; Name = 'PowerShell 7'; Extra = @('--installer-type', 'wix') }
    )
    $restartNeeded = $false
    foreach ($package in $packages) {
        if (-not $PSCmdlet.ShouldProcess($package.Name, 'Installeren via WinGet voor alle gebruikers')) {
            continue
        }
        $wingetArguments = @(
            'install', '--id', $package.Id, '--exact', '--source', 'winget',
            '--scope', 'machine', '--silent',
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
        ) + $package.Extra
        Write-Host "$($package.Name) installeren via WinGet..."
        & $winget.Source @wingetArguments | Out-Host
        $wingetExitCode = $LASTEXITCODE
        $exitCodeHex = '{0:X8}' -f ($wingetExitCode -band 0xFFFFFFFFL)
        switch ($exitCodeHex) {
            '00000000' { Write-Host "$($package.Name) is beschikbaar." }
            '8A15002B' { Write-Host "$($package.Name) is al aanwezig; overgeslagen." }
            '8A150061' { Write-Host "$($package.Name) is al geinstalleerd; overgeslagen." }
            '00000BC2' { $restartNeeded = $true }
            default { throw "$($package.Name): WinGet is mislukt (exitcode $wingetExitCode / 0x$exitCodeHex)." }
        }
    }
    if ($restartNeeded) {
        Write-Warning 'Software is geinstalleerd. Herstart Windows om de installatie af te ronden.'
    }
    return $restartNeeded
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $restartNeeded = Install-JindaSoftware @PSBoundParameters
        if ($restartNeeded) { exit 3010 }
    }
    catch {
        Write-Error -Message $_.Exception.Message -ErrorAction Continue
        exit 1
    }
}
