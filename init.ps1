#Requires -Version 5.1
<#
.SYNOPSIS
Start de volledige Jinda-inrichting: eerst software, daarna Windows-configuratie.
.DESCRIPTION
Vraagt zo nodig eenmaal administratorrechten. Downloadt beide vaste scripts
voordat iets wordt uitgevoerd en kiest opnieuw PowerShell na de software-installatie.
.PARAMETER Keyboard
USInternational (standaard) of US.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('US', 'USInternational')]
    [string]$Keyboard = 'USInternational',
    [Parameter(DontShow = $true)][switch]$RuntimeReady
)

# BEGIN shared runtime (kept identical in all entry scripts).
function Test-JindaAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-JindaWindowsPowerShell {
    $systemDirectory = if ([Environment]::Is64BitProcess) { 'System32' } else { 'Sysnative' }
    return Join-Path $env:WINDIR "$systemDirectory\WindowsPowerShell\v1.0\powershell.exe"
}

function Get-JindaPowerShellCandidates {
    $paths = @()
    $paths += Join-Path $PSHOME 'pwsh.exe'
    foreach ($root in @($env:ProgramW6432, $env:ProgramFiles) | Select-Object -Unique) {
        if ($root) {
            $folder = Join-Path $root 'PowerShell'
            foreach ($directory in (Get-ChildItem -LiteralPath $folder -Directory -ErrorAction SilentlyContinue)) {
                $paths += Join-Path $directory.FullName 'pwsh.exe'
            }
        }
    }
    $paths += @(Get-Command pwsh.exe -CommandType Application -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        $paths += @(Get-AppxPackage -Name Microsoft.PowerShell -ErrorAction SilentlyContinue |
            Where-Object InstallLocation | ForEach-Object { Join-Path $_.InstallLocation 'pwsh.exe' })
    }
    $architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $nativeMachine = if ($architecture -eq 'ARM64') { 0xAA64 } else { 0x8664 }
    foreach ($path in ($paths | Select-Object -Unique)) {
        $reader = $null
        try {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
            $versionText = $info.ProductVersion
            if ($versionText -match '(?i)preview|alpha|beta|rc' -or
                $versionText -notmatch '^(\d+\.\d+\.\d+(?:\.\d+)?)') { continue }
            $version = [version]$matches[1]
            if ($version.Major -lt 7) { continue }
            # Read PE architecture: do not select an x86 runtime.
            $reader = New-Object IO.BinaryReader([IO.File]::OpenRead($path))
            $null = $reader.BaseStream.Seek(0x3C, [IO.SeekOrigin]::Begin)
            $peOffset = $reader.ReadInt32()
            $null = $reader.BaseStream.Seek($peOffset, [IO.SeekOrigin]::Begin)
            if ($reader.ReadUInt32() -ne 0x00004550 -or $reader.ReadUInt16() -ne $nativeMachine) { continue }
            [pscustomobject]@{ Path = $path; Version = $version }
        }
        catch { Write-Verbose "PowerShell-kandidaat overgeslagen: $path ($($_.Exception.Message))" }
        finally { if ($reader) { $reader.Dispose() } }
    }
}

function Get-JindaPowerShell {
    param([switch]$WindowsPowerShell)
    if (-not $WindowsPowerShell) {
        $latest = Get-JindaPowerShellCandidates | Sort-Object Version -Descending | Select-Object -First 1
        if ($latest) { return $latest.Path }
    }
    return Get-JindaWindowsPowerShell
}

function Get-JindaCurrentPowerShell {
    return (Get-Process -Id $PID).Path
}

function Invoke-JindaChildProcess {
    param(
        [string]$Executable,
        [string]$ScriptPath,
        [string[]]$ScriptArguments = @(),
        [switch]$Elevate
    )
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $ScriptArguments
    if ($Elevate) {
        # Start-Process joins its arguments, so explicitly quote paths and values.
        if (@($arguments | Where-Object { $_ -match '["\r\n]' }).Count) {
            throw 'Een scriptpad of argument bevat ongeldige tekens.'
        }
        $argumentLine = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
        try {
            $process = Start-Process -FilePath $Executable -ArgumentList $argumentLine -Verb RunAs -Wait -PassThru -ErrorAction Stop
            return [int]$process.ExitCode
        }
        catch {
            throw "Starten als administrator is niet gelukt. Accepteer de Windows UAC-vraag. $($_.Exception.Message)"
        }
    }
    $PSNativeCommandUseErrorActionPreference = $false
    & $Executable @arguments | Out-Host
    return $LASTEXITCODE
}

