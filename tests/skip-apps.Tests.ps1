. (Join-Path (Split-Path -Parent $PSScriptRoot) 'install-software.ps1')

Describe 'App skip configuration is data, never executable code' {
    BeforeEach {
        $script:skipTestPath = Join-Path $TestDrive 'skip-apps.conf'
        $script:localSkipTestPath = Join-Path $TestDrive 'machine-skip-apps.conf'
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq 'C:\Support\skip-apps.conf' }
    }

    It 'skips nothing when every app is commented out' {
        @('# Google.Chrome', '', '# 9NKSQGP7F2NH # WhatsApp') | Set-Content -LiteralPath $script:skipTestPath -Encoding UTF8
        @(Get-JindaSkippedApps -Path $script:skipTestPath).Count | Should Be 0
    }

    It 'accepts uncommented IDs, whitespace, inline comments and case-insensitive duplicates' {
        @('  Google.Chrome # skip Chrome', 'google.chrome', ' Yodeck.Player ', '9NKSQGP7F2NH # WhatsApp', '# OpenAI.ChatGPT') |
            Set-Content -LiteralPath $script:skipTestPath -Encoding UTF8
        $ids = @(Get-JindaSkippedApps -Path $script:skipTestPath)
        $ids.Count | Should Be 3
        ($ids -join ',') | Should Be 'Google.Chrome,Yodeck.Player,9NKSQGP7F2NH'
    }

    It 'accepts already-disabled apps without enabling them' {
        @('Discord.Discord', 'Microsoft.Teams') | Set-Content -LiteralPath $script:skipTestPath -Encoding UTF8
        @(Get-JindaSkippedApps -Path $script:skipTestPath).Count | Should Be 2
        $ids = @(Get-JindaSoftwarePackages | ForEach-Object { $_.Id })
        ($ids -contains 'Discord.Discord') | Should Be $false
        ($ids -contains 'Microsoft.Teams') | Should Be $false
    }

    It 'reports an unknown ID with its line number rather than silently installing it' {
        @('# heading', 'Google.Chromee') | Set-Content -LiteralPath $script:skipTestPath -Encoding UTF8
        { Get-JindaSkippedApps -Path $script:skipTestPath } | Should Throw "Unknown app ID 'Google.Chromee'"
        { Get-JindaSkippedApps -Path $script:skipTestPath } | Should Throw 'line 2'
    }

    It 'rejects executable expressions as invalid IDs without evaluating them' {
        '$global:JindaConfigExecuted = $true' | Set-Content -LiteralPath $script:skipTestPath -Encoding UTF8
        $global:JindaConfigExecuted = $false
        try {
            { Get-JindaSkippedApps -Path $script:skipTestPath } | Should Throw 'Unknown app ID'
            $global:JindaConfigExecuted | Should Be $false
        } finally { Remove-Variable JindaConfigExecuted -Scope Global }
    }

    It 'fails closed when the configuration is missing' {
        { Get-JindaSkippedApps -Path (Join-Path $TestDrive 'missing.conf') } | Should Throw 'App skip configuration is missing'
    }

    It 'keeps package skips when no machine-specific file exists' {
        'Google.Chrome' | Set-Content -LiteralPath $script:skipTestPath -Encoding UTF8
        $ids = @(Get-JindaSkippedApps -Path $script:skipTestPath -LocalPath (Join-Path $TestDrive 'absent-local.conf'))
        ($ids -join ',') | Should Be 'Google.Chrome'
    }

    It 'combines package and machine-specific skips without duplicates' {
        'Google.Chrome' | Set-Content -LiteralPath $script:skipTestPath -Encoding UTF8
        @('TeamViewer.TeamViewer', 'google.chrome') | Set-Content -LiteralPath $script:localSkipTestPath -Encoding UTF8
        $ids = @(Get-JindaSkippedApps -Path $script:skipTestPath -LocalPath $script:localSkipTestPath)
        ($ids -join ',') | Should Be 'Google.Chrome,TeamViewer.TeamViewer'
    }

    It 'reports the machine-specific filename and line for a typo' {
        '' | Set-Content -LiteralPath $script:skipTestPath -Encoding UTF8
        @('# heading', 'TeamViewer.Typo') | Set-Content -LiteralPath $script:localSkipTestPath -Encoding UTF8
        { Get-JindaSkippedApps -Path $script:skipTestPath -LocalPath $script:localSkipTestPath } |
            Should Throw 'machine-skip-apps.conf at line 2'
    }

    It 'keeps an example line for every app, including the disabled apps' {
        $content = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'skip-apps.conf') -Raw
        $expected = @(Get-JindaSoftwarePackages | ForEach-Object { $_.Id }) + @('Discord.Discord', 'Microsoft.Teams')
        foreach ($id in $expected) {
            $pattern = '(?m)^[ \t]*(?:#[ \t]*)?' + [regex]::Escape($id) + '[ \t]+#'
            [regex]::Matches($content, $pattern).Count | Should Be 1
        }
    }

    It 'reads the file beside the script even when launched from a different directory' {
        $script:expectedSkipFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'skip-apps.conf'
        Mock Get-Content { 'Google.Chrome' } -ParameterFilter { $LiteralPath -eq $script:expectedSkipFile }
        Push-Location $TestDrive
        try { @(Get-JindaSkippedApps)[0] | Should Be 'Google.Chrome' }
        finally { Pop-Location }
        Assert-MockCalled Get-Content -Times 1 -Exactly -Scope It -ParameterFilter { $LiteralPath -eq $script:expectedSkipFile }
    }
}
