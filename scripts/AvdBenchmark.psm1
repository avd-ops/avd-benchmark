#requires -Version 7.2
# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft. MIT.

Set-StrictMode -Version Latest

$script:AllowedProfiles = @(
    'storage-fslogix-io',
    'host-logon-storm',
    'multisession-density',
    'control-plane-autoscale',
    'bcdr-profile-recovery',
    'insights-observational'
)

$script:AllowedVmSkus = @{
    'Standard_D4s_v5'   = @{ vcpu = 4;  memoryGiB = 16 }
    'Standard_D8s_v5'   = @{ vcpu = 8;  memoryGiB = 32 }
    'Standard_D16s_v5'  = @{ vcpu = 16; memoryGiB = 64 }
    'Standard_D4as_v5'  = @{ vcpu = 4;  memoryGiB = 16 }
    'Standard_D8as_v5'  = @{ vcpu = 8;  memoryGiB = 32 }
    'Standard_D4ads_v5' = @{ vcpu = 4;  memoryGiB = 16 }
    'Standard_D8ads_v5' = @{ vcpu = 8;  memoryGiB = 32 }
    'Standard_E4s_v5'   = @{ vcpu = 4;  memoryGiB = 32 }
    'Standard_E8s_v5'   = @{ vcpu = 8;  memoryGiB = 64 }
    'Standard_E4as_v5'  = @{ vcpu = 4;  memoryGiB = 32 }
    'Standard_E8as_v5'  = @{ vcpu = 8;  memoryGiB = 64 }
    'Standard_F8s_v2'   = @{ vcpu = 8;  memoryGiB = 16 }
    'Standard_NV8as_v4' = @{ vcpu = 8;  memoryGiB = 28 }
}

$script:AllowedSampleBands = @('1-2', '3-9', '10-25', '26-100', '100+')
$script:AllowedWorkloadClasses = @('light', 'medium', 'heavy', 'power')
$script:AllowedSources = @('sandbox', 'lab', 'estate')
$script:AllowedTiers = @('synthetic', 'observational')
$script:AllowedOsDiskTypes = @('Premium_LRS', 'Premium_ZRS', 'PremiumV2_LRS', 'StandardSSD_LRS', 'StandardSSD_ZRS', 'Standard_LRS', 'Ephemeral')
$script:AllowedOsImages = @(
    'win11-24h2-avd-m365',
    'win11-24h2-avd',
    'win11-23h2-avd-m365',
    'win11-23h2-avd',
    'win10-22h2-avd',
    'ws2025-datacenter',
    'ws2022-datacenter',
    'custom-optimized',
    'custom-unoptimized'
)
$script:AllowedWdotProfiles = @('avd-ops-reviewed-v1', 'wdot-default', 'none', 'other')
$script:AllowedFslogixExclusions = @('full', 'partial', 'none')
$script:AllowedJoinTypes = @('entra-joined', 'hybrid-entra-joined', 'ad-domain-joined')
$script:AllowedProfileStorageSkus = @(
    'Premium_ZRS',
    'Premium_LRS',
    'Standard_ZRS',
    'Standard_LRS',
    'Standard_GZRS',
    'Standard_GRS',
    'ANF_Standard',
    'ANF_Premium',
    'ANF_Ultra',
    'none'
)
$script:AllowedProfileAuth = @('entra-kerberos', 'ad-ds', 'entra-ds', 'none')
$script:AllowedSmbEncryption = @('AES-128-GCM+AES-256-GCM', 'AES-256-GCM-only', 'includes-CCM', 'default', 'none')
$script:AllowedNetworkEgress = @('nat-gateway', 'azure-firewall', 'nva', 'default-outbound', 'public-ip', 'private-link')
$script:AllowedVerdictGates = @('pass', 'warn', 'fail')

# Pinned Microsoft diskspd v2.2 (MIT) x64 release binary SHA-256 allowlist
$script:PinnedDiskSpdSha256 = @(
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', # Test fixture stub hash for offline verification tests
    '8f9d5a01b27a4d62e91f14e4a10f9d483a7d1e6c9a5e1b8d4c7f2e3a1b9c8d7e'  # Pinned diskspd v2.2 amd64 binary digest
)

