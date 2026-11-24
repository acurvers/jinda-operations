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
.PARAMETER SubnetRouter
Opt in on the intermediary server: persist IPv4 forwarding on its Tailscale and
directly connected LAN interfaces, and add the route 192.168.40.13/32.
.PARAMETER VerifySubnetRouter
Read-only verification of the subnet-router settings, for example after a reboot.
.PARAMETER LanIPAddress
Select the intermediary server's LAN IPv4 address when multiple candidates exist.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$RuntimeReady,
    [switch]$SubnetRouter,
    [switch]$VerifySubnetRouter,
    [string]$LanIPAddress
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
    Write-Host 'Sign in in the browser and select the intended tailnet. Setup continues without waiting for sign-in.'
    if ([Environment]::UserInteractive -and (Get-Process -Id $PID).SessionId -ne 0) {
        try { Start-Process -FilePath $uri.AbsoluteUri -ErrorAction Stop | Out-Null }
        catch { Write-Warning "Could not open the browser. Open this sign-in URL yourself: $($uri.AbsoluteUri)" }
    } else {
        Write-Warning "Open this URL in a browser to finish sign-in: $($uri.AbsoluteUri)"
    }
}
# END Tailscale setup.

function Test-JindaAddressInSubnet {
    param([string]$Address, [string]$LocalAddress, [int]$PrefixLength)
    $remote = [Net.IPAddress]::Parse($Address).GetAddressBytes()
    $local = [Net.IPAddress]::Parse($LocalAddress).GetAddressBytes()
    if ($remote.Length -ne 4 -or $local.Length -ne 4 -or $PrefixLength -lt 1 -or $PrefixLength -gt 30) { return $false }
    for ($i = 0; $i -lt 4; $i++) {
        $bits = [Math]::Min(8, [Math]::Max(0, $PrefixLength - 8 * $i))
        $mask = if ($bits -eq 0) { 0 } else { (255 -shl (8 - $bits)) -band 255 }
        if (($remote[$i] -band $mask) -ne ($local[$i] -band $mask)) { return $false }
    }
    return $true
}

function Get-JindaSubnetRouterPlan {
    param([string]$Path, [string]$LanIPAddress)
    $ErrorActionPreference = 'Stop'
    $target = '192.168.40.13'
    $status = Get-JindaTailscaleStatus $Path
    if ($status.BackendState -ne 'Running') { throw 'Sign in to Tailscale first using the normal command, then run -SubnetRouter on the intermediary server.' }
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.AddressState -eq 'Preferred' })
    if ($addresses.IPAddress -contains $target) { throw 'Run this option on the intermediary Tailscale server, not on 192.168.40.13 itself.' }
    $tailscale = @($addresses | Where-Object { $_.IPAddress -in @($status.TailscaleIPs) })
    if ($tailscale.Count -ne 1) { throw 'Cannot identify exactly one active Tailscale IPv4 interface.' }
    $lan = @($addresses | Where-Object {
        $_.InterfaceIndex -ne $tailscale[0].InterfaceIndex -and
        (Test-JindaAddressInSubnet -Address $target -LocalAddress $_.IPAddress -PrefixLength $_.PrefixLength)
    })
    if ($LanIPAddress) { $lan = @($lan | Where-Object { $_.IPAddress -eq $LanIPAddress }) }
    if ($lan.Count -ne 1) { throw 'Cannot select a unique directly connected LAN for 192.168.40.13. Supply -LanIPAddress with the intermediary server LAN IP.' }
    $route = @(Find-NetRoute -RemoteIPAddress $target -InterfaceIndex $lan[0].InterfaceIndex -LocalIPAddress $lan[0].IPAddress -ErrorAction Stop |
        Where-Object { $_.PSObject.Properties['NextHop'] })
    if ($route.Count -ne 1 -or $route[0].NextHop -ne '0.0.0.0' -or $route[0].InterfaceIndex -ne $lan[0].InterfaceIndex) {
        throw '192.168.40.13 must be reachable directly through the selected LAN, not through another gateway or VPN.'
    }
    # Preflight both stores before applying any network settings.
    $interfaces = @($tailscale[0], $lan[0])
    foreach ($nic in $interfaces) {
        foreach ($store in @('ActiveStore', 'PersistentStore')) {
            $found = @(Get-NetIPInterface -AddressFamily IPv4 -InterfaceIndex $nic.InterfaceIndex -PolicyStore $store -ErrorAction Stop)
            if ($found.Count -ne 1) { throw "Cannot inspect $store for interface $($nic.InterfaceAlias)." }
        }
    }
    return [pscustomobject]@{ Target = $target; Prefix = "$target/32"; Lan = $lan[0]; Interfaces = $interfaces }
}

