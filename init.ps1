#Requires -Version 5.1
<#
.SYNOPSIS
Start de Jinda-inrichting: keuzes vooraf, optioneel software, daarna Windows-configuratie.
.DESCRIPTION
Vraagt zo nodig eenmaal administratorrechten en verzamelt alle keuzes vooraf.
Gebruikt de twee vaste scripts uit hetzelfde GitHub-ZIP-pakket en kiest opnieuw
PowerShell na de optionele software-installatie.
.PARAMETER Keyboard
USInternational (standaard) of US.
.PARAMETER RepairWinGet
Herstelt WinGet met Microsoft.WinGet.Client en controleert de winget-bron
voordat de software-installatie begint. Alleen actief als deze switch is opgegeven.
.PARAMETER InstallApps
Ask (standaard), Yes of No. Vraagt aan het begin of apps moeten worden geinstalleerd.
.PARAMETER RemoteDesktop
Ask (standaard), Yes of No. Remote Desktop inschakelen voor het gekozen LAN.
.PARAMETER PowerShellRemoting
Ask (standaard), Yes of No. Windows PowerShell-remoting (WinRM) inschakelen op het LAN.
.PARAMETER LanIPAddress
Optioneel actief IPv4-adres van de doel-pc. Zonder dit adres wordt het LAN aan het begin gekozen.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('US', 'USInternational')]
    [string]$Keyboard = 'USInternational',
    [switch]$RepairWinGet,
    [ValidateSet('Ask', 'Yes', 'No')][string]$InstallApps = 'Ask',
    [ValidateSet('Ask', 'Yes', 'No')][string]$RemoteDesktop = 'Ask',
    [ValidateSet('Ask', 'Yes', 'No')][string]$PowerShellRemoting = 'Ask',
    [string]$LanIPAddress,
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
        [switch]$Elevate,
        [switch]$NonInteractive
    )
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
    if ($NonInteractive) { $arguments += '-NonInteractive' }
    $arguments += @('-File', $ScriptPath) + $ScriptArguments
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

function Repair-JindaWinGet {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $ErrorActionPreference = 'Stop'
    if (-not $PSCmdlet.ShouldProcess('Deze pc', 'WinGet herstellen en bijwerken naar de nieuwste stabiele versie')) { return }

    Write-Host 'WinGet herstellen met de officiele Microsoft-module...'
    # Windows PowerShell 5.1 may still need the NuGet provider to use PSGallery.
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
            Where-Object { [version]$_.Version -ge [version]'2.8.5.201' }
        if (-not $nuget) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -ErrorAction Stop | Out-Host
        }
    }
    Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Scope CurrentUser -Force -ErrorAction Stop | Out-Host
    Import-Module -Name Microsoft.WinGet.Client -Force -ErrorAction Stop
    Repair-WinGetPackageManager -Force -Latest -Verbose -ErrorAction Stop | Out-Host

    # Probe a required app: Chrome installation errors are allowed to continue.
    Write-Host 'WinGet-bron controleren met TeamViewer...'
    $winget = (Get-Command winget.exe -CommandType Application -ErrorAction Stop).Source
    $PSNativeCommandUseErrorActionPreference = $false
    & $winget show --id TeamViewer.TeamViewer --exact --source winget --accept-source-agreements --disable-interactivity | Out-Host
    $sourceCode = $LASTEXITCODE
    if ($sourceCode -ne 0) {
        throw "WinGet-bron blijft onbruikbaar na herstel (exitcode $sourceCode). Installatie en configuratie zijn niet gestart."
    }
    Write-Host 'WinGet-herstel en broncontrole geslaagd.'
}

function Read-JindaYesNo {
    param(
        [string]$Prompt,
        [ValidateSet('Ask', 'Yes', 'No')][string]$Choice = 'Ask',
        [bool]$Default = $false
    )
    if ($Choice -ne 'Ask') { return ($Choice -eq 'Yes') }
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = ([string](Read-Host "$Prompt $hint")).Trim().ToLowerInvariant()
        if ($answer -eq '') { return $Default }
        if ($answer -in @('y', 'yes', 'j', 'ja')) { return $true }
        if ($answer -in @('n', 'no', 'nee')) { return $false }
        Write-Host 'Antwoord met y of n.'
    }
}

function Select-JindaLanAddress {
    param([string]$Address)
    $candidates = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object {
            $_.AddressState -eq 'Preferred' -and $_.PrefixLength -ge 1 -and $_.PrefixLength -le 30 -and
            $_.IPAddress -notmatch '^(127\.|169\.254\.|0\.)'
        } | Sort-Object InterfaceIndex, IPAddress)
    if ($Address) {
        $parsed = [Net.IPAddress]::Parse($Address)
        if ($parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'Kies een IPv4-LAN-adres.' }
        $selected = @($candidates | Where-Object IPAddress -eq $parsed.IPAddressToString)
        if ($selected.Count -ne 1) { throw "LAN-adres $Address is niet eenduidig actief op deze pc." }
    }
    elseif ($candidates.Count -eq 0) { throw 'Geen actief IPv4-LAN gevonden. Er wordt nog niets geinstalleerd of ingesteld.' }
    elseif ($candidates.Count -eq 1) { $selected = @($candidates[0]) }
    else {
        Write-Host 'Kies het LAN waarop Remote Desktop/WinRM bereikbaar mag zijn:'
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            Write-Host ('{0}: {1} - {2}/{3}' -f ($i + 1), $candidates[$i].InterfaceAlias, $candidates[$i].IPAddress, $candidates[$i].PrefixLength)
        }
        while ($true) {
            $number = 0
            $answer = Read-Host 'LAN-nummer'
            if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $candidates.Count) {
                $selected = @($candidates[$number - 1])
                break
            }
            Write-Host 'Kies een nummer uit de lijst.'
        }
    }
    Write-Host ('LAN voor toegang op afstand: {0} - {1}/{2}.' -f $selected[0].InterfaceAlias, $selected[0].IPAddress, $selected[0].PrefixLength)
    return [string]$selected[0].IPAddress
}

