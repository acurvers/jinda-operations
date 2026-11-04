#Requires -Version 5.1
<#
.SYNOPSIS
Install Jinda apps using WinGet and the official Yodeck Windows installer.
.DESCRIPTION
First updates WinGet (Microsoft App Installer) if a newer version is available.
Installs for all users where supported. Existing WinGet apps are updated when
a newer version is available from the selected source.
Requests administrator privileges and selects the latest installed stable PowerShell 7+.
Package and source agreements are accepted automatically.
A Chrome failure produces a warning and installation continues.
Failures for all other apps stop installation.
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
        catch { Write-Verbose "Skipped PowerShell candidate: $path ($($_.Exception.Message))" }
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
            throw 'A script path or argument contains invalid characters.'
        }
        $argumentLine = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
        try {
            $process = Start-Process -FilePath $Executable -ArgumentList $argumentLine -Verb RunAs -Wait -PassThru -ErrorAction Stop
            return [int]$process.ExitCode
        }
        catch {
            throw "Could not start as administrator. Accept the Windows UAC prompt. $($_.Exception.Message)"
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
    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Run $(Split-Path -Leaf $ScriptPath) as administrator")) { return 0 }
    $executable = Get-JindaPowerShell -WindowsPowerShell:$WindowsPowerShell
    $administrator = Test-JindaAdministrator
    if (-not $administrator -or (Get-JindaCurrentPowerShell) -ne $executable) {
        if ($RuntimeReady) { throw 'The relaunched process does not have the required administrator privileges or PowerShell version.' }
        Write-Host "Starting with administrator privileges using $executable"
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
        Write-Host "Log file: $logPath"
        Write-Host "PowerShell $($PSVersionTable.PSVersion); administrator privileges active."
        return (& $Work)
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
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
    throw 'VS Code: code.cmd was not found after installation.'
}

function Install-JindaVSCodePowerShellExtension {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    if (-not $PSCmdlet.ShouldProcess('VS Code: ms-vscode.PowerShell', 'Install or update the PowerShell extension')) { return }
    $cli = Get-JindaVSCodeCliPath
    $extensionId = 'ms-vscode.PowerShell'
    Write-Host 'Installing or updating the VS Code PowerShell extension for the current account...'
    & $cli --install-extension $extensionId --force | Out-Host
    $installExitCode = $LASTEXITCODE
    if ($installExitCode -ne 0) {
        throw "VS Code: PowerShell extension installation failed (exit code $installExitCode)."
    }
    $installed = @(& $cli --list-extensions)
    $verifyExitCode = $LASTEXITCODE
    if ($verifyExitCode -ne 0) {
        throw "VS Code: extension verification failed (exit code $verifyExitCode)."
    }
    if (-not ($installed | Where-Object { ([string]$_).Trim() -ieq $extensionId })) {
        throw 'VS Code: the PowerShell extension was not found after installation.'
    }
    Write-Host 'The VS Code PowerShell extension is available.'
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
    if (-not $PSCmdlet.ShouldProcess('Yodeck Player', 'Download from Yodeck and install')) { return $false }
    if (Test-JindaYodeckInstalled) {
        Write-Host 'Yodeck Player is already installed; skipped.'
        return $false
    }
    $folder = Join-Path $env:TEMP ('jinda-yodeck-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $folder
    $installer = Join-Path $folder 'yodeck-player.exe'
    try {
        Write-Host 'Downloading Yodeck Player using the official Windows download...'
        # Published on https://www.yodeck.com/docs/user-manual/setting-up-the-windows-player-with-the-yodeck-software/
        Invoke-WebRequest -UseBasicParsing -Uri 'https://yodeck.link/windowsv2' -OutFile $installer -ErrorAction Stop
        $signature = Get-AuthenticodeSignature -FilePath $installer
        if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
            $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)CN=Flipnode LLC(?:,|$)') {
            throw 'Yodeck: the installer has no valid signature from Flipnode LLC; installation stopped.'
        }
        # The official Electron installer is NSIS; /allusers selects machine installation.
        $process = Start-Process -FilePath $installer -ArgumentList @('/S', '/allusers') -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
        if ($process.ExitCode -notin @(0, 3010)) {
            throw "Yodeck: installation failed (exit code $($process.ExitCode))."
        }
        if (-not (Test-JindaYodeckInstalled)) {
            throw 'Yodeck: the installer finished, but the installation was not found in Windows.'
        }
        Write-Host 'Yodeck Player is installed. Open the app and use its registration code to link it to your Yodeck account.'
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
        throw 'WinGet is missing. Install or update App Installer using the Microsoft Store, then reopen PowerShell.'
    }

    $restartNeeded = $false
    if ($PSCmdlet.ShouldProcess('WinGet (Microsoft.AppInstaller)', 'Upgrade if a newer version is available')) {
        Write-Host ''
        Write-Host 'Checking for a WinGet update and installing it if available...'
        # Microsoft-supported self-update; no extra PowerShell module is required.
        # https://learn.microsoft.com/en-us/windows/msix/app-installer/install-update-app-installer
        & $winget.Source upgrade --id Microsoft.AppInstaller --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
        $wingetExitCode = $LASTEXITCODE
        $exitCodeHex = '{0:X8}' -f ($wingetExitCode -band 0xFFFFFFFFL)
        switch ($exitCodeHex) {
            '00000000' { Write-Host 'WinGet update completed.' }
            '8A15002B' { Write-Host 'WinGet: no newer version is available.' }
            '00000BC2' { $restartNeeded = $true }
            default { throw "WinGet self-update failed (exit code $wingetExitCode / 0x$exitCodeHex). App installation has not started." }
        }
        # Updating App Installer can replace the executable's versioned path.
        $winget = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue
        if (-not $winget) {
            throw 'WinGet was not found after its update. Reopen PowerShell and run setup again.'
        }
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
        # Temporarily disabled: Discord installation is not working reliably (user report).
        # @{ Id = 'Discord.Discord'; Name = 'Discord'; Source = 'winget'; Scope = 'user'; Extra = @() }
        @{ Id = 'Reolink.Reolink'; Name = 'Reolink Client'; Source = 'winget'; Scope = ''; Extra = @() }
        @{ Id = 'dotPDN.PaintDotNet'; Name = 'Paint.NET'; Source = 'winget'; Scope = 'machine'; Extra = @() }
        @{ Id = 'LastPass.LastPass'; Name = 'LastPass'; Source = 'winget'; Scope = ''; Extra = @() }
        @{ Id = 'Git.Git'; Name = 'Git (including Git Bash)'; Source = 'winget'; Scope = 'machine'; Extra = @() }
        @{ Id = 'Zoom.Zoom'; Name = 'Zoom'; Source = 'winget'; Scope = 'machine'; Extra = @() }
        # Temporarily disabled: Microsoft Teams installation is not working reliably (user report).
        # @{ Id = 'Microsoft.Teams'; Name = 'Microsoft Teams'; Source = 'winget'; Scope = 'user'; Extra = @('--installer-type', 'msix') }
        @{ Id = 'VideoLAN.VLC'; Name = 'VLC'; Source = 'winget'; Scope = 'machine'; Extra = @() }
        @{ Id = 'voidtools.Everything'; Name = 'Everything'; Source = 'winget'; Scope = 'machine'; Extra = @() }
        # Yodeck uses its signed official installer; WhatsApp must be the final app.
        @{ Name = 'Yodeck Player'; Source = 'yodeck' }
        @{ Id = '9NKSQGP7F2NH'; Name = 'WhatsApp'; Source = 'msstore'; Scope = ''; Extra = @() }
    )
    foreach ($package in $packages) {
        if ($package.Source -eq 'yodeck') {
            if (Install-JindaYodeck -WhatIf:$WhatIfPreference) { $restartNeeded = $true }
            continue
        }
        Write-Host ''
        if (-not $PSCmdlet.ShouldProcess($package.Name, 'Install using WinGet')) {
            continue
        }
        $wingetArguments = @(
            'install', '--id', $package.Id, '--exact', '--source', $package.Source,
            '--silent',
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
        ) + $package.Extra
        if ($package.Scope) { $wingetArguments += @('--scope', $package.Scope) }
        Write-Host "$($package.Name) installing or updating using WinGet..."
        try {
            & $winget.Source @wingetArguments | Out-Host
            $wingetExitCode = $LASTEXITCODE
            $exitCodeHex = '{0:X8}' -f ($wingetExitCode -band 0xFFFFFFFFL)
            switch ($exitCodeHex) {
                '00000000' { Write-Host "$($package.Name) is available." }
                '8A15002B' { Write-Host "$($package.Name): no newer version is available from WinGet." }
                '8A150061' { Write-Host "$($package.Name) is already installed; skipped." }
                '00000BC2' { $restartNeeded = $true }
                default { throw "$($package.Name): WinGet failed (exit code $wingetExitCode / 0x$exitCodeHex)." }
            }
            if ($package.Id -eq 'Microsoft.VisualStudioCode') {
                Install-JindaVSCodePowerShellExtension
            }
        }
        catch {
            if ($package.Id -ne 'Google.Chrome') { throw }
            Write-Warning "Google Chrome did not complete successfully: $($_.Exception.Message) Installation will continue with the remaining apps."
        }
    }
    if ($restartNeeded) {
        Write-Warning 'Software is installed. Restart Windows to complete the installation.'
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
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
