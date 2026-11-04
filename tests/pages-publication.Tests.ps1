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
                if ($script:publicationMissingFile) { $paths = @() }
                return @{ truncated = $false; tree = @($paths | ForEach-Object { @{path=$_;type='blob';sha='expected'} }) }
            }
            return @{workflow_runs=@(@{id=42;head_sha=$script:publicationHead;name='pages build and deployment';status=$script:publicationStatus;conclusion=$script:publicationConclusion;html_url='https://github.com/acurvers/jinda-operations/actions/runs/42'})}
        }
        Mock Get-JindaPublicBlobSha {
            if ($script:publicationDownloadError) { throw 'HTTP 404' }
            if ($script:publicationMismatch) { return 'stale' }
            return 'expected'
        }
        Mock Start-Sleep {}
    }
    It 'confirms the Pages web page for the requested commit' {
        $result = Test-JindaPagesPublication -CommitSha $script:publicationSha
        $result.Verified | Should Be $true
        $result.Files | Should Be 1
        $result.Commit | Should Be $script:publicationSha
        Assert-MockCalled Get-JindaPublicBlobSha -Times 1 -Exactly -Scope It
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
    It 'rejects a successful deployment serving an older web page' {
        $script:publicationMismatch = $true
        { Test-JindaPagesPublication -CommitSha $script:publicationSha -TimeoutSeconds 1 } | Should Throw 'index.html wijkt nog af'
    }
    It 'rejects unreachable public files' {
        $script:publicationDownloadError = $true
        { Test-JindaPagesPublication -CommitSha $script:publicationSha -TimeoutSeconds 1 } | Should Throw 'niet bereikbaar'
    }
    It 'rejects a missing required file in the target commit' {
        $script:publicationMissingFile = $true
        { Test-JindaPagesPublication -CommitSha $script:publicationSha } | Should Throw 'ontbreekt'
    }

    It 'verifies all three direct scripts even when Pages is queued' {
        $script:publicationStatus = 'queued'
        $result = Test-JindaPagesPublication -CommitSha $script:publicationSha -ScriptsOnly
        $result.Verified | Should Be $true
        $result.Files | Should Be 3
        $result.Source | Should Be 'GitHub'
        Assert-MockCalled Get-JindaPublicBlobSha -Times 3 -Exactly -Scope It -ParameterFilter {
            $Uri -like 'https://raw.githubusercontent.com/acurvers/jinda-operations/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/*.ps1'
        }
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It -ParameterFilter { $Uri -like '*/actions/*' }
        Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
    }

    It 'rejects mismatched direct script bytes without waiting for Pages' {
        $script:publicationMismatch = $true
        { Test-JindaPagesPublication -CommitSha $script:publicationSha -ScriptsOnly } | Should Throw 'wijkt af'
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It -ParameterFilter { $Uri -like '*/actions/*' }
    }

    It 'rejects an unavailable direct script' {
        $script:publicationDownloadError = $true
        { Test-JindaPagesPublication -CommitSha $script:publicationSha -ScriptsOnly } | Should Throw 'HTTP 404'
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
