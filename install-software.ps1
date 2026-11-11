#Requires -Version 5.1
<#
.SYNOPSIS
Install Jinda apps, Windows OpenSSH and the official Yodeck Windows installer.
.DESCRIPTION
Updates WinGet (Microsoft App Installer) before installing any selected WinGet apps.
Installs for all users where supported. Existing WinGet apps are updated when
a newer version is available from the selected source.
Requests administrator privileges and selects the latest installed stable PowerShell 7+.
Package and source agreements are accepted automatically.
A Chrome failure produces a warning and installation continues.
Failures for all other apps stop installation.
.PARAMETER EnableOpenSSH
Opt in to installing OpenSSH client/server and enabling the SSH service and LAN firewall rule.
Without this switch, existing OpenSSH installation and settings are left unchanged.
.PARAMETER LanIPAddress
Select the active IPv4 address for the OpenSSH firewall rule. If omitted, exactly
one active IPv4 LAN address must be available.
.PARAMETER SshPublicKey
Optional Ed25519 public key for the enabled local Windows accounts when OpenSSH is selected.
.PARAMETER SkipApps
Skip the regular apps and WinGet updates. Combine with EnableOpenSSH for SSH-only installation.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$EnableOpenSSH,
    [switch]$SkipApps,
    [string]$LanIPAddress,
    [string]$SshPublicKey,
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

function Get-JindaOpenSSHLan {
    param([string]$Address)

    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
        $_.AddressState -eq 'Preferred' -and $_.PrefixLength -ge 1 -and $_.PrefixLength -le 30 -and
        $_.IPAddress -notmatch '^(127\.|169\.254\.|0\.)' -and
        (-not $Address -or $_.IPAddress -eq $Address)
    })
    if ($addresses.Count -ne 1) {
        throw 'OpenSSH requires one active IPv4 LAN address. Select the LAN in init.ps1 or pass -LanIPAddress.'
    }
    $lan = $addresses[0]
    $network = ([Net.IPAddress]$lan.IPAddress).GetAddressBytes()
    $mask = New-Object byte[] 4
    for ($index = 0; $index -lt 4; $index++) {
        $bits = [Math]::Min(8, [Math]::Max(0, $lan.PrefixLength - 8 * $index))
        $mask[$index] = (255 -shl (8 - $bits)) -band 255
        $network[$index] = $network[$index] -band $mask[$index]
    }
    $networkAddress = $network -join '.'
    [pscustomobject]@{
        Address = $lan.IPAddress
        InterfaceAlias = $lan.InterfaceAlias
        InterfacePattern = [System.Management.Automation.WildcardPattern]::Escape($lan.InterfaceAlias)
        Subnet = "$networkAddress/$($lan.PrefixLength)"
        SubnetWithMask = "$networkAddress/$($mask -join '.')"
    }
}

function Test-JindaOpenSSHSetup {
    param([string]$RuleName, $Lan)

    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name = 'sshd'" -ErrorAction Stop
    $sshListeners = @()
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $listeners = @(Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction Stop)
        } catch {
            if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { throw }
            $listeners = @()
        }
        $sshListeners = @($listeners | Where-Object {
            $service.ProcessId -gt 0 -and $_.OwningProcess -eq $service.ProcessId -and
            $_.LocalAddress -in @('0.0.0.0', $Lan.Address)
        })
        if ($sshListeners.Count -gt 0) { break }
        if ($attempt -lt 3) { Start-Sleep -Seconds 1 }
    }
    if ($listeners.Count -gt 0) {
        $listeners | Select-Object LocalAddress, LocalPort, State, OwningProcess | Format-Table -AutoSize | Out-Host
    }
    if ($sshListeners.Count -gt 0) {
        Write-Host "SUCCESS: sshd is listening on IPv4 TCP port 22 for $($Lan.Address)."
    } else {
        Write-Warning "sshd is running, but no IPv4 listener owned by sshd was found on TCP 22 for $($Lan.Address). Check Port and ListenAddress in sshd_config."
    }

    $rule = Get-NetFirewallRule -PolicyStore ActiveStore -Name $RuleName -ErrorAction Stop
    $rule | Select-Object Enabled, Profile, Direction, Action, EnforcementStatus | Format-Table -AutoSize | Out-Host
    $addressFilter = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
    $portFilter = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
    $interfaceFilter = Get-NetFirewallInterfaceFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
    if ([string]$rule.Enabled -ne 'True' -or [string]$rule.Profile -ne 'Any' -or
        $rule.Direction -ne 'Inbound' -or $rule.Action -ne 'Allow' -or $rule.EdgeTraversalPolicy -ne 'Block' -or
        [string]$portFilter.Protocol -notin @('TCP', '6') -or [string]$portFilter.LocalPort -ne '22' -or
        [string]$addressFilter.LocalAddress -notin @($Lan.Address, "$($Lan.Address)/32", "$($Lan.Address)/255.255.255.255") -or
        [string]$addressFilter.RemoteAddress -notin @($Lan.Subnet, $Lan.SubnetWithMask) -or
        [string]$interfaceFilter.InterfaceAlias -notin @($Lan.InterfaceAlias, $Lan.InterfacePattern)) {
        throw "Active OpenSSH firewall rule $RuleName does not match the selected LAN and TCP port 22."
    }
    if ($rule.PrimaryStatus -ne 'OK' -or @($rule.EnforcementStatus) -notcontains 'Enforced') {
        throw "OpenSSH firewall rule $RuleName is configured but not enforced: $($rule.EnforcementStatus -join ', ')."
    }
    Write-Host "SUCCESS: the SSH firewall rule is enforced on $($Lan.InterfaceAlias) for $($Lan.Address) from $($Lan.Subnet)."
}

