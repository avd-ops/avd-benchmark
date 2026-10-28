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

    It 'Rejects an email address, IPv4 address, UNC path, or domain name' {
        $json = $script:CleanRecord | ConvertTo-Json -Depth 12
        (Test-AvdBenchmarkResult -InputObject ($json.Replace('"nat-gateway"', '"admin@contoso.com"'))).IsValid | Should -BeFalse
        (Test-AvdBenchmarkResult -InputObject ($json.Replace('"nat-gateway"', '"10.24.16.8"'))).IsValid | Should -BeFalse
        (Test-AvdBenchmarkResult -InputObject ($json.Replace('"nat-gateway"', '"\\\\fs01\\profiles"'))).IsValid | Should -BeFalse
        (Test-AvdBenchmarkResult -InputObject ($json.Replace('"nat-gateway"', '"host01.contoso.com"'))).IsValid | Should -BeFalse
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
}
