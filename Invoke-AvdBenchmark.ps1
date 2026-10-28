#requires -Version 7.2
<#
.SYNOPSIS
    Runs an AVD Tier 1 benchmark profile and writes a redacted, validated C25 (avd-benchmark-result/v1) JSON file.
.DESCRIPTION
    Supports the five Tier 1 profiles defined in avd-assess:
      - storage-fslogix-io
      - host-logon-storm
      - multisession-density
      - control-plane-autoscale
      - bcdr-profile-recovery
    Enforces the family spend rule: any mode that provisions or starts cloud resources requires
    -SandboxBatchApproval "go batch <id> $<total>".
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidateSet('storage-fslogix-io', 'host-logon-storm', 'multisession-density', 'control-plane-autoscale', 'bcdr-profile-recovery')]
    [string]$ProfileId = 'multisession-density',

    [Parameter()]
    [ValidateSet('light', 'medium', 'heavy', 'power', 'n/a')]
    [string]$WorkloadClass = 'medium',

    [Parameter()]
    [string]$VmSku = 'Standard_E4s_v5',

    [Parameter()]
    [ValidateSet('Premium_LRS', 'Premium_ZRS', 'Ephemeral', 'StandardSSD_LRS', 'Standard_LRS')]
    [string]$OsDiskType = 'Premium_LRS',

    [Parameter()]
    [bool]$EncryptionAtHost = $true,

    [Parameter()]
    [ValidateSet('avd-ops-reviewed-v1', 'wdot-default', 'none')]
    [string]$WdotProfile = 'avd-ops-reviewed-v1',

    [Parameter()]
    [bool]$DefenderCachePresealed = $true,

    [Parameter()]
    [ValidateSet('full', 'partial', 'none')]
    [string]$FslogixExclusions = 'full',

    [Parameter()]
    [ValidateSet('Premium_ZRS', 'Premium_LRS', 'Standard_ZRS', 'Standard_LRS', 'AzureNetAppFiles_Standard', 'AzureNetAppFiles_Premium', 'none')]
    [string]$ProfileStorageSku = 'Premium_ZRS',

    [Parameter()]
    [ValidateSet('R0', 'R1', 'R2')]
    [string]$RecoveryTier = 'R1',

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
    [string]$OutputPath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'scripts' 'AvdBenchmark.psm1'
Import-Module $modulePath -Force

$approval = Test-AvdSandboxApproval -Mode $Mode -StartStoppedHosts:$StartStoppedHosts -SandboxBatchApproval $SandboxBatchApproval
if (-not $approval.Approved) {
    throw $approval.Reason
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $cloudDrive = Join-Path $HOME 'clouddrive'
    if (Test-Path -LiteralPath $cloudDrive -PathType Container) {
        $OutputPath = Join-Path $cloudDrive 'avd-benchmark-out'
    } else {
        $OutputPath = Join-Path $PSScriptRoot 'out'
    }
}

$result = Invoke-AvdBenchmarkProfile `
    -ProfileId $ProfileId `
    -WorkloadClass $WorkloadClass `
    -VmSku $VmSku `
    -OsDiskType $OsDiskType `
    -EncryptionAtHost $EncryptionAtHost `
    -WdotProfile $WdotProfile `
    -DefenderCachePresealed $DefenderCachePresealed `
    -FslogixExclusions $FslogixExclusions `
    -ProfileStorageSku $ProfileStorageSku `
    -RecoveryTier $RecoveryTier `
    -Mode $Mode `
    -StartStoppedHosts:$StartStoppedHosts `
    -SandboxBatchApproval $SandboxBatchApproval `
    -DiskSpdPath $DiskSpdPath

if ($PSCmdlet.ShouldProcess($OutputPath, "Write C25 benchmark result $($result.id).json")) {
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }
    $outFile = Join-Path $OutputPath "$($result.id).json"
    $json = $result | ConvertTo-Json -Depth 12
    Set-Content -LiteralPath $outFile -Value $json -Encoding utf8NoBOM
    $statePayload = [ordered]@{
        v       = 1
        stage   = 'benchmark'
        status  = 'done'
        profile = $ProfileId
        id      = $result.id
        gate    = $result.verdict.experienceGate
        file    = (Split-Path -Leaf $outFile)
    } | ConvertTo-Json -Compress
    Write-Host "<<<AVDBM-STATE $statePayload AVDBM-STATE>>>"
}

if ($PassThru) {
    return $result
}
