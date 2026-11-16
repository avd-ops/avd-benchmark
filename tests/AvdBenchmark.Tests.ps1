#requires -Version 7.2
# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft. MIT.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ModulePath = Join-Path $script:RepoRoot 'scripts' 'AvdBenchmark.psm1'
    $script:RunnerPath = Join-Path $script:RepoRoot 'Invoke-AvdBenchmark.ps1'
    Import-Module $script:ModulePath -Force
}

Describe 'AvdBenchmark.psm1 - Percentile Math & Sample Banding' {
    It 'Computes exact p50, p90, p95, and p99 values over numeric samples' {
        $samples = @(10, 20, 30, 40, 50, 60, 70, 80, 90, 100)
        Get-AvdPercentile -Samples $samples -Percentile 50 -Digits 1 | Should -Be 55.0
        Get-AvdPercentile -Samples $samples -Percentile 90 -Digits 1 | Should -Be 91.0
        Get-AvdPercentile -Samples $samples -Percentile 95 -Digits 1 | Should -Be 95.5
        Get-AvdPercentile -Samples $samples -Percentile 0 -Digits 1  | Should -Be 10.0
        Get-AvdPercentile -Samples $samples -Percentile 100 -Digits 1 | Should -Be 100.0
    }

    It 'Handles single-element sample arrays and rejects empty arrays' {
        Get-AvdPercentile -Samples @(42.34) -Percentile 95 -Digits 1 | Should -Be 42.3
        { Get-AvdPercentile -Samples @() -Percentile 50 } | Should -Throw '*empty*'
    }

    It 'Maps exact host and session counts to privacy-preserving C25 bands' {
        ConvertTo-AvdSampleBand -Count 1   | Should -Be '1-2'
        ConvertTo-AvdSampleBand -Count 2   | Should -Be '1-2'
        ConvertTo-AvdSampleBand -Count 5   | Should -Be '3-9'
        ConvertTo-AvdSampleBand -Count 16  | Should -Be '10-25'
        ConvertTo-AvdSampleBand -Count 64  | Should -Be '26-100'
        ConvertTo-AvdSampleBand -Count 250 | Should -Be '100+'
        { ConvertTo-AvdSampleBand -Count 0 } | Should -Throw '*at least 1*'
    }
}

Describe 'AvdBenchmark.psm1 - Sandbox Batch Spend Approval Gate' {
    It 'Allows OfflineFixture and read-only ExistingHostPool without go batch approval' {
        $r1 = Test-AvdSandboxApproval -Mode OfflineFixture
        $r1.Approved | Should -BeTrue
        $r1.RequiresGo | Should -BeFalse

        $r2 = Test-AvdSandboxApproval -Mode ExistingHostPool
        $r2.Approved | Should -BeTrue
        $r2.RequiresGo | Should -BeFalse
    }

    It 'Rejects SandboxBatch or -StartStoppedHosts without exact go batch <id> $<total> approval' {
        (Test-AvdSandboxApproval -Mode SandboxBatch).Approved | Should -BeFalse
        (Test-AvdSandboxApproval -Mode SandboxBatch -SandboxBatchApproval 'go').Approved | Should -BeFalse
        (Test-AvdSandboxApproval -Mode SandboxBatch -SandboxBatchApproval 'go batch bm-01 $0').Approved | Should -BeFalse
        (Test-AvdSandboxApproval -Mode ExistingHostPool -StartStoppedHosts).Approved | Should -BeFalse
    }

    It 'Accepts valid go batch <id> $<total> approval string' {
        $ok = Test-AvdSandboxApproval -Mode SandboxBatch -SandboxBatchApproval 'go batch bm-storage-01 $14.50'
        $ok.Approved | Should -BeTrue
        $ok.BatchId | Should -Be 'bm-storage-01'
        $ok.BudgetUsd | Should -Be 14.5
    }
}

