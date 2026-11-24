#Requires -Version 5.1
# Read-only verification: never runs the downloaded server script.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string]$CommitSha,
    [switch]$ScriptsOnly,
    [ValidateRange(1, 180)][int]$TimeoutSeconds = 60
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Test-PagesPublication.ps1') -CommitSha $CommitSha -ScriptsOnly:$ScriptsOnly -TimeoutSeconds $TimeoutSeconds
$headers = @{ Accept = 'application/vnd.github+json' }
if ($env:GH_TOKEN) { $headers.Authorization = 'Bearer ' + $env:GH_TOKEN }
$api = 'https://api.github.com/repos/acurvers/jinda-operations'
$tree = Invoke-RestMethod "$api/git/trees/${CommitSha}?recursive=1" -Headers $headers -TimeoutSec 20
if ($tree.truncated) { throw 'Incomplete Git tree.' }
function Assert-ServerPublishedBytes {
    param([string]$Path, [byte[]]$Bytes)
    $entry = @($tree.tree | Where-Object { $_.path -eq $Path -and $_.type -eq 'blob' })
    if ($entry.Count -ne 1 -or (Get-JindaGitBlobSha $Bytes) -ne $entry[0].sha) { throw "Downloaded content differs from commit: $Path" }
    Write-Host "Verified exact commit bytes: $Path"
}
$raw = 'https://raw.githubusercontent.com/acurvers/jinda-operations/main/windows-server.zip'
$response = Invoke-WebRequest $raw -UseBasicParsing -TimeoutSec 60
$memory = New-Object IO.MemoryStream
$response.RawContentStream.CopyTo($memory)
$bytes = $memory.ToArray()
Assert-ServerPublishedBytes 'windows-server.zip' $bytes
Add-Type -AssemblyName System.IO.Compression
$memory.Position = 0
$zip = New-Object IO.Compression.ZipArchive($memory, [IO.Compression.ZipArchiveMode]::Read)
try {
    if ($zip.Entries.Count -ne 2) { throw 'Unexpected files in server ZIP.' }
    foreach ($name in @('Enable-ServerRemoteAccess.ps1', 'README.md')) {
        $entry = $zip.GetEntry($name)
        if (-not $entry) { throw "Missing ZIP entry: $name" }
        $inputStream = $entry.Open(); $buffer = New-Object IO.MemoryStream
        try { $inputStream.CopyTo($buffer); Assert-ServerPublishedBytes "windows-server/$name" $buffer.ToArray() }
        finally { $inputStream.Dispose(); $buffer.Dispose() }
    }
}
finally { $zip.Dispose(); $memory.Dispose() }
if ($ScriptsOnly) { Write-Host 'Server ZIP publication verified.'; exit 0 }
$timer = [Diagnostics.Stopwatch]::StartNew()
do {
    $runs = Invoke-RestMethod "$api/actions/runs?per_page=100" -Headers $headers -TimeoutSec 20
    $run = $runs.workflow_runs | Where-Object { $_.head_sha -eq $CommitSha -and $_.name -eq 'pages build and deployment' } | Sort-Object id -Descending | Select-Object -First 1
    if ($run -and $run.status -eq 'completed') {
        if ($run.conclusion -ne 'success') { throw "Pages publication $($run.conclusion): $($run.html_url)" }
        $page = Invoke-WebRequest 'https://acurvers.github.io/jinda-operations/windows-server.html' -UseBasicParsing -TimeoutSec 20
        $buffer = New-Object IO.MemoryStream
        try { $page.RawContentStream.CopyTo($buffer); Assert-ServerPublishedBytes 'windows-server.html' $buffer.ToArray() }
        finally { $buffer.Dispose() }
        Write-Host "Server page live; successful Pages run: $($run.html_url)"
        exit 0
    }
    if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
    Write-Host 'Server ZIP verified; waiting for the Pages deployment.'
    Start-Sleep -Seconds ([Math]::Min(10, [Math]::Max(1, $TimeoutSeconds - [int]$timer.Elapsed.TotalSeconds)))
} while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
throw 'Server ZIP verified, but Server webpage publication not yet confirmed.'