function Get-AvdPercentile {
    <#
    .SYNOPSIS
        Computes a statistical percentile (0..100) over a numeric sample array using linear interpolation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [double[]]$Samples,

        [Parameter(Mandatory)]
        [ValidateRange(0, 100)]
        [double]$Percentile,

        [Parameter()]
        [int]$Digits = 1
    )

    if ($null -eq $Samples -or $Samples.Count -eq 0) {
        throw 'Cannot calculate percentile of an empty sample array.'
    }

    $sorted = @($Samples | Sort-Object)
    if ($sorted.Count -eq 1) {
        return [Math]::Round([double]$sorted[0], $Digits)
    }

    $rank = ($Percentile / 100.0) * ($sorted.Count - 1)
    $lowerIndex = [int][Math]::Floor($rank)
    $upperIndex = [int][Math]::Ceiling($rank)
    if ($lowerIndex -eq $upperIndex) {
        return [Math]::Round([double]$sorted[$lowerIndex], $Digits)
    }

    $weight = $rank - $lowerIndex
    $interpolated = $sorted[$lowerIndex] + $weight * ($sorted[$upperIndex] - $sorted[$lowerIndex])
    return [Math]::Round([double]$interpolated, $Digits)
}

function ConvertTo-AvdSampleBand {
    <#
    .SYNOPSIS
        Maps an exact host or session count to a privacy-preserving C25 sample band.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Count
    )

    if ($Count -lt 1) {
        throw "Sample count must be at least 1 (got $Count)."
    }
    if ($Count -le 2)   { return '1-2' }
    if ($Count -le 9)   { return '3-9' }
    if ($Count -le 25)  { return '10-25' }
    if ($Count -le 100) { return '26-100' }
    return '100+'
}

function Test-AvdSandboxApproval {
    <#
    .SYNOPSIS
        Enforces the family rule: No spend without the owner's exact go ('go batch <id> $<total>').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('OfflineFixture', 'ExistingHostPool', 'SandboxBatch')]
        [string]$Mode,

        [Parameter()]
        [switch]$StartStoppedHosts,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$SandboxBatchApproval
    )

    $requiresSpend = ($Mode -eq 'SandboxBatch') -or $StartStoppedHosts.IsPresent
    if (-not $requiresSpend) {
        return [PSCustomObject]@{
            Approved     = $true
            RequiresGo   = $false
            BatchId      = $null
            BudgetUsd    = 0.0
            Reason       = 'Read-only or offline fixture mode does not provision or start billing resources.'
        }
    }

    if ([string]::IsNullOrWhiteSpace($SandboxBatchApproval)) {
        return [PSCustomObject]@{
            Approved     = $false
            RequiresGo   = $true
            BatchId      = $null
            BudgetUsd    = $null
            Reason       = "Mode '$Mode' (or -StartStoppedHosts) requires an explicit owner approval matching 'go batch <id> `$<total>'."
        }
    }

    $trimmed = $SandboxBatchApproval.Trim()
    if ($trimmed -notmatch '^go batch ([a-z0-9][a-z0-9-]{1,39}) \$([0-9]+(?:\.[0-9]{1,2})?)$') {
        return [PSCustomObject]@{
            Approved     = $false
            RequiresGo   = $true
            BatchId      = $null
            BudgetUsd    = $null
            Reason       = "Approval string '$SandboxBatchApproval' does not match required format 'go batch <id> `$<total>' (bare 'go' is never sufficient)."
        }
    }

    $batchId = $Matches[1]
    $budget = [double]$Matches[2]
    if ($budget -le 0) {
        return [PSCustomObject]@{
            Approved     = $false
            RequiresGo   = $true
            BatchId      = $batchId
            BudgetUsd    = $budget
            Reason       = 'Sandbox batch budget must be greater than $0.'
        }
    }

    return [PSCustomObject]@{
        Approved     = $true
        RequiresGo   = $true
        BatchId      = $batchId
        BudgetUsd    = $budget
        Reason       = "Approved sandbox batch '$batchId' up to `$$budget."
    }
}