function ConvertTo-JindaEd25519PublicKey {
    param([string]$PublicKey)

    if ($PublicKey.Trim() -cnotmatch '\Assh-ed25519[ \t]+([A-Za-z0-9+/]{68})(?:[ \t]+[^\r\n]*)?\z') {
        throw 'Provide one OpenSSH Ed25519 public key, beginning with ssh-ed25519.'
    }
    $blob = $Matches[1]
    $bytes = [Convert]::FromBase64String($blob)
    # The wire format is the ssh-ed25519 algorithm name followed by a 32-byte key.
    if ([BitConverter]::ToString($bytes, 0, 19) -ne '00-00-00-0B-73-73-68-2D-65-64-32-35-35-31-39-00-00-00-20') {
        throw 'The supplied Ed25519 public key has an invalid OpenSSH key blob.'
    }
    return "ssh-ed25519 $blob"
}

function Get-JindaSshProfilePath {
    param($User)

    $sid = $User.SID.Value
    $filter = "SID = '$sid' AND Special = FALSE"
    $profile = Get-CimInstance -ClassName Win32_UserProfile -Filter $filter -ErrorAction Stop
    if ($profile) { return $profile.LocalPath }

    # Create a Windows profile so a local account can use its key on first sign-in.
    if (-not ('JindaOperations.UserProfiles' -as [type])) {
        Add-Type -Namespace JindaOperations -Name UserProfiles -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("userenv.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, ExactSpelling = true)]
public static extern int CreateProfile(string sid, string name, System.Text.StringBuilder path, uint pathCapacity);
'@ -ErrorAction Stop
    }
    $path = [System.Text.StringBuilder]::new(32768)
    $result = [JindaOperations.UserProfiles]::CreateProfile($sid, $User.Name, $path, $path.Capacity)
    if ($result -eq 0) { return $path.ToString() }
    if ($result -eq -2147024713) {
        $profile = Get-CimInstance -ClassName Win32_UserProfile -Filter $filter -ErrorAction Stop
        if ($profile) { return $profile.LocalPath }
    }
    throw ('Could not initialize the Windows profile for {0} (HRESULT 0x{1:X8}).' -f $User.Name, $result)
}

function Set-JindaSshAuthorizedKey {
    param([string]$Path, [string]$PublicKey, [System.Security.Principal.SecurityIdentifier]$UserSid)

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -Path $directory -ItemType Directory -ErrorAction Stop
    }
    $folder = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
    if ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "OpenSSH key directory must not be a link: $directory"
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        $null = New-Item -Path $Path -ItemType File -ErrorAction Stop
    }
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($file.PSIsContainer -or $file.LinkType -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "OpenSSH key file must be a regular file: $Path"
    }

    $adminSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $systemSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $security = [System.Security.AccessControl.FileSecurity]::new()
    $security.SetOwner($adminSid)
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($adminSid, $systemSid, $UserSid) | Where-Object { $_ }) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow')
        $security.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $security -ErrorAction Stop

    # Keep existing lines and key options. Lock out concurrent writes during the read and append.
    $utf8 = [Text.UTF8Encoding]::new($false)
    $stream = [IO.File]::Open($Path, 'Open', 'ReadWrite', 'Read')
    try {
        $reader = [IO.StreamReader]::new($stream, $utf8, $true, 1024, $true)
        try {
            $existing = $reader.ReadToEnd()
            if ($reader.CurrentEncoding.CodePage -ne $utf8.CodePage) {
                throw "OpenSSH key file must be UTF-8 or ASCII: $Path"
            }
        } finally { $reader.Dispose() }
        $blob = [regex]::Escape($PublicKey.Split(' ')[1])
        $pattern = '^[ \t]*(?:(?:[^ \t"\\]|\\.|"(?:[^"\\]|\\.)*")+[ \t]+)?ssh-ed25519[ \t]+{0}(?:[ \t]|$)' -f $blob
        foreach ($line in $existing -split '\r?\n') {
            if ($line -notmatch '^\s*#' -and $line -cmatch $pattern) { return }
        }
        $separator = if ($existing -and -not $existing.EndsWith([string][char]10)) { [Environment]::NewLine } else { '' }
        $append = $utf8.GetBytes($separator + $PublicKey + [Environment]::NewLine)
        $null = $stream.Seek(0, 'End')
        $stream.Write($append, 0, $append.Length)
    } finally { $stream.Dispose() }
}

