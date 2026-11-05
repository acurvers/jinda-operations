#Requires -Version 5.1
<#
.SYNOPSIS
Controleert directe scriptdownloads of de Pages-webpagina voor een exacte commit.
.DESCRIPTION
Alleen lezen: geen installatie, herstart, publicatie of automatische retry van een
geannuleerde workflow. Met -ScriptsOnly worden de drie scripts en skip-apps.conf uit het GitHub-ZIP
byte voor byte gecontroleerd, zonder Pages. Zonder die switch wordt de geslaagde
Pages-run plus index.html gecontroleerd. Exitcode 0 bevestigt de gekozen controle.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[0-9a-f]{40}$')][string]$CommitSha,
    [switch]$ScriptsOnly,
    [ValidateRange(1, 1800)][int]$TimeoutSeconds = 600,
    [ValidateRange(1, 60)][int]$PollSeconds = 20
)

function Get-JindaGitBlobSha {
    param([AllowEmptyCollection()][byte[]]$Bytes)
    $buffer = New-Object IO.MemoryStream
    $hash = [Security.Cryptography.SHA1]::Create()
    try {
        $prefix = [Text.Encoding]::UTF8.GetBytes("blob $($Bytes.Length)`0")
        $buffer.Write($prefix, 0, $prefix.Length)
        $buffer.Write($Bytes, 0, $Bytes.Length)
        return ([BitConverter]::ToString($hash.ComputeHash($buffer.ToArray()))).Replace('-', '').ToLowerInvariant()
    }
    finally { $hash.Dispose(); $buffer.Dispose() }
}

function Get-JindaPublicBlobSha {
    param([string]$Uri)
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Uri -TimeoutSec 20 -ErrorAction Stop
    if ($response.StatusCode -ne 200) { throw "HTTP $($response.StatusCode): $Uri" }
    # Hash the received bytes, preserving BOM and line endings. No cache-busting:
    # this must check the same URL that the user actually downloads.
    $buffer = New-Object IO.MemoryStream
    try {
        $response.RawContentStream.Position = 0
        $response.RawContentStream.CopyTo($buffer)
        return Get-JindaGitBlobSha -Bytes $buffer.ToArray()
    }
    finally { $buffer.Dispose() }
}

function Get-JindaArchiveBlobShas {
    $response = Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/acurvers/jinda-operations/archive/refs/heads/main.zip' -TimeoutSec 60 -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression
    $response.RawContentStream.Position = 0
    $archive = [IO.Compression.ZipArchive]::new($response.RawContentStream, [IO.Compression.ZipArchiveMode]::Read)
    try {
        $hashes = @{}
        foreach ($path in @('init.ps1', 'install-software.ps1', 'set-windows-english.ps1', 'skip-apps.conf')) {
            $entry = $archive.GetEntry("jinda-operations-main/$path")
            if (-not $entry) { throw "Script ontbreekt in GitHub-ZIP: $path" }
            $stream = $entry.Open()
            $buffer = New-Object IO.MemoryStream
            try {
                $stream.CopyTo($buffer)
                $hashes[$path] = Get-JindaGitBlobSha -Bytes $buffer.ToArray()
            }
            finally { $stream.Dispose(); $buffer.Dispose() }
        }
        return $hashes
    }
    finally { $archive.Dispose() }
}

function Test-JindaPagesPublication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string]$CommitSha,
        [switch]$ScriptsOnly,
        [ValidateRange(1, 1800)][int]$TimeoutSeconds = 600,
        [ValidateRange(1, 60)][int]$PollSeconds = 20
    )
    $api = 'https://api.github.com/repos/acurvers/jinda-operations'
    $site = 'https://acurvers.github.io/jinda-operations'
    $headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    # Optional for maintainers checking publication repeatedly; setup needs no API.
    if ($env:GH_TOKEN) { $headers.Authorization = 'Bearer ' + $env:GH_TOKEN }
    $paths = if ($ScriptsOnly) { @('init.ps1', 'install-software.ps1', 'set-windows-english.ps1', 'skip-apps.conf') } else { @('index.html') }
    $tree = Invoke-RestMethod -Uri "$api/git/trees/${CommitSha}?recursive=1" -Headers $headers -TimeoutSec 20 -ErrorAction Stop
    if ($tree.truncated) { throw 'Git-bestandenlijst is onvolledig; publicatie niet bevestigd.' }
    $expected = @{}
    foreach ($path in $paths) {
        $entry = @($tree.tree | Where-Object { $_.path -eq $path -and $_.type -eq 'blob' })
        if ($entry.Count -ne 1) { throw "Verplicht publicatiebestand ontbreekt in commit: $path" }
        $expected[$path] = $entry[0].sha
    }

    if ($ScriptsOnly) {
        $downloaded = Get-JindaArchiveBlobShas
        foreach ($path in $paths) {
            if ($downloaded[$path] -ne $expected[$path]) {
                throw "GitHub-download $path wijkt af van de gevraagde commit."
            }
        }
        return [pscustomobject]@{
            Verified = $true; Commit = $CommitSha; Source = 'GitHub ZIP'; Files = $paths.Count
            CheckedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
    }

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lastStatus = 'Nog geen passende Pages-run gevonden.'
    do {
        try {
            $runs = Invoke-RestMethod -Uri "$api/actions/runs?per_page=100" -Headers $headers -TimeoutSec 20 -ErrorAction Stop
            $run = $runs.workflow_runs | Where-Object {
                $_.head_sha -eq $CommitSha -and $_.name -eq 'pages build and deployment'
            } | Sort-Object id -Descending | Select-Object -First 1
        }
        catch { throw "Pages-status kon niet worden gecontroleerd: $($_.Exception.Message)" }

        if ($run -and $run.status -eq 'completed' -and $run.conclusion -ne 'success') {
            throw "Pages-publicatie $($run.conclusion); NIET gepubliceerd bevestigd. $($run.html_url)"
        }
        if ($run -and $run.status -eq 'completed' -and $run.conclusion -eq 'success') {
            $pending = @()
            foreach ($path in $paths) {
                try {
                    if ((Get-JindaPublicBlobSha -Uri "$site/$path") -ne $expected[$path]) {
                        $pending += "$path wijkt nog af"
                    }
                }
                catch { $pending += "$path niet bereikbaar: $($_.Exception.Message)" }
            }
            if ($pending.Count -eq 0) {
                return [pscustomobject]@{
                    Verified = $true; Commit = $CommitSha; Run = $run.html_url
                    Files = $paths.Count; CheckedAtUtc = [DateTime]::UtcNow.ToString('o')
                }
            }
            $lastStatus = $pending -join '; '
        }
        elseif ($run) { $lastStatus = "Pages-status: $($run.status)." }
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
        Write-Host "Publicatie nog niet bevestigd: $lastStatus"
        $remaining = [Math]::Ceiling($TimeoutSeconds - $timer.Elapsed.TotalSeconds)
        if ($remaining -gt 0) { Start-Sleep -Seconds ([Math]::Min($PollSeconds, $remaining)) }
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw "Publicatie niet bevestigd binnen $TimeoutSeconds seconden. $lastStatus"
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        if (-not $CommitSha) { throw 'Geef de volledige gepubliceerde commit op met -CommitSha.' }
        Test-JindaPagesPublication -CommitSha $CommitSha -ScriptsOnly:$ScriptsOnly -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds
        exit 0
    }
    catch { Write-Error $_ -ErrorAction Continue; exit 1 }
}
