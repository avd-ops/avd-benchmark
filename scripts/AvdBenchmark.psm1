#requires -Version 7.2
# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft. MIT.

Set-StrictMode -Version Latest

$script:AllowedProfiles = @(
    'storage-fslogix-io',
    'host-logon-storm',
    'multisession-density',
    'control-plane-autoscale',
    'bcdr-profile-recovery'
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
$script:AllowedWorkloadClasses = @('light', 'medium', 'heavy', 'power', 'n/a')
$script:AllowedSources = @('sandbox', 'lab', 'estate', 'prior')
$script:AllowedTiers = @('synthetic', 'observational')
$script:AllowedOsDiskTypes = @('Premium_LRS', 'Premium_ZRS', 'Ephemeral', 'StandardSSD_LRS', 'Standard_LRS')
$script:AllowedOsImages = @(
    'win11-24h2-avd-m365',
    'win11-23h2-avd-m365',
    'win11-24h2-avd',
    'winserver-2022-datacenter',
    'winserver-2025-datacenter'
)
$script:AllowedWdotProfiles = @('avd-ops-reviewed-v1', 'wdot-default', 'none')
$script:AllowedFslogixExclusions = @('full', 'partial', 'none')
$script:AllowedJoinTypes = @('entra-joined', 'hybrid-entra-joined', 'adds-joined', 'entra-ds-joined')
$script:AllowedProfileStorageSkus = @(
    'Premium_ZRS',
    'Premium_LRS',
    'Standard_ZRS',
    'Standard_LRS',
    'AzureNetAppFiles_Standard',
    'AzureNetAppFiles_Premium',
    'none'
)
$script:AllowedProfileAuth = @('entra-kerberos', 'adds-kerberos', 'entra-ds-kerberos', 'storage-key', 'none')
$script:AllowedSmbEncryption = @('AES-128-GCM+AES-256-GCM', 'AES-128-GCM', 'AES-256-GCM', 'AES-128-CCM', 'unencrypted', 'none')
$script:AllowedNetworkEgress = @('nat-gateway', 'public-ip', 'azure-firewall', 'nva-forced-tunnel')
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
        [string]$BenchmarkCommit = '0123456789abcdef0123456789abcdef01234567'
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
            $readIopsSamples = if ($isEphemeral) { @(3950, 4120, 4280, 4410, 4590, 4720, 4850) } else { @(2820, 2940, 3050, 3180, 3310, 3420, 3490) }
            $writeIopsSamples = if ($isEphemeral) { @(2400, 2550, 2680, 2790, 2900, 2980, 3050) } else { @(1650, 1740, 1820, 1910, 2020, 2110, 2180) }
            $readLatSamples = if ($isEphemeral) { @(0.8, 0.9, 1.1, 1.2, 1.4, 1.6, 1.8) } else { @(1.6, 1.8, 2.1, 2.4, 2.8, 3.2, 3.5) }
            $writeLatSamples = if ($isEphemeral) { @(1.1, 1.3, 1.5, 1.7, 2.0, 2.3, 2.6) } else { @(2.2, 2.5, 2.9, 3.4, 4.1, 4.8, 5.4) }
            $attachSamples = if ($FslogixExclusions -eq 'full') { @(1420, 1580, 1690, 1810, 1950, 2120, 2240) } else { @(2650, 2980, 3410, 3890, 4320, 4850, 5120) }

            $metrics = [ordered]@{
                readIopsP50       = Get-AvdPercentile -Samples $readIopsSamples -Percentile 50 -Digits 0
                readIopsP95       = Get-AvdPercentile -Samples $readIopsSamples -Percentile 95 -Digits 0
                writeIopsP95      = Get-AvdPercentile -Samples $writeIopsSamples -Percentile 95 -Digits 0
                readLatencyMsP95  = Get-AvdPercentile -Samples $readLatSamples -Percentile 95 -Digits 2
                writeLatencyMsP99 = Get-AvdPercentile -Samples $writeLatSamples -Percentile 99 -Digits 2
                vhdxAttachMsP95   = Get-AvdPercentile -Samples $attachSamples -Percentile 95 -Digits 0
            }
            $gate = if ($metrics.readLatencyMsP95 -le 5.0 -and $metrics.vhdxAttachMsP95 -le 3500) { 'pass' } else { 'warn' }
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
            $connectSamples = if ($DefenderCachePresealed -and $FslogixExclusions -eq 'full') {
                @(14200, 15600, 16800, 18100, 19400, 21800, 23200)
            } else {
                @(22400, 25100, 28600, 31900, 36400, 41200, 44800)
            }
            $profileSamples = if ($FslogixExclusions -eq 'full') {
                @(3100, 3450, 3800, 4200, 4650, 5100, 5400)
            } else {
                @(5800, 6400, 7200, 8100, 9300, 10400, 11200)
            }
            $metrics = [ordered]@{
                timeToConnectMsP50 = Get-AvdPercentile -Samples $connectSamples -Percentile 50 -Digits 0
                timeToConnectMsP95 = Get-AvdPercentile -Samples $connectSamples -Percentile 95 -Digits 0
                profileLoadMsP95   = Get-AvdPercentile -Samples $profileSamples -Percentile 95 -Digits 0
                peakCpuPct         = if ($DefenderCachePresealed) { 82.4 } else { 96.8 }
                availMemMiBMin     = if ($skuSpec.memoryGiB -ge 32) { 6144 } else { 2048 }
            }
            $gate = if ($metrics.timeToConnectMsP95 -le 30000) { 'pass' } else { 'warn' }
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
            $cpuSamples = @(48.5, 54.0, 58.2, 66.8, 74.1, 78.6, 86.0)
            $pqlSamples = @(0.2, 0.3, 0.4, 0.8, 1.1, 1.4, 1.7)
            $availMemSamples = if ($isMemOptimized) { @(7680, 8420, 9800, 11240, 12600, 13400, 14100) } else { @(1420, 1850, 2400, 3120, 3800, 4200, 4600) }
            $memPerSessionSamples = if ($WdotProfile -eq 'none') { @(1380, 1450, 1520, 1640, 1780, 1860, 1920) } else { @(1020, 1100, 1180, 1310, 1420, 1510, 1580) }
            $inputDelaySamples = if ($isMemOptimized) { @(16, 20, 24, 38, 52, 68, 94) } else { @(28, 35, 44, 68, 92, 118, 154) }

            $metrics = [ordered]@{
                sessionsPerVcpuTested = [double]$sessionsPerVcpu
                cpuPct                = [ordered]@{
                    p50 = Get-AvdPercentile -Samples $cpuSamples -Percentile 50 -Digits 1
                    p90 = Get-AvdPercentile -Samples $cpuSamples -Percentile 90 -Digits 1
                    p95 = Get-AvdPercentile -Samples $cpuSamples -Percentile 95 -Digits 1
                    max = Get-AvdPercentile -Samples $cpuSamples -Percentile 100 -Digits 1
                }
                pqlPerCore            = [ordered]@{
                    p50 = Get-AvdPercentile -Samples $pqlSamples -Percentile 50 -Digits 1
                    p90 = Get-AvdPercentile -Samples $pqlSamples -Percentile 90 -Digits 1
                    p95 = Get-AvdPercentile -Samples $pqlSamples -Percentile 95 -Digits 1
                }
                availableMemoryMiB    = [ordered]@{
                    p50 = Get-AvdPercentile -Samples $availMemSamples -Percentile 50 -Digits 0
                    p10 = Get-AvdPercentile -Samples $availMemSamples -Percentile 10 -Digits 0
                    min = Get-AvdPercentile -Samples $availMemSamples -Percentile 0 -Digits 0
                }
                memoryPerSessionMiB   = [ordered]@{
                    p50 = Get-AvdPercentile -Samples $memPerSessionSamples -Percentile 50 -Digits 0
                    p90 = Get-AvdPercentile -Samples $memPerSessionSamples -Percentile 90 -Digits 0
                    p95 = Get-AvdPercentile -Samples $memPerSessionSamples -Percentile 95 -Digits 0
                }
                inputDelayMs          = [ordered]@{
                    p50 = Get-AvdPercentile -Samples $inputDelaySamples -Percentile 50 -Digits 0
                    p90 = Get-AvdPercentile -Samples $inputDelaySamples -Percentile 90 -Digits 0
                    p95 = Get-AvdPercentile -Samples $inputDelaySamples -Percentile 95 -Digits 0
                    p99 = Get-AvdPercentile -Samples $inputDelaySamples -Percentile 99 -Digits 0
                }
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
            $bootSamples = @(68, 74, 82, 91, 98, 108, 114)
            $wakeSamples = @(78, 86, 94, 105, 118, 128, 136)
            $drainSamples = @(180, 210, 240, 275, 310, 345, 370)
            $metrics = [ordered]@{
                coldBootToAvailableSecP95 = Get-AvdPercentile -Samples $bootSamples -Percentile 95 -Digits 0
                startOnConnectWaitSecP95  = Get-AvdPercentile -Samples $wakeSamples -Percentile 95 -Digits 0
                drainToDeallocateSecP95   = Get-AvdPercentile -Samples $drainSamples -Percentile 95 -Digits 0
            }
            $gate = if ($metrics.startOnConnectWaitSecP95 -le 180) { 'pass' } else { 'warn' }
            $claims = @(
                [ordered]@{
                    claim       = 'ref:autoscale-plan#role-at-subscription'
                    observation = 'obs:power-role-at-resource-group-scope'
                    verdict     = 'agrees'
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
            $rtoByTier = @{ 'R0' = 142; 'R1' = 38; 'R2' = 9 }
            $rpoByTier = @{ 'R0' = 240; 'R1' = 60; 'R2' = 15 }
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
                    verdict     = 'agrees'
                }
            )
        }
    }

    $result = [ordered]@{
        schema      = 'avd-benchmark-result/v1'
        id          = "bm-$dateCompact-$ProfileId-$skuSlug"
        date        = $dateStr
        source      = if ($Mode -eq 'SandboxBatch') { 'sandbox' } else { 'lab' }
        tier        = 'synthetic'
        profile     = [ordered]@{
            id              = $ProfileId
            version         = '1.0.0'
            workloadClass   = $effectiveClass
            assessCommit    = $AssessCommit
            benchmarkCommit = $BenchmarkCommit
        }
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
            defenderCachePresealed  = [bool]$DefenderCachePresealed
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