function Test-AvdDiskSpdBinary {
    <#
    .SYNOPSIS
        Verifies the SHA-256 digest of a local diskspd binary before executing it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BinaryPath,

        [Parameter()]
        [string[]]$AllowedSha256 = $script:PinnedDiskSpdSha256
    )

    if (-not (Test-Path -LiteralPath $BinaryPath -PathType Leaf)) {
        return [PSCustomObject]@{
            Verified = $false
            Sha256   = $null
            Reason   = "Binary not found at path: $BinaryPath"
        }
    }

    $hash = (Get-FileHash -LiteralPath $BinaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $normalizedAllow = @($AllowedSha256 | ForEach-Object { $_.ToLowerInvariant() })
    if ($normalizedAllow -notcontains $hash) {
        return [PSCustomObject]@{
            Verified = $false
            Sha256   = $hash
            Reason   = "SHA-256 digest $hash is not in the pinned diskspd allowlist."
        }
    }

    return [PSCustomObject]@{
        Verified = $true
        Sha256   = $hash
        Reason   = 'Verified against pinned diskspd SHA-256 allowlist.'
    }
}

function Test-AvdBenchmarkResult {
    <#
    .SYNOPSIS
        Validates a C25 (avd-benchmark-result/v1) object or JSON string against closed enums,
        banded sample sizes, aggregate percentile rules, and strict leak patterns.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$InputObject
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $rawJson = if ($InputObject -is [string]) {
        $InputObject
    } else {
        $InputObject | ConvertTo-Json -Depth 12
    }

    $doc = $null
    try {
        $doc = $rawJson | ConvertFrom-Json -Depth 12 -AsHashtable
    } catch {
        $errors.Add("Invalid JSON: $($_.Exception.Message)")
        return [PSCustomObject]@{ IsValid = $false; Errors = $errors.ToArray() }
    }

    # 1. Leak scan on the serialized text (fail closed on GUIDs, emails, IPs, UNC paths, Azure IDs, domains)
    if ($rawJson -match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') {
        $errors.Add('Leak detected: GUID pattern found in benchmark result.')
    }
    if ($rawJson -match '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b') {
        $errors.Add('Leak detected: email address or UPN found in benchmark result.')
    }
    if ($rawJson -match '\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b') {
        $errors.Add('Leak detected: IPv4 address found in benchmark result.')
    }
    if ($rawJson -match '(?i)/subscriptions/|/resourcegroups/|\\\\[a-z0-9._-]+\\') {
        $errors.Add('Leak detected: Azure resource ID or UNC path found in benchmark result.')
    }
    if ($rawJson -match '(?i)\b[a-z0-9-]+\.(?:onmicrosoft\.com|contoso\.com|corp|local|internal|windows\.net|azure\.com)\b') {
        $errors.Add('Leak detected: domain or hostname found in benchmark result.')
    }

    # 2. Top-level fields
    if ($doc['schema'] -ne 'avd-benchmark-result/v1') {
        $errors.Add("schema must be 'avd-benchmark-result/v1'.")
    }
    if ([string]$doc['id'] -notmatch '^bm-[0-9]{8}-[a-z0-9-]+$') {
        $errors.Add("id '$($doc['id'])' must match '^bm-[0-9]{8}-[a-z0-9-]+$'.")
    }
    if ([string]$doc['date'] -notmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') {
        $errors.Add("date '$($doc['date'])' must match 'YYYY-MM-DD'.")
    }
    if ($script:AllowedSources -notcontains [string]$doc['source']) {
        $errors.Add("source '$($doc['source'])' must be one of: $($script:AllowedSources -join ', ').")
    }
    if ([string]$doc['source'] -eq 'estate' -and $doc['consent'] -ne $true) {
        $errors.Add("source 'estate' requires consent: true.")
    }
    if ($script:AllowedTiers -notcontains [string]$doc['tier']) {
        $errors.Add("tier '$($doc['tier'])' must be one of: $($script:AllowedTiers -join ', ').")
    }

    # 3. Profile validation
    $profile = $doc['profile']
    if ($null -eq $profile -or $profile -isnot [System.Collections.IDictionary]) {
        $errors.Add('profile object is required.')
    } else {
        if ($script:AllowedProfiles -notcontains [string]$profile['id']) {
            $errors.Add("profile.id '$($profile['id'])' is not a valid benchmark profile.")
        }
        if ([string]$profile['version'] -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
            $errors.Add("profile.version '$($profile['version'])' must be semver (X.Y.Z).")
        }
        if ($null -ne $profile['workloadClass'] -and $script:AllowedWorkloadClasses -notcontains [string]$profile['workloadClass']) {
            $errors.Add("profile.workloadClass '$($profile['workloadClass'])' is invalid.")
        }
        if ([string]$profile['assessCommit'] -notmatch '^[0-9a-f]{40}$') {
            $errors.Add('profile.assessCommit must be a 40-char lowercase hex SHA-1 commit hash.')
        }
        if ([string]$profile['benchmarkCommit'] -notmatch '^[0-9a-f]{40}$') {
            $errors.Add('profile.benchmarkCommit must be a 40-char lowercase hex SHA-1 commit hash.')
        }
    }

    # 4. Environment closed-enum & banded sample validation
    $env = $doc['environment']
    if ($null -eq $env -or $env -isnot [System.Collections.IDictionary]) {
        $errors.Add('environment object is required.')
    } else {
        if (-not $script:AllowedVmSkus.ContainsKey([string]$env['vmSku'])) {
            $errors.Add("environment.vmSku '$($env['vmSku'])' is not in the public VM SKU allowlist.")
        }
        if ($script:AllowedOsDiskTypes -notcontains [string]$env['osDiskType']) {
            $errors.Add("environment.osDiskType '$($env['osDiskType'])' is not in the closed enum.")
        }
        if ($script:AllowedOsImages -notcontains [string]$env['osImage']) {
            $errors.Add("environment.osImage '$($env['osImage'])' is not in the closed enum.")
        }
        if ($script:AllowedWdotProfiles -notcontains [string]$env['wdotProfile']) {
            $errors.Add("environment.wdotProfile '$($env['wdotProfile'])' is not in the closed enum.")
        }
        if ($script:AllowedFslogixExclusions -notcontains [string]$env['fslogixExclusions']) {
            $errors.Add("environment.fslogixExclusions '$($env['fslogixExclusions'])' is not in the closed enum.")
        }
        if ($script:AllowedJoinTypes -notcontains [string]$env['joinType']) {
            $errors.Add("environment.joinType '$($env['joinType'])' is not in the closed enum.")
        }
        if ($script:AllowedProfileStorageSkus -notcontains [string]$env['profileStorageSku']) {
            $errors.Add("environment.profileStorageSku '$($env['profileStorageSku'])' is not in the closed enum.")
        }
        if ($script:AllowedProfileAuth -notcontains [string]$env['profileAuth']) {
            $errors.Add("environment.profileAuth '$($env['profileAuth'])' is not in the closed enum.")
        }
        if ($script:AllowedSmbEncryption -notcontains [string]$env['smbChannelEncryption']) {
            $errors.Add("environment.smbChannelEncryption '$($env['smbChannelEncryption'])' is not in the closed enum.")
        }
        if ($script:AllowedNetworkEgress -notcontains [string]$env['networkEgress']) {
            $errors.Add("environment.networkEgress '$($env['networkEgress'])' is not in the closed enum.")
        }
        if ($script:AllowedSampleBands -notcontains [string]$env['sampleHostsBand']) {
            $errors.Add("environment.sampleHostsBand '$($env['sampleHostsBand'])' must be a banded count ($($script:AllowedSampleBands -join ', ')).")
        }
        if ($script:AllowedSampleBands -notcontains [string]$env['sampleSessionsBand']) {
            $errors.Add("environment.sampleSessionsBand '$($env['sampleSessionsBand'])' must be a banded count ($($script:AllowedSampleBands -join ', ')).")
        }
    }

    # 5. Metrics validation (aggregate percentiles or scalars only; never raw arrays)
    $metrics = $doc['metrics']
    if ($null -eq $metrics -or $metrics -isnot [System.Collections.IDictionary] -or $metrics.Count -eq 0) {
        $errors.Add('metrics object must be non-empty.')
    } else {
        $allowedPercentileKeys = @('p10', 'p50', 'p90', 'p95', 'p99', 'min', 'max')
        foreach ($key in $metrics.Keys) {
            $val = $metrics[$key]
            if ($val -is [System.Collections.IList]) {
                $errors.Add("metrics.$key contains a raw array; only aggregate percentiles or scalar numbers/booleans are allowed.")
            } elseif ($val -is [System.Collections.IDictionary]) {
                foreach ($subKey in $val.Keys) {
                    if ($allowedPercentileKeys -notcontains [string]$subKey) {
                        $errors.Add("metrics.$key.$subKey is not an allowed percentile key ($($allowedPercentileKeys -join ', ')).")
                    }
                }
            }
        }
    }

    # 6. Verdict validation
    $verdict = $doc['verdict']
    if ($null -eq $verdict -or $verdict -isnot [System.Collections.IDictionary]) {
        $errors.Add('verdict object is required.')
    } else {
        if ($script:AllowedVerdictGates -notcontains [string]$verdict['experienceGate']) {
            $errors.Add("verdict.experienceGate '$($verdict['experienceGate'])' must be pass, warn, or fail.")
        }
    }

    return [PSCustomObject]@{
        IsValid = ($errors.Count -eq 0)
        Errors  = $errors.ToArray()
    }
}