Describe 'AvdBenchmark.psm1 - Pinned diskspd SHA-256 Verification' {
    It 'Verifies an empty test stub against the pinned SHA-256 allowlist and rejects tampered binaries' {
        $tmpFile = Join-Path ([IO.Path]::GetTempPath()) "diskspd-stub-$([Guid]::NewGuid().ToString('N')).bin"
        try {
            [IO.File]::WriteAllBytes($tmpFile, [byte[]]@())
            $verified = Test-AvdDiskSpdBinary -BinaryPath $tmpFile
            $verified.Verified | Should -BeTrue

            [IO.File]::WriteAllBytes($tmpFile, [Text.Encoding]::UTF8.GetBytes('untrusted-binary'))
            $tampered = Test-AvdDiskSpdBinary -BinaryPath $tmpFile
            $tampered.Verified | Should -BeFalse
        } finally {
            if (Test-Path -LiteralPath $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force }
        }
    }
}

Describe 'AvdBenchmark.psm1 - Five Tier 1 Profiles & Contract C25 Validation' {
    It 'Emits schema-valid C25 results for all 5 Tier 1 profiles (<Profile>)' -ForEach @(
        @{ Profile = 'storage-fslogix-io' }
        @{ Profile = 'host-logon-storm' }
        @{ Profile = 'multisession-density' }
        @{ Profile = 'control-plane-autoscale' }
        @{ Profile = 'bcdr-profile-recovery' }
    ) {
        $res = Invoke-AvdBenchmarkProfile -ProfileId $Profile -VmSku 'Standard_E4s_v5' -Mode OfflineFixture
        $res.schema | Should -Be 'avd-benchmark-result/v1'
        $res.profile.id | Should -Be $Profile
        $check = Test-AvdBenchmarkResult -InputObject $res
        $check.IsValid | Should -BeTrue -Because ($check.Errors -join '; ')
    }

    It 'Writes a validated C25 JSON file via Invoke-AvdBenchmark.ps1 and emits AVDBM-STATE line' {
        $outDir = Join-Path ([IO.Path]::GetTempPath()) "avd-bm-test-$([Guid]::NewGuid().ToString('N'))"
        try {
            $res = & $script:RunnerPath -ProfileId 'multisession-density' -WorkloadClass 'medium' -VmSku 'Standard_E4s_v5' -Mode 'OfflineFixture' -OutputPath $outDir -PassThru
            $expectedFile = Join-Path $outDir "$($res.id).json"
            Test-Path -LiteralPath $expectedFile | Should -BeTrue
            $raw = Get-Content -LiteralPath $expectedFile -Raw
            (Test-AvdBenchmarkResult -InputObject $raw).IsValid | Should -BeTrue
        } finally {
            if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
        }
    }
}

