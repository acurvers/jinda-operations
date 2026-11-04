. (Join-Path (Split-Path -Parent $PSScriptRoot) 'set-windows-english.ps1')

Describe 'Merging managed Jinda browser bookmarks without losing existing entries' {
    It 'creates the Jinda folder and exact Operations link from an empty policy' {
        $result = Add-JindaManagedBookmarkJson -Json $null | ConvertFrom-Json
        $result.Count | Should Be 2
        $result[0].toplevel_name | Should Be 'Jinda'
        $result[1].name | Should Be 'Jinda Operations'
        $result[1].url | Should Be 'https://acurvers.github.io/jinda-operations/'
    }

    It 'is idempotent and returns the original JSON if the link already exists' {
        $first = Add-JindaManagedBookmarkJson -Json '[]'
        Add-JindaManagedBookmarkJson -Json $first | Should Be $first
    }

    It 'preserves an existing link name and nested location, including without trailing slash' {
        $original = '[{"toplevel_name":"Company"},{"name":"Other","children":[{"name":"Existing name","url":"https://acurvers.github.io/jinda-operations"}]}]'
        Add-JindaManagedBookmarkJson -Json $original | Should Be $original
    }

    It 'keeps existing managed folder names and all nested bookmarks' {
        $original = '[{"toplevel_name":"Company"},{"name":"Office","children":[{"name":"Calendar","url":"https://example.com/calendar"}]}]'
        $result = Add-JindaManagedBookmarkJson -Json $original | ConvertFrom-Json
        $result.Count | Should Be 3
        $result[0].toplevel_name | Should Be 'Company'
        $result[1].children[0].url | Should Be 'https://example.com/calendar'
        $result[2].name | Should Be 'Jinda'
        $result[2].children[0].name | Should Be 'Jinda Operations'
    }

    It 'adds to an existing Jinda subfolder instead of creating a second one' {
        $original = '[{"name":"Jinda","children":[{"name":"Existing","url":"https://example.com"}]}]'
        $result = @(Add-JindaManagedBookmarkJson -Json $original | ConvertFrom-Json)
        $result.Count | Should Be 1
        $result[0].children.Count | Should Be 2
        $result[0].children[0].name | Should Be 'Existing'
    }

    It 'adds directly to an existing Jinda top-level folder' {
        $original = '[{"toplevel_name":"Jinda"},{"name":"Existing","url":"https://example.com"}]'
        $result = Add-JindaManagedBookmarkJson -Json $original | ConvertFrom-Json
        $result.Count | Should Be 3
        $result[2].name | Should Be 'Jinda Operations'
    }

    It 'refuses malformed JSON, non-array policies and invalid bookmark entries' {
        foreach ($invalid in @('[invalid', '{}', '[null]', '[12]', '[{"name":"Missing URL"}]', '[{"name":"Broken folder","children":{}}]', '[{"toplevel_name":"One"},{"toplevel_name":"Two"}]')) {
            { Add-JindaManagedBookmarkJson -Json $invalid } | Should Throw 'existing bookmark policy'
        }
    }
}

Describe 'Writing browser policies (all registry writes are mocked)' {
    BeforeEach {
        $script:bookmarkRegistry = @{
            'HKLM:\SOFTWARE\Policies\Google\Chrome' = @{}
            'HKLM:\SOFTWARE\Policies\Microsoft\Edge' = @{}
        }
        Mock Test-JindaAdministrator { $true }
        Mock Test-Path { $script:bookmarkRegistry.ContainsKey(@($LiteralPath)[0]) }
        Mock Get-ItemProperty { [pscustomobject]$script:bookmarkRegistry[@($LiteralPath)[0]] }
        Mock New-Item { }
        Mock New-ItemProperty { $script:bookmarkRegistry[@($LiteralPath)[0]][$Name] = $Value }
    }

    It 'writes and verifies the Chrome and Edge machine policies as strings' {
        Set-JindaBrowserBookmarks
        Assert-MockCalled New-ItemProperty -Times 1 -Exactly -Scope It -ParameterFilter {
            $LiteralPath -eq 'HKLM:\SOFTWARE\Policies\Google\Chrome' -and $Name -eq 'ManagedBookmarks' -and $PropertyType -eq 'String'
        }
        Assert-MockCalled New-ItemProperty -Times 1 -Exactly -Scope It -ParameterFilter {
            $LiteralPath -eq 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -and $Name -eq 'ManagedFavorites' -and $PropertyType -eq 'String'
        }
        ($script:bookmarkRegistry['HKLM:\SOFTWARE\Policies\Microsoft\Edge'].ManagedFavorites | ConvertFrom-Json)[1].name | Should Be 'Jinda Operations'
    }

    It 'does not write anything again on a second run' {
        Set-JindaBrowserBookmarks
        Set-JindaBrowserBookmarks
        Assert-MockCalled New-ItemProperty -Times 2 -Exactly -Scope It
        Assert-MockCalled New-Item -Times 2 -Exactly -Scope It
    }

    It 'validates both policies before writing if Edge has malformed data' {
        $script:bookmarkRegistry['HKLM:\SOFTWARE\Policies\Microsoft\Edge'].ManagedFavorites = '[broken'
        { Set-JindaBrowserBookmarks } | Should Throw 'existing bookmark policy'
        Assert-MockCalled New-ItemProperty -Times 0 -Exactly -Scope It
        Assert-MockCalled New-Item -Times 0 -Exactly -Scope It
    }

    It 'does not modify settings or require elevation in WhatIf' {
        Mock Test-JindaAdministrator { $false }
        Set-JindaBrowserBookmarks -WhatIf
        Assert-MockCalled New-ItemProperty -Times 0 -Exactly -Scope It
        Assert-MockCalled New-Item -Times 0 -Exactly -Scope It
    }

    It 'rejects a non-administrator before writing' {
        Mock Test-JindaAdministrator { $false }
        { Set-JindaBrowserBookmarks } | Should Throw 'administrator'
        Assert-MockCalled New-ItemProperty -Times 0 -Exactly -Scope It
    }

    It 'does not overwrite an expanded registry policy' {
        Mock Test-Path { $true }
        { Set-JindaBrowserBookmarks } | Should Throw 'registry subkeys'
        Assert-MockCalled New-ItemProperty -Times 0 -Exactly -Scope It
    }

    It 'rejects a non-string existing policy' {
        $script:bookmarkRegistry['HKLM:\SOFTWARE\Policies\Google\Chrome'].ManagedBookmarks = 42
        { Set-JindaBrowserBookmarks } | Should Throw 'not a JSON string'
        Assert-MockCalled New-ItemProperty -Times 0 -Exactly -Scope It
    }

    It 'detects a concurrent policy change before overwriting it' {
        $script:policyReads = 0
        Mock Get-ItemProperty {
            $script:policyReads++
            if ($script:policyReads -gt 2) { return [pscustomobject]@{ ManagedBookmarks = '[]' } }
            return [pscustomobject]@{}
        }
        { Set-JindaBrowserBookmarks } | Should Throw 'changed during setup'
        Assert-MockCalled New-ItemProperty -Times 0 -Exactly -Scope It
    }

    It 'reports a failed read-back rather than claiming configuration succeeded' {
        Mock New-ItemProperty { }
        { Set-JindaBrowserBookmarks } | Should Throw 'could not verify'
        Assert-MockCalled New-ItemProperty -Times 1 -Exactly -Scope It
    }
}
