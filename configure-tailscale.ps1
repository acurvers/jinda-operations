#Requires -Version 5.1
<#
.SYNOPSIS
Configure an already installed Tailscale client and offer browser sign-in.
.DESCRIPTION
Disables accepting Tailscale DNS/subnet routes and clears exit-node use.
Keeps the active account and other preferences. A new device opens its official
browser sign-in page; setup does not wait for the user to finish signing in.
No software installation or Windows Server 2012 configuration is performed.
Requires a supported Windows version and a current installed Tailscale client.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param([switch]$RuntimeReady)

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

# BEGIN Tailscale setup.
function Get-JindaTailscaleCliPath {
    foreach ($root in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}) | Select-Object -Unique) {
        if (-not $root) { continue }
        $path = Join-Path $root 'Tailscale\tailscale.exe'
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }
    $command = Get-Command tailscale.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw 'Tailscale CLI was not found after installation. Reopen PowerShell and retry setup.'
}

function Invoke-JindaTailscaleCli {
    param([string]$Path, [string[]]$Arguments)
    if (@($Arguments | Where-Object { $_ -match '["\r\n]' }).Count) { throw 'Invalid Tailscale CLI argument.' }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Path
    $info.Arguments = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Could not start the Tailscale CLI.' }
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(20000)) {
            $process.Kill()
            throw 'Tailscale CLI did not respond within 20 seconds.'
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output.Result; Error = $errors.Result }
    }
    finally { $process.Dispose() }
}

function Get-JindaTailscaleStatus {
    param([string]$Path)
    $result = Invoke-JindaTailscaleCli $Path @('status', '--json')
    if ($result.ExitCode -notin @(0, 1)) { throw "Tailscale status failed: $($result.Error)" }
    try { $status = $result.Output | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'Tailscale returned an invalid status response.' }
    if (-not $status.BackendState) { throw 'Tailscale did not report its connection state.' }
    return $status
}

function Assert-JindaTailscalePreferences {
    param([string]$Path)
    $result = Invoke-JindaTailscaleCli $Path @('get', '--json')
    if ($result.ExitCode -ne 0) { throw "Could not read Tailscale preferences: $($result.Error)" }
    $prefs = $result.Output | ConvertFrom-Json -ErrorAction Stop
    if ($prefs.'accept-dns' -isnot [bool] -or $prefs.'accept-dns' -ne $false -or
        $prefs.'accept-routes' -isnot [bool] -or $prefs.'accept-routes' -ne $false -or
        $null -eq $prefs.'exit-node' -or [string]$prefs.'exit-node' -ne '') {
        throw 'Tailscale preferences could not be verified: DNS and subnet routes must be off, with no exit node.'
    }
}

function Initialize-JindaTailscale {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    if (-not $PSCmdlet.ShouldProcess('Tailscale on this PC', 'Disable Tailscale DNS, accepted subnet routes and exit-node use; open browser sign-in if needed')) { return }
    $path = Get-JindaTailscaleCliPath
    $service = Get-Service -Name Tailscale -ErrorAction Stop
    if ($service.Status -ne 'Running') {
        Start-Service -Name Tailscale -ErrorAction Stop
        $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(20))
    }
    # Only these three preferences change. Do not reset or replace account profiles.
    $result = Invoke-JindaTailscaleCli $path @('set', '--accept-dns=false', '--accept-routes=false', '--exit-node=')
    if ($result.ExitCode -ne 0) { throw "Could not configure Tailscale: $($result.Error)" }
    Assert-JindaTailscalePreferences $path
    Write-Host 'Tailscale verified: DNS off; accepted subnet routes off; no exit node.'

    $status = Get-JindaTailscaleStatus $path
    if ($status.BackendState -eq 'Running') {
        Write-Host 'Tailscale is already signed in. Keeping the current account and tailnet.'
        return
    }
    # No login/force-reauth/logout: preserve existing identities. A new device
    # receives a browser authentication URL; setup never waits for the user.
    $result = Invoke-JindaTailscaleCli $path @('up', '--json', '--timeout=5s', '--accept-dns=false', '--accept-routes=false', '--exit-node=')
    $status = Get-JindaTailscaleStatus $path
    Assert-JindaTailscalePreferences $path
    if ($result.ExitCode -ne 0 -and ($result.Error -notmatch 'timeout waiting for Tailscale service' -or
        $status.BackendState -notin @('NeedsLogin', 'NeedsMachineAuth'))) {
        throw "Tailscale connection setup failed: $($result.Error)"
    }
    if ($status.BackendState -eq 'Running') { Write-Host 'Tailscale is connected using the existing account.'; return }
    if ($status.BackendState -eq 'NeedsMachineAuth') {
        Write-Warning 'Tailscale sign-in requires device approval in the selected tailnet. Setup will continue.'
        return
    }
    $uri = $null
    if (-not [Uri]::TryCreate([string]$status.AuthURL, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.Host -ne 'login.tailscale.com' -or $uri.Port -ne 443 -or $uri.UserInfo -ne '') {
        throw 'Tailscale did not provide a valid official browser sign-in URL.'
    }
    Write-Host 'Sign in in the browser and select the customer tailnet. Setup continues without waiting for sign-in.'
    if ([Environment]::UserInteractive -and (Get-Process -Id $PID).SessionId -ne 0) {
        try { Start-Process -FilePath $uri.AbsoluteUri -ErrorAction Stop | Out-Null }
        catch { Write-Warning "Could not open the browser. Open this sign-in URL yourself: $($uri.AbsoluteUri)" }
    } else {
        Write-Warning "Open this URL in a browser to finish sign-in: $($uri.AbsoluteUri)"
    }
}
# END Tailscale setup.

# Dot-sourcing defines functions only, for offline tests.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $exitCode = Invoke-JindaManagedScript -ScriptPath $PSCommandPath -RuntimeReady:$RuntimeReady -WhatIf:$WhatIfPreference -Work {
            Initialize-JindaTailscale
            return 0
        }
        exit $exitCode
    }
    catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
}