Describe 'AvdBenchmark.psm1 - Fail-Closed Leak & Redaction Guard' {
    BeforeEach {
        $script:CleanRecord = Invoke-AvdBenchmarkProfile -ProfileId 'multisession-density' -VmSku 'Standard_E4s_v5' -Mode OfflineFixture
    }

    It 'Rejects a GUID anywhere in the C25 payload' {
        $dirty = $script:CleanRecord | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12 -AsHashtable
        $dirty['id'] = 'bm-20261028-123e4567-e89b-12d3-a456-426614174000'
        $check = Test-AvdBenchmarkResult -InputObject $dirty
        $check.IsValid | Should -BeFalse
        ($check.Errors -join ' ') | Should -Match 'GUID'
    }

    It 'Rejects an email address, IPv4/IPv6 address, UNC path, or domain name' {
        $json = $script:CleanRecord | ConvertTo-Json -Depth 12
        (Test-AvdBenchmarkResult -InputObject ($json.Replace('"nat-gateway"', '"admin@contoso.com"'))).IsValid | Should -BeFalse
        (Test-AvdBenchmarkResult -InputObject ($json.Replace('"nat-gateway"', '"10.24.16.8"'))).IsValid | Should -BeFalse
        (Test-AvdBenchmarkResult -InputObject ($json.Replace('"nat-gateway"', '"2001:db8::1"'))).IsValid | Should -BeFalse
        (Test-AvdBenchmarkResult -InputObject ($json.Replace('"nat-gateway"', '"\\\\fs01\\profiles"'))).IsValid | Should -BeFalse
        (Test-AvdBenchmarkResult -InputObject ($json.Replace('"nat-gateway"', '"host01.contoso.com"'))).IsValid | Should -BeFalse
        (Test-AvdBenchmarkResult -InputObject ($json.Replace('"nat-gateway"', '"host01.acme.com"'))).IsValid | Should -BeFalse
    }

    It 'Rejects unknown top-level properties via the pinned C25 JSON schema' {
        $dirty = $script:CleanRecord | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12 -AsHashtable
        $dirty['unexpectedField'] = 'should-fail'
        $check = Test-AvdBenchmarkResult -InputObject $dirty
        $check.IsValid | Should -BeFalse
        ($check.Errors -join ' ') | Should -Match 'Schema validation failed'
    }

    It 'Keeps contracts/benchmark-result.schema.json byte-identical to PINS.json SHA-256' {
        $pinsPath = Join-Path $script:RepoRoot 'PINS.json'
        $pins = Get-Content -LiteralPath $pinsPath -Raw | ConvertFrom-Json -AsHashtable
        $schemaRel = $pins['artifacts']['schema']
        $expectedHash = $pins['hashes'][$schemaRel]
        $actualHash = (Get-FileHash -LiteralPath (Join-Path $script:RepoRoot $schemaRel) -Algorithm SHA256).Hash.ToLowerInvariant()
        $actualHash | Should -Be $expectedHash
    }

    It 'Rejects unbanded sample counts and raw time-series arrays in metrics' {
        $dirty = $script:CleanRecord | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12 -AsHashtable
        $dirty['environment']['sampleHostsBand'] = '4'
        $dirty['metrics']['rawSeries'] = @(10, 20, 30)
        $check = Test-AvdBenchmarkResult -InputObject $dirty
        $check.IsValid | Should -BeFalse
        ($check.Errors -join ' ') | Should -Match 'sampleHostsBand'
        ($check.Errors -join ' ') | Should -Match 'raw array'
    }

    It 'Validates every empirical C25 record in site/portal/corpus.json cleanly' {
        $corpusPath = Join-Path $script:RepoRoot 'site' 'portal' 'corpus.json'
        $corpus = Get-Content -LiteralPath $corpusPath -Raw | ConvertFrom-Json -Depth 12 -AsHashtable
        $corpus['records'].Count | Should -BeGreaterOrEqual 10
        foreach ($rec in $corpus['records']) {
            $check = Test-AvdBenchmarkResult -InputObject $rec
            $check.IsValid | Should -BeTrue -Because ($check.Errors -join '; ')
            $rec['source'] | Should -BeIn @('sandbox', 'lab')
        }
    }
}

