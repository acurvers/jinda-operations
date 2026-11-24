#Requires -Version 3.0
<#
.SYNOPSIS
Enable selected RDP, Windows PowerShell remoting and IPv4 ping on Server 2012/R2.
.DESCRIPTION
Collects all choices before applying settings. Uses native 64-bit Windows
PowerShell, including when launched from an x86 console. No apps, language,
account/password policies, routing or client TrustedHosts configuration.
Windows Firewall with Advanced Security on the target server: scopes the
selected built-in inbound rules to one local IPv4 interface and allowed sources.
Existing custom rules and centrally managed rules are not rewritten.
.PARAMETER RemoteDesktop
Ask, Yes or No. No skips configuration; it does not disable existing RDP.
.PARAMETER WinRM
Ask, Yes or No. Uses the existing Windows PowerShell endpoint, not PowerShell 7.
Enabling remoting can restart WinRM and interrupt existing WinRM sessions.
.PARAMETER Ping
Ask, Yes or No. Enables a dedicated inbound ICMPv4 echo rule.
.PARAMETER AllowedRemoteAddresses
Explicit IPv4 addresses/subnets, for example 192.168.40.0/24,10.6.0.3.
When omitted, asks at startup with the selected LAN subnet as the default.
.EXAMPLE
.\Enable-ServerRemoteAccess.ps1 -RemoteDesktop Yes -WinRM Yes -Ping Yes -LanIPAddress 192.168.40.20 -AllowedRemoteAddresses 192.168.40.0/24,10.6.0.3
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Ask', 'Yes', 'No')][string]$RemoteDesktop = 'Ask',
    [ValidateSet('Ask', 'Yes', 'No')][string]$WinRM = 'Ask',
    [ValidateSet('Ask', 'Yes', 'No')][string]$Ping = 'Ask',
    [string]$LanIPAddress,
    [string[]]$AllowedRemoteAddresses,
    [switch]$RuntimeReady
)

function Test-ServerAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ServerNativePowerShell {
    $folder = if ([Environment]::Is64BitProcess) { 'System32' } else { 'Sysnative' }
    return Join-Path $env:WINDIR "$folder\WindowsPowerShell\v1.0\powershell.exe"
}

function Read-ServerYesNo {
    param([string]$Prompt, [string]$Choice = 'Ask')
    if ($Choice -ne 'Ask') { return ($Choice -eq 'Yes') }
    while ($true) {
        $answer = ([string](Read-Host "$Prompt (N = skip; leave existing settings unchanged) [Y/n]")).Trim().ToLowerInvariant()
        if ($answer -in @('', 'y', 'yes', 'j', 'ja')) { return $true }
        if ($answer -in @('n', 'no', 'nee')) { return $false }
        Write-Host 'Please enter y or n.'
    }
}

function ConvertTo-ServerAllowedAddresses {
    param([string[]]$Addresses)
    $result = @(foreach ($item in $Addresses) {
        foreach ($value in ($item -split ',')) {
            $value = $value.Trim()
            if (-not $value) { continue }
            # Strict dotted IPv4; do not accept Any, hostnames or abbreviated IPs.
            if ($value -notmatch '^(\d{1,3}\.){3}\d{1,3}(/\d{1,2})?$') { throw "Invalid IPv4 address/subnet: $value" }
            $parts = $value -split '/'
            foreach ($octet in ($parts[0] -split '\.')) {
                if ([int]$octet -gt 255) { throw "Invalid IPv4 address: $value" }
            }
            if ($parts.Count -eq 2 -and ([int]$parts[1] -lt 1 -or [int]$parts[1] -gt 32)) {
                throw "Use an IPv4 prefix between 1 and 32: $value"
            }
            $value
        }
    })
    if ($result.Count -eq 0) { throw 'At least one allowed IPv4 address or subnet is required.' }
    return @($result | Select-Object -Unique)
}