function Add-JindaOpenSSHManagementKey {
    param([string]$PublicKey)

    $users = @(Get-LocalUser -ErrorAction Stop | Where-Object Enabled)
    $adminSids = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop |
        ForEach-Object { $_.SID.Value })
    $adminUsers = @($users | Where-Object { $_.SID.Value -in $adminSids })
    if ($adminUsers.Count -gt 0) {
        $path = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
        Set-JindaSshAuthorizedKey -Path $path -PublicKey $PublicKey
        Write-Host 'SSH public key configured for local administrators.'
    }
    foreach ($user in $users | Where-Object { $_.SID.Value -notin $adminSids }) {
        $profile = Get-JindaSshProfilePath -User $user
        $profileDirectory = Get-Item -LiteralPath $profile -Force -ErrorAction Stop
        if (-not $profileDirectory.PSIsContainer -or ($profileDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Expected a regular Windows profile directory for $($user.Name)."
        }
        $path = Join-Path $profile '.ssh\authorized_keys'
        Set-JindaSshAuthorizedKey -Path $path -PublicKey $PublicKey -UserSid $user.SID
        Write-Host "SSH public key configured for $($user.Name)."
    }
}

function Install-JindaOpenSSH {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$LanIPAddress, [string]$SshPublicKey)

    # Use Microsoft's in-box features, serviced by Windows Update, not a preview MSI.
    # https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse
    if (-not $PSCmdlet.ShouldProcess('Windows OpenSSH client and server', 'Install and enable SSH on the selected LAN (TCP 22)')) { return $false }
    $ErrorActionPreference = 'Stop'
    $lan = Get-JindaOpenSSHLan -Address $LanIPAddress
    $restartNeeded = $false
    foreach ($name in @('OpenSSH.Client~~~~0.0.1.0', 'OpenSSH.Server~~~~0.0.1.0')) {
        $capability = Get-WindowsCapability -Online -Name $name -ErrorAction Stop
        if (-not $capability) { throw "Windows does not offer the required capability: $name" }
        if ($capability.State -eq 'Installed') {
            Write-Host "$name is already installed."
            continue
        }
        if ($capability.State -ne 'NotPresent') {
            throw "$name has state $($capability.State). Complete any pending Windows servicing or restart, then run setup again."
        }
        Write-Host "Installing $name using Windows optional features..."
        # Add-WindowsCapability reports RestartNeeded; it has no -NoRestart switch.
        $result = Add-WindowsCapability -Online -Name $name -ErrorAction Stop
        if ($result.RestartNeeded) { $restartNeeded = $true }
        $installed = Get-WindowsCapability -Online -Name $name -ErrorAction Stop
        if (-not $result.RestartNeeded -and $installed.State -ne 'Installed') {
            throw "$name was not installed successfully (state: $($installed.State))."
        }
    }

    # The Windows feature normally creates a broad rule. Restrict that same rule
    # before starting sshd; do not create a second rule alongside an unrestricted one.
    $ruleName = 'OpenSSH-Server-In-TCP'
    $rule = Get-NetFirewallRule -PolicyStore PersistentStore -Name $ruleName -ErrorAction SilentlyContinue
    $ruleSettings = @{
        PolicyStore = 'PersistentStore'
        Enabled = 'True'; Direction = 'Inbound'; Action = 'Allow'
        Protocol = 'TCP'; LocalPort = 22
        Profile = 'Any'; EdgeTraversalPolicy = 'Block'
        LocalAddress = $lan.Address; RemoteAddress = $lan.Subnet
        InterfaceAlias = $lan.InterfacePattern
    }
    if ($rule) {
        Set-NetFirewallRule -Name $ruleName @ruleSettings -ErrorAction Stop | Out-Null
    } else {
        New-NetFirewallRule -Name $ruleName -DisplayName 'OpenSSH Server (sshd)' @ruleSettings -ErrorAction Stop | Out-Null
    }
    if ($restartNeeded) {
        Write-Warning 'OpenSSH requires a restart. Restart Windows and run setup again to finish enabling the SSH service.'
        return $true
    }
    $service = Get-Service -Name sshd -ErrorAction Stop
    Set-Service -Name sshd -StartupType Automatic -ErrorAction Stop
    if ($service.Status -ne 'Running') { Start-Service -Name sshd -ErrorAction Stop }
    if ((Get-Service -Name sshd -ErrorAction Stop).Status -ne 'Running') {
        throw 'OpenSSH is installed, but the sshd service is not running.'
    }
    Test-JindaOpenSSHSetup -RuleName $ruleName -Lan $lan
    if ($SshPublicKey) { Add-JindaOpenSSHManagementKey -PublicKey $SshPublicKey }
    Write-Host 'OpenSSH is installed and sshd is configured to start with Windows.'
    Write-Host 'Use an existing Windows account and its password or configured SSH key.'
    return $false
}