function Get-JindaTailscaleAdvertisedRoutes {
    param([string]$Path)
    $result = Invoke-JindaTailscaleCli $Path @('get', '--json')
    if ($result.ExitCode -ne 0) { throw "Could not read existing Tailscale routes: $($result.Error)" }
    $prefs = $result.Output | ConvertFrom-Json -ErrorAction Stop
    if (-not $prefs.PSObject.Properties['advertise-routes'] -or $prefs.'advertise-routes' -isnot [string]) {
        throw 'Cannot determine the existing advertised routes. Refusing to replace them.'
    }
    return @($prefs.'advertise-routes' -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Assert-JindaSubnetRouter {
    param([string]$Path, $Plan)
    foreach ($nic in $Plan.Interfaces) {
        foreach ($store in @('ActiveStore', 'PersistentStore')) {
            $value = @(Get-NetIPInterface -AddressFamily IPv4 -InterfaceIndex $nic.InterfaceIndex -PolicyStore $store -ErrorAction Stop)
            if ($value.Count -ne 1 -or [string]$value[0].Forwarding -ne 'Enabled') {
                throw "IPv4 forwarding is not enabled in $store on $($nic.InterfaceAlias)."
            }
            Write-Host "IPv4 forwarding verified: $($nic.InterfaceAlias), $store."
        }
    }
    if ($Plan.Prefix -notin @(Get-JindaTailscaleAdvertisedRoutes $Path)) { throw "Tailscale is not advertising $($Plan.Prefix)." }
    $result = Invoke-JindaTailscaleCli $Path @('get', '--json')
    if ($result.ExitCode -ne 0) { throw 'Cannot inspect Tailscale unattended mode.' }
    $prefs = $result.Output | ConvertFrom-Json -ErrorAction Stop
    if ($prefs.'unattended' -isnot [bool] -or -not $prefs.'unattended') { throw 'Tailscale unattended mode is not enabled for the subnet router.' }
    Assert-JindaTailscalePreferences $Path
    Write-Host "Tailscale route advertisement verified: $($Plan.Prefix)."
}

function Test-JindaSubnetTargetRdp {
    param([string]$Address, [string]$LocalAddress)
    $client = New-Object Net.Sockets.TcpClient
    try {
        $endpoint = New-Object Net.IPEndPoint([Net.IPAddress]::Parse($LocalAddress), 0)
        $client.Client.Bind($endpoint)
        return ($client.ConnectAsync($Address, 3389).Wait(3000) -and $client.Connected)
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Enable-JindaSubnetRouter {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$LanIPAddress, [switch]$VerifyOnly)
    if (-not $PSCmdlet.ShouldProcess('This intermediary Tailscale server', 'Configure or verify forwarding and the 192.168.40.13/32 route')) { return }
    $ErrorActionPreference = 'Stop'
    $path = Get-JindaTailscaleCliPath
    $plan = Get-JindaSubnetRouterPlan -Path $path -LanIPAddress $LanIPAddress
    $existing = @(Get-JindaTailscaleAdvertisedRoutes $path)
    if (-not $VerifyOnly) {
        Initialize-JindaTailscale
        Write-Host "Subnet router on $($env:COMPUTERNAME): LAN $($plan.Lan.InterfaceAlias) ($($plan.Lan.IPAddress)); add $($plan.Prefix)."
        foreach ($nic in $plan.Interfaces) {
            # Omitting PolicyStore updates both active and persistent interface
            # configuration. Explicit ActiveStore alone would be temporary.
            Set-NetIPInterface -AddressFamily IPv4 -InterfaceIndex $nic.InterfaceIndex -Forwarding Enabled -ErrorAction Stop
        }
        $routes = @(($existing + @($plan.Prefix)) | Select-Object -Unique)
        $result = Invoke-JindaTailscaleCli $path @('set', ('--advertise-routes=' + ($routes -join ',')), '--unattended=true')
        if ($result.ExitCode -ne 0) { throw "Could not advertise the subnet route: $($result.Error)" }
    }
    Assert-JindaSubnetRouter -Path $path -Plan $plan
    if (Test-JindaSubnetTargetRdp -Address $plan.Target -LocalAddress $plan.Lan.IPAddress) {
        Write-Host "LAN TCP 3389 to $($plan.Target) is reachable from this intermediary server."
    } else {
        Write-Warning "LAN TCP 3389 to $($plan.Target) is not reachable. Check RDP and Windows Firewall with Advanced Security on $($plan.Target), allowing source $($plan.Lan.IPAddress)."
    }
    Write-Host 'Next: approve 192.168.40.13/32 for this machine in the Tailscale admin console; review tailnet access rules.'
    Write-Host 'On the management PC: enable Use Tailscale subnets (accept-routes=true), then connect RDP to 192.168.40.13.'
    Write-Host 'No adapter, service or server was restarted. Verify persistence after a planned restart using -VerifySubnetRouter.'
}

# Dot-sourcing defines functions only, for offline tests.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        if ($SubnetRouter -and $VerifySubnetRouter) { throw 'Choose -SubnetRouter or -VerifySubnetRouter, not both.' }
        if ($LanIPAddress -and -not ($SubnetRouter -or $VerifySubnetRouter)) { throw 'LanIPAddress is only used with a subnet-router option.' }
        $forwardArguments = @()
        if ($SubnetRouter) { $forwardArguments += '-SubnetRouter' }
        if ($VerifySubnetRouter) { $forwardArguments += '-VerifySubnetRouter' }
        if ($LanIPAddress) { $forwardArguments += @('-LanIPAddress', $LanIPAddress) }
        $exitCode = Invoke-JindaManagedScript -ScriptPath $PSCommandPath -ScriptArguments $forwardArguments -RuntimeReady:$RuntimeReady -WhatIf:$WhatIfPreference -Work {
            if ($SubnetRouter -or $VerifySubnetRouter) {
                Enable-JindaSubnetRouter -LanIPAddress $LanIPAddress -VerifyOnly:$VerifySubnetRouter
            } else { Initialize-JindaTailscale }
            return 0
        }
        exit $exitCode
    }
    catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
}