function Get-ServerSubnet {
    param([string]$IPAddress, [int]$PrefixLength)
    $bytes = [Net.IPAddress]::Parse($IPAddress).GetAddressBytes()
    for ($i = 0; $i -lt 4; $i++) {
        $bits = [Math]::Min(8, [Math]::Max(0, $PrefixLength - 8 * $i))
        $mask = if ($bits -eq 0) { 0 } else { (255 -shl (8 - $bits)) -band 255 }
        $bytes[$i] = $bytes[$i] -band $mask
    }
    return ('{0}/{1}' -f ($bytes -join '.'), $PrefixLength)
}

function Select-ServerLan {
    param([string]$IPAddress)
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
        $_.AddressState -eq 'Preferred' -and $_.PrefixLength -ge 1 -and $_.PrefixLength -le 30 -and
        $_.IPAddress -notmatch '^(127\.|169\.254\.|0\.)'
    } | Sort-Object InterfaceIndex, IPAddress)
    if ($IPAddress) {
        $selected = @($addresses | Where-Object { $_.IPAddress -eq $IPAddress })
        if ($selected.Count -ne 1) { throw 'LanIPAddress must match one active local IPv4 address.' }
        return $selected[0]
    }
    if ($addresses.Count -eq 0) { throw 'No active IPv4 LAN address found.' }
    if ($addresses.Count -eq 1) { return $addresses[0] }
    Write-Host 'Select the server LAN interface:'
    for ($i = 0; $i -lt $addresses.Count; $i++) {
        Write-Host ('{0}: {1} - {2}/{3}' -f ($i + 1), $addresses[$i].InterfaceAlias, $addresses[$i].IPAddress, $addresses[$i].PrefixLength)
    }
    while ($true) {
        $number = 0
        $answer = Read-Host 'LAN number'
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $addresses.Count) {
            return $addresses[$number - 1]
        }
        Write-Host 'Select a number from the list.'
    }
}

function Get-ServerAccessPlan {
    param($Lan, [string[]]$Sources, [bool]$Rdp, [bool]$Remoting, [bool]$Echo)
    $ErrorActionPreference = 'Stop'
    $profiles = @(Get-NetConnectionProfile -InterfaceIndex $Lan.InterfaceIndex)
    if ($profiles.Count -ne 1) { throw 'Cannot identify a unique network profile for the selected LAN.' }
    $profile = if ($profiles[0].NetworkCategory -eq 'DomainAuthenticated') { 'Domain' } else { [string]$profiles[0].NetworkCategory }
    $policy = Get-NetFirewallProfile -PolicyStore ActiveStore -Name $profile
    if ([string]$policy.Enabled -ne 'True' -or [string]$policy.AllowLocalFirewallRules -eq 'False') {
        throw 'Windows Firewall with Advanced Security on this server must be enabled and allow local rules. Review central policy first.'
    }
    $patterns = @()
    if ($Rdp) { $patterns += @('RemoteDesktop-UserMode-In-TCP', 'RemoteDesktop-UserMode-In-UDP') }
    if ($Remoting) { $patterns += 'WINRM-HTTP-In-TCP*' }
    $rules = @()
    if ($patterns.Count) {
        $rules = @(Get-NetFirewallRule -PolicyStore PersistentStore -Name $patterns -ErrorAction SilentlyContinue | Where-Object { $_.Direction -eq 'Inbound' })
    }
    if ($Rdp) {
        foreach ($name in @('RemoteDesktop-UserMode-In-TCP', 'RemoteDesktop-UserMode-In-UDP')) {
            if ($name -notin $rules.Name) { throw "Missing built-in Windows Firewall rule on this server: $name" }
        }
        $rdpPolicy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -ErrorAction SilentlyContinue
        if ($rdpPolicy -and $rdpPolicy.PSObject.Properties['fDenyTSConnections'] -and $rdpPolicy.fDenyTSConnections -eq 1) {
            throw 'Remote Desktop is denied by policy. Review central policy first.'
        }
    }
    if ($Remoting -and @($rules | Where-Object { $_.Name -like 'WINRM-HTTP-In-TCP*' }).Count -eq 0) {
        throw 'Missing built-in WinRM HTTP rules in Windows Firewall with Advanced Security on this server.'
    }
    $activeNames = @($rules | ForEach-Object { $_.Name })
    if ($Echo) { $activeNames += 'Jinda-Server-ICMPv4-In' }
    foreach ($name in $activeNames) {
        $effective = @(Get-NetFirewallRule -PolicyStore ActiveStore -Name $name -ErrorAction SilentlyContinue)
        if (@($effective | Where-Object { $_.PolicyStoreSourceType -eq 'GroupPolicy' }).Count) {
            throw "Windows Firewall rule on this server is centrally managed: $name"
        }
    }
    $port = 3389
    if ($Rdp) {
        $port = [int](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name PortNumber).PortNumber
        if ($port -lt 1 -or $port -gt 65535) { throw 'Invalid existing RDP port.' }
    }
    return [pscustomobject]@{
        Lan = $Lan; Sources = @(ConvertTo-ServerAllowedAddresses $Sources)
        Rdp = $Rdp; Remoting = $Remoting; Echo = $Echo; RdpPort = $port; Rules = $rules; Patterns = $patterns
    }
}