function Get-JindaSoftwarePackages {
    # Scope is only forced when the manifest supports it; empty means installer default.
    return @(
        @{ Id = 'Google.Chrome'; Name = 'Google Chrome'; Source = 'winget'; Scope = 'machine'; Extra = @() }
        @{ Id = 'TeamViewer.TeamViewer'; Name = 'TeamViewer'; Source = 'winget'; Scope = 'machine'; Extra = @('--installer-type', 'nullsoft') }
        @{ Id = 'Microsoft.PowerShell'; Name = 'PowerShell 7'; Source = 'winget'; Scope = 'machine'; Extra = @('--installer-type', 'wix') }
        @{ Id = 'Windows.OpenSSH'; Name = 'OpenSSH client and server'; Source = 'windows-capability' }
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
        @{ Id = 'ScooterSoftware.BeyondCompare.5'; Name = 'Beyond Compare 5'; Source = 'winget'; Scope = 'machine'; Extra = @('--locale', 'en') }
        @{ Id = '9NT1R1C2HH7J'; Name = 'ChatGPT Classic'; Source = 'msstore'; Scope = ''; Extra = @() }
        # The Codex desktop app is now named ChatGPT; OpenAI.Codex is the separate CLI.
        @{ Id = 'OpenAI.ChatGPT'; Name = 'Codex desktop (ChatGPT)'; Source = 'winget'; Scope = ''; Extra = @('--installer-type', 'msix') }
        @{ Id = 'OpenWhisperSystems.Signal'; Name = 'Signal'; Source = 'winget'; Scope = 'user'; Extra = @() }
        @{ Id = 'OBSProject.OBSStudio'; Name = 'OBS Studio'; Source = 'winget'; Scope = 'machine'; Extra = @('--installer-type', 'nullsoft') }
        @{ Id = 'Adobe.Acrobat.Reader.64-bit'; Name = 'Adobe Acrobat Reader'; Source = 'winget'; Scope = 'machine'; Extra = @() }
        # Yodeck uses its signed official installer; WhatsApp must be the final app.
        @{ Id = 'Yodeck.Player'; Name = 'Yodeck Player'; Source = 'yodeck' }
        @{ Id = '9NKSQGP7F2NH'; Name = 'WhatsApp'; Source = 'msstore'; Scope = ''; Extra = @() }
    )
}

