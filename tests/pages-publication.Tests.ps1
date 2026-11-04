. (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/Test-PagesPublication.ps1')

Describe 'Pages publication must prove deployment and actual downloads' {
    BeforeEach {
        $script:publicationSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        $script:publicationStatus = 'completed'
        $script:publicationConclusion = 'success'
        $script:publicationHead = $script:publicationSha
        $script:publicationMismatch = $false
        $script:publicationDownloadError = $false
        $script:publicationMissingFile = $false
        Mock Invoke-RestMethod {
            if ($Uri -like '*/git/trees/*') {
                $paths = @('index.html', 'init.ps1', 'install-software.ps1', 'set-windows-english.ps1')
                if ($script:publicationMissingFile) { $paths = $paths[0..2] }
                return @{ truncated = $false; tree = @($paths | ForEach-Object { @{path=$_;type='blob';sha='expected'} }) }
            }
            return @{workflow_runs=@(@{id=42;head_sha=$script:publicationHead;name='pages build and deployment';status=$script:publicationStatus;conclusion=$script:publicationConclusion;html_url='https://github.com/acurvers/jinda-operations/actions/runs/42'})}
        }
        Mock Get-JindaPublicBlobSha {
            if ($script:publicationDownloadError) { throw 'HTTP 404' }
            if ($script:publicationMismatch -and $Uri -like '*/init.ps1') { return 'stale' }
            return 'expected'
        }
        Mock Start-Sleep {}
    }
    It 'confirms exactly four public files for the requested commit' {
        $result = Test-JindaPagesPublication -CommitSha $script:publicationSha
        $result.Verified | Should Be $true
        $result.Files | Should Be 4
        $result.Commit | Should Be $script:publicationSha
        Assert-MockCalled Get-JindaPublicBlobSha -Times 4 -Exactly -Scope It
        Assert-MockCalled Get-JindaPublicBlobSha -Times 0 -Exactly -Scope It -ParameterFilter { $Uri -match '\?' }
    }
    It 'rejects cancellation even if downloads might still work' {
        $script:publicationConclusion = 'cancelled'
        { Test-JindaPagesPublication -CommitSha $script:publicationSha } | Should Throw 'cancelled'
        Assert-MockCalled Get-JindaPublicBlobSha -Times 0 -Exactly -Scope It
    }
    It 'rejects a failed workflow' {
        $script:publicationConclusion = 'failure'
        { Test-JindaPagesPublication -CommitSha $script:publicationSha } | Should Throw 'failure'
    }
    It 'does not accept a successful workflow for another commit' {
        $script:publicationHead = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        { Test-JindaPagesPublication -CommitSha $script:publicationSha -TimeoutSeconds 1 } | Should Throw 'niet bevestigd'
        Assert-MockCalled Get-JindaPublicBlobSha -Times 0 -Exactly -Scope It
    }
    It 'does not accept an unfinished workflow' {
        $script:publicationStatus = 'queued'
        { Test-JindaPagesPublication -CommitSha $script:publicationSha -TimeoutSeconds 1 } | Should Throw 'niet bevestigd'
    }
    It 'rejects a successful deployment serving an older init script' {
        $script:publicationMismatch = $true
        { Test-JindaPagesPublication -CommitSha $script:publicationSha -TimeoutSeconds 1 } | Should Throw 'init.ps1 wijkt nog af'
    }
    It 'rejects unreachable public files' {
        $script:publicationDownloadError = $true
        { Test-JindaPagesPublication -CommitSha $script:publicationSha -TimeoutSeconds 1 } | Should Throw 'niet bereikbaar'
    }
    It 'rejects a missing required file in the target commit' {
        $script:publicationMissingFile = $true
        { Test-JindaPagesPublication -CommitSha $script:publicationSha } | Should Throw 'ontbreekt'
    }
}

Describe 'Git blob hashes preserve exact bytes' {
    It 'matches the known Git empty-blob hash' {
        Get-JindaGitBlobSha -Bytes ([byte[]]@()) | Should Be 'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391'
    }
    It 'matches the known Git hello-newline hash' {
        Get-JindaGitBlobSha -Bytes ([Text.Encoding]::UTF8.GetBytes("hello`n")) | Should Be 'ce013625030ba8dba906f756967f9e9ca394464a'
    }
}