Describe 'ConvertFrom-EucScore (Experimental BYO Adapter)' {
    BeforeAll {
        $script:EucDir = Join-Path $TestDrive 'euc-synth'
        New-Item -ItemType Directory -Path $script:EucDir -Force | Out-Null
        $script:SynthIni = Join-Path $script:EucDir 'Telemetry.ini'
        @(
            '# Synthetic Telemetry.ini fixture for unit tests',
            '\Processor(_Total)\% Processor Time',
            '\System\Processor Queue Length',
            '\Memory\Available MBytes',
            '\User Input Delay per Session(Max)\Max Input Delay'
        ) | Set-Content -LiteralPath $script:SynthIni -Encoding ascii

        $script:SynthCsv = Join-Path $script:EucDir 'synthetic-telemetry.csv'
        @(
            '"\Processor(_Total)\% Processor Time","\System\Processor Queue Length","\Memory\Available MBytes","\User Input Delay per Session(Max)\Max Input Delay"',
            '42.0,2,18400,28',
            '48.0,4,17900,35',
            '55.0,6,17200,44'
        ) | Set-Content -LiteralPath $script:SynthCsv -Encoding ascii
    }

    It 'Requires -Experimental switch' {
        { ConvertFrom-EucScore -EucScoreCsvPath $script:SynthCsv } | Should -Throw '*Experimental*'
    }

    It 'Normalizes synthetic telemetry CSV + Telemetry.ini into a valid C25 v1 result with extensions.generator' {
        $res = ConvertFrom-EucScore -EucScoreCsvPath $script:SynthCsv -Experimental -Persona 'knowledge-worker' -VmSku 'Standard_E4s_v5'
        $res['schema'] | Should -Be 'avd-benchmark-result/v1'
        $res['source'] | Should -Be 'lab'
        $res['extensions']['generator']['kind'] | Should -Be 'euc-score-byo'
        $res['extensions']['generator']['persona'] | Should -Be 'knowledge-worker'
        $res['extensions']['generator']['licenseSelfDeclared'] | Should -Be 'community-public-results'
        $res['extensions']['generator']['exportSha256'] | Should -Match '^[0-9a-f]{64}$'
        $res['verdict']['experienceGate'] | Should -Be 'pass'
        $res['verdict']['claims'][0]['verdict'] | Should -Be 'extends'
        (Test-AvdBenchmarkResult -InputObject $res).IsValid | Should -BeTrue
    }

    It 'Fails closed on directories, .ref files, inventory CSVs, and unrenamed Telemetry_<Computer>_<User> filenames without echoing paths' {
        { ConvertFrom-EucScore -EucScoreCsvPath $script:EucDir -Experimental } | Should -Throw '*not a directory*'

        $refFile = Join-Path $script:EucDir 'run.ref'
        Set-Content -LiteralPath $refFile -Value 'app-launch' -Encoding ascii
        { ConvertFrom-EucScore -EucScoreCsvPath $refFile -Experimental } | Should -Throw '*.csv*'

        $piiCsv = Join-Path $script:EucDir 'Telemetry_AVDHOST01_jdoe_2026-11-16-12-00-00.csv'
        Copy-Item -LiteralPath $script:SynthCsv -Destination $piiCsv -Force
        $errMsg = ''
        try {
            ConvertFrom-EucScore -EucScoreCsvPath $piiCsv -Experimental
        } catch {
            $errMsg = $_.Exception.Message
        }
        $errMsg | Should -Match 'unrenamed'
        $errMsg | Should -Not -Match 'AVDHOST01'
        $errMsg | Should -Not -Match 'jdoe'

        $invCsv = Join-Path $script:EucDir 'User Sessions.csv'
        Copy-Item -LiteralPath $script:SynthCsv -Destination $invCsv -Force
        { ConvertFrom-EucScore -EucScoreCsvPath $invCsv -Experimental } | Should -Throw '*inventory*'
    }

    It 'Refuses unknown PerfMon counters in Telemetry.ini and enforces estate consent + session band >= 10-25' {
        $badDir = Join-Path $TestDrive 'euc-bad-ini'
        New-Item -ItemType Directory -Path $badDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $badDir 'Telemetry.ini') -Value '\Process(SecretApp)\Private Bytes' -Encoding ascii
        $badCsv = Join-Path $badDir 'telemetry.csv'
        Copy-Item -LiteralPath $script:SynthCsv -Destination $badCsv -Force
        { ConvertFrom-EucScore -EucScoreCsvPath $badCsv -Experimental } | Should -Throw '*unrecognized*'

        { ConvertFrom-EucScore -EucScoreCsvPath $script:SynthCsv -Experimental -Source 'estate' } | Should -Throw '*Consent*'
        { ConvertFrom-EucScore -EucScoreCsvPath $script:SynthCsv -Experimental -Source 'estate' -Consent -SampleSessionsBand '1-2' } | Should -Throw '*10-25*'
    }
}
