#Requires -Version 5.1
<#
.SYNOPSIS
Installeert de Jinda-apps via WinGet en de officiele Yodeck Windows-installer.
.DESCRIPTION
Installeert waar ondersteund voor alle gebruikers. Bestaande WinGet-apps
worden bijgewerkt als de gekozen bron een nieuwere versie aanbiedt.
Vraagt automatisch beheerrechten en kiest de nieuwste aanwezige stabiele PowerShell 7+.
De pakket- en bronvoorwaarden worden automatisch geaccepteerd.
Bij een Chrome-fout gaat de installatie verder met een waarschuwing.
Fouten bij alle andere apps stoppen de installatie.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param([Parameter(DontShow = $true)][switch]$RuntimeReady)

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

function Get-JindaVSCodeCliPath {
    # A fresh machine installation may not yet be visible in this process's PATH.
    foreach ($root in (@($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}) |
        Where-Object { $_ } | Select-Object -Unique)) {
        $candidate = Join-Path $root 'Microsoft VS Code\bin\code.cmd'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    if ($env:LOCALAPPDATA) {
        $candidate = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $command = Get-Command -Name 'code.cmd' -CommandType Application -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw 'VS Code: code.cmd is na installatie niet gevonden.'
}

function Install-JindaVSCodePowerShellExtension {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    if (-not $PSCmdlet.ShouldProcess('VS Code: ms-vscode.PowerShell', 'Install or update the PowerShell extension')) { return }
    $cli = Get-JindaVSCodeCliPath
    $extensionId = 'ms-vscode.PowerShell'
    Write-Host 'PowerShell-extensie voor VS Code installeren of bijwerken voor het uitvoerende account...'
    & $cli --install-extension $extensionId --force | Out-Host
    $installExitCode = $LASTEXITCODE
    if ($installExitCode -ne 0) {
        throw "VS Code: PowerShell-extensie installeren is mislukt (exitcode $installExitCode)."
    }
    $installed = @(& $cli --list-extensions)
    $verifyExitCode = $LASTEXITCODE
    if ($verifyExitCode -ne 0) {
        throw "VS Code: extensies controleren is mislukt (exitcode $verifyExitCode)."
    }
    if (-not ($installed | Where-Object { ([string]$_).Trim() -ieq $extensionId })) {
        throw 'VS Code: de PowerShell-extensie is na installatie niet teruggevonden.'
    }
    Write-Host 'PowerShell-extensie voor VS Code is beschikbaar.'
}

function Test-JindaYodeckInstalled {
    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($entry in (Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue)) {
        if ($entry.PSObject.Properties['DisplayName'] -and $entry.DisplayName -match '^Yodeck( Electron)? Player(?:\s|$)') {
            return $true
        }
    }
    return $false
}

function Install-JindaYodeck {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $ErrorActionPreference = 'Stop'
    Write-Host ''
    if (-not $PSCmdlet.ShouldProcess('Yodeck Player', 'Downloaden bij Yodeck en installeren')) { return $false }
    if (Test-JindaYodeckInstalled) {
        Write-Host 'Yodeck Player is al aanwezig; overgeslagen.'
        return $false
    }
    $folder = Join-Path $env:TEMP ('jinda-yodeck-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $folder
    $installer = Join-Path $folder 'yodeck-player.exe'
    try {
        Write-Host 'Yodeck Player downloaden via de officiele Windows-download...'
        # Published on https://www.yodeck.com/docs/user-manual/setting-up-the-windows-player-with-the-yodeck-software/
        Invoke-WebRequest -UseBasicParsing -Uri 'https://yodeck.link/windowsv2' -OutFile $installer -ErrorAction Stop
        $signature = Get-AuthenticodeSignature -FilePath $installer
        if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
            $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)CN=Flipnode LLC(?:,|$)') {
            throw 'Yodeck: de installer heeft geen geldige handtekening van Flipnode LLC; installatie gestopt.'
        }
        # The official Electron installer is NSIS; /allusers selects machine installation.
        $process = Start-Process -FilePath $installer -ArgumentList @('/S', '/allusers') -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
        if ($process.ExitCode -notin @(0, 3010)) {
            throw "Yodeck: installatie mislukt (exitcode $($process.ExitCode))."
        }
        if (-not (Test-JindaYodeckInstalled)) {
            throw 'Yodeck: de installer is klaar, maar de installatie is niet teruggevonden in Windows.'
        }
        Write-Host 'Yodeck Player is geinstalleerd. Open de app om deze met de registratiecode aan je Yodeck-account te koppelen.'
        return ($process.ExitCode -eq 3010)
    }
    finally {
        # Remove only our downloaded executable; never recurse through a temp directory.
        if (Test-Path -LiteralPath $installer) { Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue }
    }
}

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

    # Scope is only forced when the manifest supports it; empty means installer default.
    $packages = @(
        @{ Id = 'Google.Chrome'; Name = 'Google Chrome'; Source = 'winget'; Scope = 'machine'; Extra = @() }
        @{ Id = 'TeamViewer.TeamViewer'; Name = 'TeamViewer'; Source = 'winget'; Scope = 'machine'; Extra = @('--installer-type', 'nullsoft') }
        @{ Id = 'Microsoft.PowerShell'; Name = 'PowerShell 7'; Source = 'winget'; Scope = 'machine'; Extra = @('--installer-type', 'wix') }
        @{ Id = 'Microsoft.VisualStudioCode'; Name = 'Visual Studio Code'; Source = 'winget'; Scope = 'machine'; Extra = @() }
        # Current desktop OneNote, not the retired OneNote for Windows 10.
        @{ Id = 'XPFFZHVGQWWLHB'; Name = 'OneNote'; Source = 'msstore'; Scope = ''; Extra = @() }
        @{ Id = 'Notepad++.Notepad++'; Name = 'Notepad++'; Source = 'winget'; Scope = 'machine'; Extra = @() }
        @{ Id = 'Discord.Discord'; Name = 'Discord'; Source = 'winget'; Scope = 'user'; Extra = @() }
        @{ Id = 'Reolink.Reolink'; Name = 'Reolink Client'; Source = 'winget'; Scope = ''; Extra = @() }
        @{ Id = 'dotPDN.PaintDotNet'; Name = 'Paint.NET'; Source = 'winget'; Scope = 'machine'; Extra = @() }
        @{ Id = 'LastPass.LastPass'; Name = 'LastPass'; Source = 'winget'; Scope = ''; Extra = @() }
        @{ Id = 'Git.Git'; Name = 'Git (inclusief Git Bash)'; Source = 'winget'; Scope = 'machine'; Extra = @() }
        @{ Id = 'Zoom.Zoom'; Name = 'Zoom'; Source = 'winget'; Scope = 'machine'; Extra = @() }
        @{ Id = 'Microsoft.Teams'; Name = 'Microsoft Teams'; Source = 'winget'; Scope = 'user'; Extra = @('--installer-type', 'msix') }
        @{ Id = '9NKSQGP7F2NH'; Name = 'WhatsApp'; Source = 'msstore'; Scope = ''; Extra = @() }
        @{ Id = 'VideoLAN.VLC'; Name = 'VLC'; Source = 'winget'; Scope = 'machine'; Extra = @() }
    )
    $restartNeeded = $false
    foreach ($package in $packages) {
        Write-Host ''
        if (-not $PSCmdlet.ShouldProcess($package.Name, 'Installeren via WinGet')) {
            continue
        }
        $wingetArguments = @(
            'install', '--id', $package.Id, '--exact', '--source', $package.Source,
            '--silent',
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
        ) + $package.Extra
        if ($package.Scope) { $wingetArguments += @('--scope', $package.Scope) }
        Write-Host "$($package.Name) installeren of bijwerken via WinGet..."
        try {
            & $winget.Source @wingetArguments | Out-Host
            $wingetExitCode = $LASTEXITCODE
            $exitCodeHex = '{0:X8}' -f ($wingetExitCode -band 0xFFFFFFFFL)
            switch ($exitCodeHex) {
                '00000000' { Write-Host "$($package.Name) is beschikbaar." }
                '8A15002B' { Write-Host "$($package.Name): geen nieuwere versie beschikbaar via WinGet." }
                '8A150061' { Write-Host "$($package.Name) is al geinstalleerd; overgeslagen." }
                '00000BC2' { $restartNeeded = $true }
                default { throw "$($package.Name): WinGet is mislukt (exitcode $wingetExitCode / 0x$exitCodeHex)." }
            }
            if ($package.Id -eq 'Microsoft.VisualStudioCode') {
                Install-JindaVSCodePowerShellExtension
            }
        }
        catch {
            if ($package.Id -ne 'Google.Chrome') { throw }
            Write-Warning "Google Chrome is niet succesvol afgerond: $($_.Exception.Message) De installatie gaat verder met de overige apps."
        }
    }
    if (Install-JindaYodeck -WhatIf:$WhatIfPreference) { $restartNeeded = $true }
    if ($restartNeeded) {
        Write-Warning 'Software is geinstalleerd. Herstart Windows om de installatie af te ronden.'
    }
    return $restartNeeded
}



if ($MyInvocation.InvocationName -ne '.') {
    try {
        $exitCode = Invoke-JindaManagedScript -ScriptPath $PSCommandPath -RuntimeReady:$RuntimeReady -WhatIf:$WhatIfPreference -Work {
            if (Install-JindaSoftware) { return 3010 }
            return 0
        }
        exit $exitCode
    }
    catch {
        Write-Host "FOUT: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
