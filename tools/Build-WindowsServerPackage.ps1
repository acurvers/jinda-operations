#Requires -Version 5.1
# Build only: never runs the server configuration.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
# Keep ZIP compression bytes stable between PowerShell 7/.NET and .NET Framework.
if ($PSVersionTable.PSEdition -eq 'Core') {
    & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    if ($LASTEXITCODE -ne 0) { throw 'Windows PowerShell package build failed.' }
    return
}
Add-Type -AssemblyName System.IO.Compression
$root = Split-Path $PSScriptRoot -Parent
$path = Join-Path $root 'windows-server.zip'
$stream = [IO.File]::Open($path, [IO.FileMode]::Create)
$zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($name in @('Enable-ServerRemoteAccess.ps1', 'README.md')) {
        $entry = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
        # Deterministic timestamp: identical source files produce an identical ZIP.
        $entry.LastWriteTime = [DateTimeOffset]'2026-11-24T00:00:00+00:00'
        $output = $entry.Open()
        $inputFile = [IO.File]::OpenRead((Join-Path $root "windows-server\$name"))
        try { $inputFile.CopyTo($output) }
        finally { $inputFile.Dispose(); $output.Dispose() }
    }
}
finally { $zip.Dispose(); $stream.Dispose() }
$hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
$pagePath = Join-Path $root 'windows-server.html'
$page = [IO.File]::ReadAllText($pagePath)
if (-not $page.Contains('<!-- package-sha256 -->') -or [regex]::Matches($page, '\$expected = &quot;[a-fA-F0-9]{64}&quot;').Count -ne 1) { throw 'Missing or duplicate package hash marker in windows-server.html.' }
$page = [regex]::Replace($page, "(?<=\`$expected = &quot;)[a-fA-F0-9]{64}(?=&quot;)", $hash)
[IO.File]::WriteAllText($pagePath, $page, (New-Object Text.UTF8Encoding($false)))
Write-Host "Built windows-server.zip; SHA-256: $hash"