function Get-JindaSetupOptions {
    param(
        [string]$InstallApps = 'Ask', [string]$RemoteDesktop = 'Ask',
        [string]$PowerShellRemoting = 'Ask', [string]$LanIPAddress
    )
    Write-Host 'Kies nu de onderdelen. Daarna loopt de inrichting zonder verdere vragen door.'
    $apps = Read-JindaYesNo -Prompt 'Apps downloaden en installeren?' -Choice $InstallApps -Default $true
    $rdp = Read-JindaYesNo -Prompt 'Remote Desktop (RDP) inschakelen op het LAN?' -Choice $RemoteDesktop
    $winrm = Read-JindaYesNo -Prompt 'PowerShell-remoting (WinRM) inschakelen op het LAN?' -Choice $PowerShellRemoting
    $address = ''
    if ($rdp -or $winrm) { $address = Select-JindaLanAddress -Address $LanIPAddress }
    [pscustomobject]@{ InstallApps = $apps; RemoteDesktop = $rdp; PowerShellRemoting = $winrm; LanIPAddress = $address }
}

function Invoke-JindaInitialization {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [ValidateSet('US', 'USInternational')]
        [string]$Keyboard = 'USInternational',
        [switch]$RepairWinGet,
        [ValidateSet('Ask', 'Yes', 'No')][string]$InstallApps = 'Ask',
        [ValidateSet('Ask', 'Yes', 'No')][string]$RemoteDesktop = 'Ask',
        [ValidateSet('Ask', 'Yes', 'No')][string]$PowerShellRemoting = 'Ask',
        [string]$LanIPAddress
    )

    $ErrorActionPreference = 'Stop'
    if (-not $PSCmdlet.ShouldProcess('Deze pc', 'Jinda-software installeren en Windows configureren')) { return 0 }

    # The start command downloads one complete source archive. Children never prompt.
    $options = Get-JindaSetupOptions -InstallApps $InstallApps -RemoteDesktop $RemoteDesktop -PowerShellRemoting $PowerShellRemoting -LanIPAddress $LanIPAddress
    $folder = $PSScriptRoot
    $install = Join-Path $folder 'install-software.ps1'
    $config = Join-Path $folder 'set-windows-english.ps1'
    $requiredScripts = @($config)
    if ($options.InstallApps) { $requiredScripts = @($install, $config) }
    foreach ($path in $requiredScripts) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Scriptpakket onvolledig: $path ontbreekt. Gebruik de nieuwe startopdracht uit de GitHub README."
        }
    }
    Write-Host "Scripts gebruiken uit GitHub-pakket: $folder"

    $installCode = 0
    if ($options.InstallApps) {
        if ($RepairWinGet) { Repair-JindaWinGet }
        Write-Host 'Stap 1/2: software installeren.'
        $installCode = Invoke-JindaChildProcess -Executable (Get-JindaPowerShell) -ScriptPath $install -NonInteractive
        if ($installCode -notin @(0, 3010)) { throw "Software-installatie mislukt (exitcode $installCode). Configuratie is niet gestart." }
    }
    else { Write-Host 'Software-installatie en eventueel WinGet-herstel overgeslagen volgens je keuze.' }

    # PowerShell may have just been installed or upgraded; select it again.
    Write-Host 'Stap 2/2: Windows configureren.'
    $configArguments = @('-Keyboard', $Keyboard)
    if ($options.RemoteDesktop) { $configArguments += '-EnableRemoteDesktop' }
    if ($options.PowerShellRemoting) { $configArguments += '-EnableWinRM' }
    if ($options.LanIPAddress) { $configArguments += @('-LanIPAddress', $options.LanIPAddress) }
    $configCode = Invoke-JindaChildProcess -Executable (Get-JindaPowerShell) -ScriptPath $config -ScriptArguments $configArguments -NonInteractive
    if ($configCode -ne 0) { throw "Windows-configuratie mislukt (exitcode $configCode)." }

    Write-Host 'Jinda-inrichting voltooid. Herstart Windows om de wijzigingen toe te passen.'
    return $installCode
}

# Dot-sourcing defines functions only, for tests.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $scriptArguments = @('-Keyboard', $Keyboard, '-InstallApps', $InstallApps, '-RemoteDesktop', $RemoteDesktop, '-PowerShellRemoting', $PowerShellRemoting)
        if ($RepairWinGet) { $scriptArguments += '-RepairWinGet' }
        if ($LanIPAddress) { $scriptArguments += @('-LanIPAddress', $LanIPAddress) }
        $exitCode = Invoke-JindaManagedScript -ScriptPath $PSCommandPath -ScriptArguments $scriptArguments -RuntimeReady:$RuntimeReady -WhatIf:$WhatIfPreference -Work {
            Invoke-JindaInitialization -Keyboard $Keyboard -RepairWinGet:$RepairWinGet -InstallApps $InstallApps -RemoteDesktop $RemoteDesktop -PowerShellRemoting $PowerShellRemoting -LanIPAddress $LanIPAddress
        }
        exit $exitCode
    }
    catch {
        Write-Host "FOUT: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