function Set-ServerRuleScope {
    param($Plan)
    foreach ($rule in $Plan.Rules) {
        Set-NetFirewallRule -PolicyStore PersistentStore -Name $rule.Name -Profile Any `
            -InterfaceAlias $Plan.Lan.InterfaceAlias -LocalAddress $Plan.Lan.IPAddress `
            -RemoteAddress $Plan.Sources -ErrorAction Stop | Out-Null
    }
}

function Get-ServerRuleAddressFilter {
    param($Rule)
    return ($Rule | Get-NetFirewallAddressFilter -ErrorAction Stop)
}

function ConvertTo-ServerCanonicalAddress {
    param([string]$Address)
    $parts = $Address -split '/'
    $prefix = 32
    if ($parts.Count -eq 2) {
        if ($parts[1] -match '^\d+$') { $prefix = [int]$parts[1] }
        else {
            # Windows Server 2012 may report a dotted mask instead of a prefix.
            $bits = (([Net.IPAddress]::Parse($parts[1]).GetAddressBytes() | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join '')
            if ($bits -notmatch '^1*0*$') { throw "Non-contiguous IPv4 mask: $Address" }
            $prefix = ($bits -replace '0', '').Length
        }
    }
    return Get-ServerSubnet -IPAddress $parts[0] -PrefixLength $prefix
}

function Invoke-ServerAccessPlan {
    param($Plan)
    $ErrorActionPreference = 'Stop'
    # Scope existing built-in Windows Firewall rules before enabling access.
    Set-ServerRuleScope $Plan
    if ($Plan.Remoting) {
        Write-Host ''
        Write-Host 'Enabling Windows PowerShell remoting on HTTP/TCP 5985...'
        try {
            Enable-PSRemoting -SkipNetworkProfileCheck -Force -ErrorAction Stop | Out-Host
        }
        finally {
            # Enable-PSRemoting may create/modify the built-in Windows Firewall rules.
            $Plan.Rules = @(Get-NetFirewallRule -PolicyStore PersistentStore -Name $Plan.Patterns -ErrorAction Stop | Where-Object { $_.Direction -eq 'Inbound' })
            Set-ServerRuleScope $Plan
        }
        foreach ($rule in $Plan.Rules | Where-Object { $_.Name -like 'WINRM-HTTP-In-TCP*' }) {
            Set-NetFirewallRule -PolicyStore PersistentStore -Name $rule.Name -Enabled True -Protocol TCP -LocalPort 5985 | Out-Null
        }
        foreach ($setting in @(@{ Path = 'WSMan:\localhost\Service\AllowUnencrypted'; Value = $false }, @{ Path = 'WSMan:\localhost\Service\Auth\Basic'; Value = $false })) {
            if ([string](Get-Item -LiteralPath $setting.Path).Value -ine 'false') {
                Set-Item -LiteralPath $setting.Path -Value $setting.Value -Force
            }
            if ([string](Get-Item -LiteralPath $setting.Path).Value -ine 'false') { throw "Could not verify $($setting.Path)." }
        }
        Test-WSMan -ComputerName localhost -ErrorAction Stop | Out-Null
    }
    if ($Plan.Rdp) {
        Write-Host ''
        Write-Host "Enabling Remote Desktop with NLA on existing port $($Plan.RdpPort)..."
        foreach ($protocol in @('TCP', 'UDP')) {
            Set-NetFirewallRule -PolicyStore PersistentStore -Name "RemoteDesktop-UserMode-In-$protocol" -Enabled True -Protocol $protocol -LocalPort $Plan.RdpPort | Out-Null
        }
        Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
        Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1
        Set-Service -Name TermService -StartupType Automatic
        Start-Service -Name TermService
    }
    if ($Plan.Echo) {
        Write-Host ''
        Write-Host 'Enabling IPv4 ping from the allowed sources...'
        $settings = @{
            PolicyStore = 'PersistentStore'; Direction = 'Inbound'; Action = 'Allow'; Enabled = 'True'
            Profile = 'Any'; Protocol = 'ICMPv4'; IcmpType = 8
            InterfaceAlias = $Plan.Lan.InterfaceAlias; LocalAddress = $Plan.Lan.IPAddress; RemoteAddress = $Plan.Sources
        }
        $name = 'Jinda-Server-ICMPv4-In'
        if (Get-NetFirewallRule -PolicyStore PersistentStore -Name $name -ErrorAction SilentlyContinue) {
            Set-NetFirewallRule -Name $name @settings | Out-Null
        } else {
            New-NetFirewallRule -Name $name -DisplayName 'Jinda Server - IPv4 echo from allowed management sources' @settings | Out-Null
        }
    }
    # Read the effective rules, rather than reporting only saved configuration.
    $names = @($Plan.Rules | ForEach-Object { $_.Name })
    if ($Plan.Echo) { $names += 'Jinda-Server-ICMPv4-In' }
    foreach ($name in $names) {
        $rule = Get-NetFirewallRule -PolicyStore ActiveStore -Name $name -ErrorAction Stop
        $filter = Get-ServerRuleAddressFilter $rule
        if ([string]$rule.Enabled -ne 'True' -or [string]$rule.Action -ne 'Allow') {
            throw "Effective Windows Firewall rule on this server is not enabled/Allow: $name"
        }
        $expectedSources = @($Plan.Sources | ForEach-Object { ConvertTo-ServerCanonicalAddress $_ } | Sort-Object -Unique)
        $actualSources = @($filter.RemoteAddress | ForEach-Object { ConvertTo-ServerCanonicalAddress $_ } | Sort-Object -Unique)
        $local = @($filter.LocalAddress | ForEach-Object { ConvertTo-ServerCanonicalAddress $_ })
        if (($expectedSources -join ',') -ne ($actualSources -join ',') -or $local.Count -ne 1 -or
            $local[0] -ne (ConvertTo-ServerCanonicalAddress $Plan.Lan.IPAddress)) {
            throw "Effective Windows Firewall address limits on this server differ from the plan: $name"
        }
        Write-Host ("Windows Firewall on {0}: {1}; local={2}; sources={3}" -f $env:COMPUTERNAME, $name, ($filter.LocalAddress -join ','), ($filter.RemoteAddress -join ','))
    }
    Write-Host ''
    Write-Host 'Selected settings applied. No server reboot was requested.'
    Write-Host 'Test access from your management PC. Other custom/central rules can also affect access.'
    if ($Plan.Remoting) {
        Write-Host "WinRM: Enter-PSSession -ComputerName $($Plan.Lan.IPAddress) -ConfigurationName Microsoft.PowerShell -Authentication Negotiate -Credential (Get-Credential)"
        Write-Host 'Use an existing authorized Windows account; client TrustedHosts/HTTPS is a separate configuration.'
    }
}

function Start-ServerRemoteAccess {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable]$Options, [string]$ScriptPath)
    $ErrorActionPreference = 'Stop'
    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Configure selected Server 2012 RDP, WinRM and IPv4 ping access')) { return }
    if (-not (Test-ServerAdministrator) -or -not [Environment]::Is64BitProcess) {
        if ($Options.RuntimeReady) { throw 'The relaunched process is not an elevated native 64-bit Windows PowerShell process.' }
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, '-RuntimeReady')
        foreach ($name in @('RemoteDesktop', 'WinRM', 'Ping', 'LanIPAddress')) {
            if ($Options[$name]) { $arguments += @('-' + $name, [string]$Options[$name]) }
        }
        if ($Options.AllowedRemoteAddresses) { $arguments += @('-AllowedRemoteAddresses', ($Options.AllowedRemoteAddresses -join ',')) }
        if (@($arguments | Where-Object { $_ -match '["\r\n]' }).Count) { throw 'Invalid characters in script path or arguments.' }
        $line = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
        $start = @{ FilePath = (Get-ServerNativePowerShell); ArgumentList = $line; Wait = $true; PassThru = $true }
        if (-not (Test-ServerAdministrator)) { $start.Verb = 'RunAs' }
        Write-Host 'Starting native 64-bit Windows PowerShell with administrator privileges...'
        $child = Start-Process @start -ErrorAction Stop
        if ($child.ExitCode -ne 0) { throw "Server setup failed (exit code $($child.ExitCode))." }
        return
    }
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    if ($os.ProductType -notin @(2, 3) -or [string]$os.Version -notmatch '^6\.[23]\.') {
        throw 'This separate script supports Windows Server 2012 and 2012 R2 only.'
    }
    Write-Host ("{0}; Windows PowerShell {1}; native 64-bit; administrator." -f $os.Caption, $PSVersionTable.PSVersion)
    Write-Host 'Choose all options now. Afterwards setup continues without further questions.'
    $rdp = Read-ServerYesNo 'Enable Remote Desktop (RDP)?' $Options.RemoteDesktop
    $remoting = Read-ServerYesNo 'Enable Windows PowerShell remoting (WinRM)?' $Options.WinRM
    $echo = Read-ServerYesNo 'Allow IPv4 ping?' $Options.Ping
    if (-not $rdp -and -not $remoting -and -not $echo) { Write-Host 'All components skipped.'; return }
    $lan = Select-ServerLan $Options.LanIPAddress
    $sources = $Options.AllowedRemoteAddresses
    if (-not $sources) {
        $subnet = Get-ServerSubnet $lan.IPAddress $lan.PrefixLength
        Write-Host "Selected LAN: $($lan.InterfaceAlias) - $($lan.IPAddress)/$($lan.PrefixLength)"
        Write-Host 'Standard Windows Firewall rules on this server will use these sources. Include your management/VPN IP if it is outside this LAN.'
        while ($true) {
            $answer = Read-Host "Allowed IPv4 addresses/subnets, comma-separated [Enter = $subnet]"
            if (-not $answer.Trim()) { $answer = $subnet }
            try { $sources = @(ConvertTo-ServerAllowedAddresses @($answer)); break }
            catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }
        }
    }
    $plan = Get-ServerAccessPlan -Lan $lan -Sources $sources -Rdp $rdp -Remoting $remoting -Echo $echo
    Write-Host ("Setup choices: RDP={0}; WinRM={1}; Ping={2}; server={3}; allowed={4}" -f $rdp, $remoting, $echo, $lan.IPAddress, ($plan.Sources -join ', '))
    $logDirectory = Join-Path $env:LOCALAPPDATA 'JindaOperations\Logs'
    $null = New-Item -ItemType Directory -Path $logDirectory -Force
    $log = Join-Path $logDirectory ('server-remote-access-{0}-{1}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PID)
    $null = Start-Transcript -Path $log -Force
    try { Write-Host "Log file: $log"; Invoke-ServerAccessPlan $plan }
    finally { $null = Stop-Transcript -ErrorAction SilentlyContinue }
}

# Dot-sourcing loads functions for offline tests; it never starts setup.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $options = @{ RemoteDesktop = $RemoteDesktop; WinRM = $WinRM; Ping = $Ping; LanIPAddress = $LanIPAddress; AllowedRemoteAddresses = $AllowedRemoteAddresses; RuntimeReady = $RuntimeReady }
        Start-ServerRemoteAccess -Options $options -ScriptPath $PSCommandPath -WhatIf:$WhatIfPreference
        exit 0
    }
    catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red; Write-Host $_.ScriptStackTrace; exit 1 }
}