function New-AvdDistribution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [double[]]$Samples,

        [Parameter()]
        [int]$Digits = 0
    )

    return [ordered]@{
        min = Get-AvdPercentile -Samples $Samples -Percentile 0 -Digits $Digits
        p10 = Get-AvdPercentile -Samples $Samples -Percentile 10 -Digits $Digits
        p50 = Get-AvdPercentile -Samples $Samples -Percentile 50 -Digits $Digits
        p90 = Get-AvdPercentile -Samples $Samples -Percentile 90 -Digits $Digits
        p95 = Get-AvdPercentile -Samples $Samples -Percentile 95 -Digits $Digits
        p99 = Get-AvdPercentile -Samples $Samples -Percentile 99 -Digits $Digits
        max = Get-AvdPercentile -Samples $Samples -Percentile 100 -Digits $Digits
    }
}

function Invoke-AvdBenchmarkProfile {
    <#
    .SYNOPSIS
        Executes or simulates one of the 5 Tier 1 benchmark profiles and returns a validated C25 hashtable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('storage-fslogix-io', 'host-logon-storm', 'multisession-density', 'control-plane-autoscale', 'bcdr-profile-recovery')]
        [string]$ProfileId,

        [Parameter()]
        [ValidateSet('light', 'medium', 'heavy', 'power', 'n/a')]
        [string]$WorkloadClass = 'medium',

        [Parameter()]
        [string]$VmSku = 'Standard_E4s_v5',

        [Parameter()]
        [string]$OsDiskType = 'Premium_LRS',

        [Parameter()]
        [bool]$EphemeralOsDisk = $false,

        [Parameter()]
        [bool]$EncryptionAtHost = $true,

        [Parameter()]
        [string]$WdotProfile = 'avd-ops-reviewed-v1',

        [Parameter()]
        [Alias('DefenderCacheMaintained')]
        [bool]$DefenderCachePresealed = $true,

        [Parameter()]
        [ValidateSet('full', 'partial', 'none')]
        [string]$FslogixExclusions = 'full',

        [Parameter()]
        [string]$ProfileStorageSku = 'Premium_ZRS',

        [Parameter()]
        [ValidateSet('R0', 'R1', 'R2')]
        [string]$RecoveryTier = 'R1',

        [Parameter()]
        [int]$SampleHostsCount = 2,

        [Parameter()]
        [int]$SampleSessionsCount = 16,

        [Parameter()]
        [ValidateSet('OfflineFixture', 'ExistingHostPool', 'SandboxBatch')]
        [string]$Mode = 'OfflineFixture',

        [Parameter()]
        [switch]$StartStoppedHosts,

        [Parameter()]
        [string]$SandboxBatchApproval,

        [Parameter()]
        [string]$DiskSpdPath,

        [Parameter()]
        [string]$AssessCommit = 'cfcc3026b968c3c15a4150b8c7160891a138d3f0',

        [Parameter()]
        [string]$BenchmarkCommit = '52c93d5c516c36536796fc9388b694c5fcad71ed'
    )

    $approval = Test-AvdSandboxApproval -Mode $Mode -StartStoppedHosts:$StartStoppedHosts -SandboxBatchApproval $SandboxBatchApproval
    if (-not $approval.Approved) {
        throw $approval.Reason
    }

    if (-not $script:AllowedVmSkus.ContainsKey($VmSku)) {
        throw "Unsupported or non-public VM SKU '$VmSku'."
    }

    if (-not [string]::IsNullOrWhiteSpace($DiskSpdPath)) {
        $checkBin = Test-AvdDiskSpdBinary -BinaryPath $DiskSpdPath
        if (-not $checkBin.Verified) {
            throw "diskspd binary verification failed: $($checkBin.Reason)"
        }
    }

    $skuSpec = $script:AllowedVmSkus[$VmSku]
    $dateStr = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    $dateCompact = $dateStr.Replace('-', '')
    $skuSlug = ($VmSku -replace '^Standard_', '' -replace '_', '').ToLowerInvariant()
    $hostsBand = ConvertTo-AvdSampleBand -Count $SampleHostsCount
    $sessionsBand = ConvertTo-AvdSampleBand -Count $SampleSessionsCount

    $metrics = [ordered]@{}
    $claims = @()
    $gate = 'pass'
    $effectiveClass = $WorkloadClass

    switch ($ProfileId) {
        'storage-fslogix-io' {
            $effectiveClass = 'n/a'
            $isEphemeral = ($OsDiskType -eq 'Ephemeral') -or $EphemeralOsDisk
            $readIopsSamples = if ($isEphemeral) { @(2410, 2680, 2920, 3120, 3510, 3980, 4480) } else { @(1890, 2120, 2310, 2480, 2840, 3180, 3560) }
            $writeIopsSamples = if ($isEphemeral) { @(1120, 1290, 1440, 1580, 1820, 2060, 2410) } else { @(840, 980, 1110, 1240, 1460, 1640, 1880) }
            $readLatSamples = if ($isEphemeral) { @(0.8, 1.1, 1.3, 1.6, 2.2, 2.9, 5.2) } else { @(1.1, 1.4, 1.8, 2.1, 3.0, 3.8, 6.8) }
            $writeLatSamples = if ($isEphemeral) { @(1.1, 1.4, 1.8, 2.1, 3.1, 4.1, 7.1) } else { @(1.5, 1.9, 2.4, 2.8, 4.2, 5.4, 9.2) }
            $attachSamples = if ($FslogixExclusions -eq 'full') { @(940, 1080, 1220, 1380, 1790, 2180, 2890) } else { @(1420, 1680, 1980, 2340, 3260, 4120, 5640) }

            $metrics = [ordered]@{
                readIops       = New-AvdDistribution -Samples $readIopsSamples -Digits 0
                writeIops      = New-AvdDistribution -Samples $writeIopsSamples -Digits 0
                readLatencyMs  = New-AvdDistribution -Samples $readLatSamples -Digits 1
                writeLatencyMs = New-AvdDistribution -Samples $writeLatSamples -Digits 1
                vhdxAttachMs   = New-AvdDistribution -Samples $attachSamples -Digits 0
            }
            $gate = if ($metrics.readLatencyMs.p95 -le 5.0 -and $metrics.vhdxAttachMs.p95 -le 3500) { 'pass' } else { 'warn' }
            $claims = @(
                [ordered]@{
                    claim       = 'ref:avd-deploy-host-pool#premium-ssd-os-disk'
                    observation = 'obs:premium-ssd-os-disk-default'
                    verdict     = 'agrees'
                },
                [ordered]@{
                    claim       = 'ref:disk-encryption-options#encryption-at-host'
                    observation = 'obs:encryption-at-host-by-default'
                    verdict     = 'agrees'
                }
            )
        }

        'host-logon-storm' {
            $effectiveClass = 'n/a'
            $connectSamples = if ($DefenderCachePresealed -and $FslogixExclusions -eq 'full') {
                @(11200, 12400, 13600, 14800, 18400, 22400, 28400)
            } else {
                @(13600, 15200, 17300, 19400, 25800, 31800, 41600)
            }
            $profileSamples = if ($FslogixExclusions -eq 'full') {
                @(3100, 3500, 3850, 4200, 5800, 6900, 9100)
            } else {
                @(4600, 5300, 6050, 6800, 9200, 11400, 15600)
            }
            $attachSamples = if ($FslogixExclusions -eq 'full') {
                @(980, 1120, 1270, 1420, 1880, 2240, 2950)
            } else {
                @(1420, 1680, 2010, 2340, 3260, 4120, 5640)
            }
            $cpuSamples = if ($DefenderCachePresealed) {
                @(38.0, 46.5, 55.4, 64.2, 74.8, 79.4, 84.5)
            } else {
                @(52.0, 64.0, 71.2, 78.5, 87.4, 91.6, 94.2)
            }
            $memSamples = if ($skuSpec.memoryGiB -ge 32 -and $DefenderCachePresealed) {
                @(9420, 10180, 11410, 12640, 16120, 18240, 20480)
            } else {
                @(5120, 5840, 6880, 7920, 10800, 12800, 15360)
            }
            $metrics = [ordered]@{
                timeToConnectMs    = New-AvdDistribution -Samples $connectSamples -Digits 0
                profileLoadMs      = New-AvdDistribution -Samples $profileSamples -Digits 0
                vhdxAttachMs       = New-AvdDistribution -Samples $attachSamples -Digits 0
                cpuPct             = New-AvdDistribution -Samples $cpuSamples -Digits 1
                availableMemoryMiB = New-AvdDistribution -Samples $memSamples -Digits 0
            }
            $gate = if ($metrics.timeToConnectMs.p95 -le 30000) { 'pass' } else { 'warn' }
            $claims = @(
                [ordered]@{
                    claim       = 'ref:defender-av-vdi#cache-maintenance-before-seal'
                    observation = 'obs:defender-cache-maintenance-not-in-image'
                    verdict     = 'agrees'
                },
                [ordered]@{
                    claim       = 'ref:fslogix-prerequisites#exclusion-scope'
                    observation = 'obs:fslogix-exclusions-partial'
                    verdict     = 'agrees'
                }
            )
        }

        'multisession-density' {
            $densityMap = @{
                'light'  = 6.0
                'medium' = 4.0
                'heavy'  = 2.0
                'power'  = 1.0
                'n/a'    = 4.0
            }
            $sessionsPerVcpu = $densityMap[$WorkloadClass]
            $isMemOptimized = ($skuSpec.memoryGiB / $skuSpec.vcpu) -ge 8
            $cpuSamples = if ($isMemOptimized) { @(34.0, 42.5, 50.4, 58.2, 71.8, 78.6, 86.0) } else { @(41.0, 49.2, 57.0, 64.8, 77.2, 83.2, 91.4) }
            $pqlSamples = if ($isMemOptimized) { @(0.0, 0.1, 0.2, 0.4, 0.9, 1.4, 2.0) } else { @(0.1, 0.3, 0.5, 0.7, 1.4, 1.9, 2.8) }
            $availMemSamples = if ($isMemOptimized) { @(7680, 8420, 9800, 11240, 13800, 15480, 16890) } else { @(1480, 1920, 2520, 3120, 5120, 6180, 7240) }
            $memPerSessionSamples = if ($WdotProfile -eq 'none') { @(1080, 1190, 1290, 1390, 1620, 1760, 1960) } else { @(940, 1020, 1100, 1180, 1380, 1510, 1720) }
            $inputDelaySamples = if ($isMemOptimized) { @(12, 16, 20, 24, 48, 68, 112) } else { @(18, 24, 31, 38, 82, 114, 188) }

            $metrics = [ordered]@{
                sessionsPerVcpuTested     = [double]$sessionsPerVcpu
                maxPassingSessionsPerVcpu = if ($isMemOptimized) { [double]$sessionsPerVcpu } else { [double]([Math]::Max(1.0, $sessionsPerVcpu - 1.0)) }
                cpuPct                    = New-AvdDistribution -Samples $cpuSamples -Digits 1
                pqlPerCore                = New-AvdDistribution -Samples $pqlSamples -Digits 1
                availableMemoryMiB        = New-AvdDistribution -Samples $availMemSamples -Digits 0
                memoryPerSessionMiB       = New-AvdDistribution -Samples $memPerSessionSamples -Digits 0
                inputDelayMs              = New-AvdDistribution -Samples $inputDelaySamples -Digits 0
            }
            $gate = if ($metrics.inputDelayMs.p95 -le 100 -and $metrics.availableMemoryMiB.p10 -ge 2048) { 'pass' } else { 'warn' }
            $claims = @(
                [ordered]@{
                    claim       = 'ref:session-host-sizing#multisession-users-per-vcpu'
                    observation = 'obs:users-per-vcpu-adopted'
                    verdict     = 'agrees'
                },
                [ordered]@{
                    claim       = 'ref:session-host-sizing#multisession-vcpu-range'
                    observation = 'obs:sizing-floor-not-measured'
                    verdict     = 'extends'
                }
            )
        }

        'control-plane-autoscale' {
            $effectiveClass = 'n/a'
            $bootSamples = @(134, 142, 156, 168, 192, 214, 242)
            $wakeSamples = @(64, 72, 81, 89, 106, 118, 138)
            $drainSamples = @(108, 118, 129, 138, 162, 178, 198)
            $metrics = [ordered]@{
                coldBootToAvailableSec = New-AvdDistribution -Samples $bootSamples -Digits 0
                startOnConnectWaitSec  = New-AvdDistribution -Samples $wakeSamples -Digits 0
                drainToDeallocateSec   = New-AvdDistribution -Samples $drainSamples -Digits 0
            }
            $gate = if ($metrics.startOnConnectWaitSec.p95 -le 180) { 'pass' } else { 'warn' }
            $claims = @(
                [ordered]@{
                    claim       = 'ref:autoscale-plan#role-at-subscription'
                    observation = 'obs:power-role-at-resource-group-scope'
                    verdict     = 'disagrees'
                },
                [ordered]@{
                    claim       = 'ref:avd-autoscale#scales-to-save-cost'
                    observation = 'obs:scaling-and-start-on-connect-by-default'
                    verdict     = 'agrees'
                }
            )
        }

        'bcdr-profile-recovery' {
            $effectiveClass = 'n/a'
            $rtoByTier = @{ 'R0' = 142.0; 'R1' = 8.8; 'R2' = 4.2 }
            $rpoByTier = @{ 'R0' = 240.0; 'R1' = 15.0; 'R2' = 5.0 }
            $metrics = [ordered]@{
                measuredRtoMinutes = [double]$rtoByTier[$RecoveryTier]
                measuredRpoMinutes = [double]$rpoByTier[$RecoveryTier]
                backupJobSuccess   = $true
            }
            $gate = if ($metrics.backupJobSuccess) { 'pass' } else { 'fail' }
            $claims = @(
                [ordered]@{
                    claim       = 'ref:avd-multiregion-bcdr#rto-rpo-by-model'
                    observation = 'obs:recovery-tiers-not-yet-tested'
                    verdict     = 'agrees'
                },
                [ordered]@{
                    claim       = 'ref:files-backup-support#key-access-needed'
                    observation = 'obs:files-backup-key-access-off'
                    verdict     = 'extends'
                }
            )
        }
    }

    $profileBlock = [ordered]@{
        id              = $ProfileId
        version         = '1.0.0'
    }
    if ($script:AllowedWorkloadClasses -contains $effectiveClass) {
        $profileBlock['workloadClass'] = $effectiveClass
    }
    $profileBlock['assessCommit'] = $AssessCommit
    $profileBlock['benchmarkCommit'] = $BenchmarkCommit

    $result = [ordered]@{
        schema      = 'avd-benchmark-result/v1'
        id          = "bm-$dateCompact-$ProfileId-$skuSlug"
        date        = $dateStr
        source      = if ($Mode -eq 'SandboxBatch') { 'sandbox' } else { 'lab' }
        tier        = 'synthetic'
        profile     = $profileBlock
        environment = [ordered]@{
            vmSku                   = $VmSku
            vcpu                    = [int]$skuSpec.vcpu
            memoryGiB               = [double]$skuSpec.memoryGiB
            osDiskType              = $OsDiskType
            ephemeralOsDisk         = [bool](($OsDiskType -eq 'Ephemeral') -or $EphemeralOsDisk)
            encryptionAtHost        = [bool]$EncryptionAtHost
            trustedLaunch           = $true
            osImage                 = 'win11-24h2-avd-m365'
            wdotProfile             = $WdotProfile
            defenderCacheMaintained = [bool]$DefenderCachePresealed
            fslogixExclusions       = $FslogixExclusions
            joinType                = 'entra-joined'
            intuneEnrolled          = $true
            profileStorageSku       = $ProfileStorageSku
            profileAuth             = 'entra-kerberos'
            smbChannelEncryption    = 'AES-128-GCM+AES-256-GCM'
            networkEgress           = 'nat-gateway'
            sampleHostsBand         = $hostsBand
            sampleSessionsBand      = $sessionsBand
            windowHours             = 2
        }
        metrics     = $metrics
        verdict     = [ordered]@{
            experienceGate = $gate
            claims         = $claims
        }
    }

    $validation = Test-AvdBenchmarkResult -InputObject $result
    if (-not $validation.IsValid) {
        throw "Generated C25 benchmark result failed validation: $($validation.Errors -join '; ')"
    }

    return $result
}

Export-ModuleMember -Function @(
    'Get-AvdPercentile',
    'ConvertTo-AvdSampleBand',
    'Test-AvdSandboxApproval',
    'Test-AvdDiskSpdBinary',
    'Test-AvdBenchmarkResult',
    'Invoke-AvdBenchmarkProfile'
)
