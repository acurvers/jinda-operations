#Requires -Version 5.1
<#
.SYNOPSIS
Installeert Chrome, TeamViewer en PowerShell 7 en stelt Windows in op Engels (VS).
.DESCRIPTION
Downloadt de scripts van Jinda Operations en voert ze direct uit.
Start vanuit Windows PowerShell als administrator. Herstart Windows na afloop.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('US', 'USInternational')]
    [string]$Keyboard = 'USInternational'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

try {
    if (-not $PSCmdlet.ShouldProcess('Deze pc', "Chrome, TeamViewer en PowerShell 7 installeren; Windows naar Engels (VS) met $Keyboard")) {
        return
    }
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) {
        throw 'Start dit script met de 64-bits Windows PowerShell 5.1 (powershell.exe).'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or $identity.IsSystem) {
        throw 'Start Windows PowerShell als administrator onder een aangemeld gebruikersaccount.'
    }
    $windows = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    if ($windows.InstallationType -ne 'Client' -or [int]$windows.CurrentBuildNumber -lt 22000 -or $windows.EditionID -match 'SingleLanguage|CountrySpecific') {
        throw 'Dit script vereist Windows 11 met ondersteuning voor meerdere weergavetalen, bijvoorbeeld Pro.'
    }

    $downloadFolder = Join-Path $env:TEMP ('jinda-setup-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $downloadFolder
    $baseUrl = 'https://acurvers.github.io/jinda-operations'
    $scripts = @('install-software.ps1', 'set-windows-english.ps1')
    foreach ($name in $scripts) {
        Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$name" -OutFile (Join-Path $downloadFolder $name) -ErrorAction Stop
    }

    $powerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $powerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $downloadFolder 'install-software.ps1')
    if ($LASTEXITCODE -notin @(0, 3010)) { throw "Software-installatie mislukt (exitcode $LASTEXITCODE)." }

    & $powerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $downloadFolder 'set-windows-english.ps1') -Keyboard $Keyboard
    if ($LASTEXITCODE -ne 0) { throw "Taalinstellingen niet volledig toegepast (exitcode $LASTEXITCODE)." }

    Write-Host 'Klaar. Herstart Windows om de taalinstellingen toe te passen.'
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