function Invoke-JindaManagedScript {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$ScriptPath,
        [string[]]$ScriptArguments = @(),
        [switch]$RuntimeReady,
        [switch]$WindowsPowerShell,
        [scriptblock]$Work
    )
    $ErrorActionPreference = 'Stop'
    # WhatIf causes no elevation, download, log creation or settings changes.
    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Uitvoeren: $(Split-Path -Leaf $ScriptPath) met beheerrechten")) { return 0 }
    $executable = Get-JindaPowerShell -WindowsPowerShell:$WindowsPowerShell
    $administrator = Test-JindaAdministrator
    if (-not $administrator -or (Get-JindaCurrentPowerShell) -ne $executable) {
        if ($RuntimeReady) { throw 'De herstart heeft niet de vereiste beheerrechten of PowerShell-versie opgeleverd.' }
        Write-Host "Starten met beheerrechten via $executable"
        return Invoke-JindaChildProcess -Executable $executable -ScriptPath $ScriptPath -ScriptArguments ($ScriptArguments + @('-RuntimeReady')) -Elevate:(-not $administrator)
    }
    $transcriptStarted = $false
    $logPath = $null
    try {
        $logFolder = Join-Path $env:LOCALAPPDATA 'JindaOperations\Logs'
        $null = New-Item -ItemType Directory -Path $logFolder -Force
        $logName = '{0}-{1}-{2}.log' -f [IO.Path]::GetFileNameWithoutExtension($ScriptPath), (Get-Date -Format 'yyyyMMdd-HHmmss'), $PID
        $logPath = Join-Path $logFolder $logName
        $null = Start-Transcript -LiteralPath $logPath -Force
        $transcriptStarted = $true
        Write-Host "Logbestand: $logPath"
        Write-Host "PowerShell $($PSVersionTable.PSVersion); administratorrechten actief."
        return (& $Work)
    }
    catch {
        Write-Host "FOUT: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        if ($logPath) { Write-Host "Details: $logPath" }
        return 1
    }
    finally {
        if ($transcriptStarted) { $null = Stop-Transcript -ErrorAction SilentlyContinue }
    }
}
# END shared runtime.

function Invoke-JindaInitialization {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [ValidateSet('US', 'USInternational')]
        [string]$Keyboard = 'USInternational'
    )

    $ErrorActionPreference = 'Stop'
    if (-not $PSCmdlet.ShouldProcess('Deze pc', 'Jinda-software installeren en Windows configureren')) { return 0 }

    $baseUrl = 'https://acurvers.github.io/jinda-operations'
    $folder = Join-Path $env:TEMP ('jinda-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $folder
    $install = Join-Path $folder 'install-software.ps1'
    $config = Join-Path $folder 'set-windows-english.ps1'
    Write-Host 'Installatie- en configuratiescript downloaden...'
    Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/install-software.ps1" -OutFile $install -ErrorAction Stop
    Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/set-windows-english.ps1" -OutFile $config -ErrorAction Stop

    Write-Host 'Stap 1/2: software installeren.'
    $installCode = Invoke-JindaChildProcess -Executable (Get-JindaPowerShell) -ScriptPath $install
    if ($installCode -notin @(0, 3010)) { throw "Software-installatie mislukt (exitcode $installCode). Configuratie is niet gestart." }

    # PowerShell may have just been installed or upgraded; select it again.
    Write-Host 'Stap 2/2: Windows configureren.'
    $configCode = Invoke-JindaChildProcess -Executable (Get-JindaPowerShell) -ScriptPath $config -ScriptArguments @('-Keyboard', $Keyboard)
    if ($configCode -ne 0) { throw "Windows-configuratie mislukt (exitcode $configCode)." }

    Write-Host 'Jinda-inrichting voltooid. Herstart Windows om de wijzigingen toe te passen.'
    return $installCode
}

# Dot-sourcing defines functions only, for tests.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $exitCode = Invoke-JindaManagedScript -ScriptPath $PSCommandPath -ScriptArguments @('-Keyboard', $Keyboard) -RuntimeReady:$RuntimeReady -WhatIf:$WhatIfPreference -Work {
            Invoke-JindaInitialization -Keyboard $Keyboard
        }
        exit $exitCode
    }
    catch {
        Write-Host "FOUT: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