function Get-JindaSkippedApps {
    param(
        [string]$Path = (Join-Path $PSScriptRoot 'skip-apps.conf'),
        [string]$LocalPath = 'C:\Support\skip-apps.conf'
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "App skip configuration is missing: $Path. Download the complete Jinda package."
    }
    $configPaths = @($Path)
    if (Test-Path -LiteralPath $LocalPath -ErrorAction Stop) {
        $configPaths += $LocalPath
    }
    $knownIds = @(Get-JindaSoftwarePackages | ForEach-Object { $_.Id }) + @('Discord.Discord', 'Microsoft.Teams')
    $skipped = @()
    foreach ($configPath in $configPaths) {
        $lineNumber = 0
        foreach ($line in (Get-Content -LiteralPath $configPath -Encoding UTF8 -ErrorAction Stop)) {
            $lineNumber++
            $id = ($line -replace '#.*$', '').Trim()
            if (-not $id) { continue }
            if ($id -notin $knownIds) {
                throw "Unknown app ID '$id' in ${configPath} at line $lineNumber. Use an ID from the commented app list."
            }
            if ($id -notin $skipped) { $skipped += $id }
        }
    }
    return $skipped
}

function Install-JindaSoftware {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([switch]$EnableOpenSSH, [switch]$SkipApps, [string]$LanIPAddress, [string]$SshPublicKey)

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    # Validate the package list and any machine-specific list before installing.
    $skippedApps = @(Get-JindaSkippedApps)
    if ($SshPublicKey) {
        if (-not $EnableOpenSSH -or 'Windows.OpenSSH' -in $skippedApps) {
            throw 'The public key requires the OpenSSH installation option to be enabled and not skipped.'
        }
        $SshPublicKey = ConvertTo-JindaEd25519PublicKey -PublicKey $SshPublicKey
    }
    $packages = @(foreach ($package in (Get-JindaSoftwarePackages)) {
        if ($package.Id -eq 'Windows.OpenSSH' -and -not $EnableOpenSSH) {
            Write-Host 'OpenSSH was not selected; existing installation and settings are unchanged.'
            continue
        }
        if ($SkipApps -and $package.Id -ne 'Windows.OpenSSH') { continue }
        if ($package.Id -in $skippedApps) {
            Write-Host ''
            Write-Host "$($package.Name): skipped by skip-apps.conf; existing installation left unchanged."
        } else {
            $package
        }
    })
    if ($packages.Count -eq 0) {
        Write-Host 'No software components selected. No app, OpenSSH or WinGet changes will run.'
        return $false
    }
    $needsWinGet = @($packages | Where-Object { $_.Source -in @('winget', 'msstore') }).Count -gt 0
    $winget = $null
    if ($needsWinGet) {
        $winget = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue
        if (-not $winget) {
            throw 'WinGet is missing. Install or update App Installer using the Microsoft Store, then reopen PowerShell.'
        }
    }

    $restartNeeded = $false
    if ($needsWinGet -and $PSCmdlet.ShouldProcess('WinGet (Microsoft.AppInstaller)', 'Upgrade if a newer version is available')) {
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

    foreach ($package in $packages) {
        if ($package.Source -eq 'windows-capability') {
            if (Install-JindaOpenSSH -LanIPAddress $LanIPAddress -SshPublicKey $SshPublicKey -WhatIf:$WhatIfPreference) { $restartNeeded = $true }
            continue
        }
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
        $scriptArguments = @()
        if ($EnableOpenSSH) { $scriptArguments += '-EnableOpenSSH' }
        if ($SkipApps) { $scriptArguments += '-SkipApps' }
        if ($LanIPAddress) { $scriptArguments += @('-LanIPAddress', $LanIPAddress) }
        if ($SshPublicKey) { $scriptArguments += @('-SshPublicKey', $SshPublicKey) }
        $exitCode = Invoke-JindaManagedScript -ScriptPath $PSCommandPath -ScriptArguments $scriptArguments -RuntimeReady:$RuntimeReady -WhatIf:$WhatIfPreference -Work {
            if (Install-JindaSoftware -EnableOpenSSH:$EnableOpenSSH -SkipApps:$SkipApps -LanIPAddress $LanIPAddress -SshPublicKey $SshPublicKey) { return 3010 }
            return 0
        }
        exit $exitCode
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
