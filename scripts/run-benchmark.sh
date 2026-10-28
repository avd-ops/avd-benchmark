#!/usr/bin/env bash
# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft. MIT.
# Companion Bash wrapper for Invoke-AvdBenchmark.ps1 (docs/run-anywhere.md).

set -euo pipefail

if [ "${BASH_VERSINFO[0]:-0}" -lt 3 ]; then
  echo "Error: bash 3.2 or later is required." >&2
  exit 2
fi

if ! command -v pwsh >/dev/null 2>&1; then
  echo "Error: PowerShell 7 (pwsh) is required to run Invoke-AvdBenchmark.ps1." >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MSYS_NO_PATHCONV=1

PROFILE_ID="multisession-density"
WORKLOAD_CLASS="medium"
VM_SKU="Standard_E4s_v5"
OS_DISK_TYPE="Premium_LRS"
WDOT_PROFILE="avd-ops-reviewed-v1"
FSLOGIX_EXCLUSIONS="full"
MODE="OfflineFixture"
APPROVAL=""
OUTPUT_PATH=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      PROFILE_ID="$2"
      shift 2
      ;;
    --workload-class)
      WORKLOAD_CLASS="$2"
      shift 2
      ;;
    --vm-sku)
      VM_SKU="$2"
      shift 2
      ;;
    --os-disk-type)
      OS_DISK_TYPE="$2"
      shift 2
      ;;
    --wdot-profile)
      WDOT_PROFILE="$2"
      shift 2
      ;;
    --fslogix-exclusions)
      FSLOGIX_EXCLUSIONS="$2"
      shift 2
      ;;
    --mode)
      MODE="$2"
      shift 2
      ;;
    --sandbox-batch-approval)
      APPROVAL="$2"
      shift 2
      ;;
    --output-path)
      OUTPUT_PATH="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: ./scripts/run-benchmark.sh [--profile <id>] [--workload-class <class>] [--vm-sku <sku>] [--os-disk-type <type>] [--mode <OfflineFixture|ExistingHostPool|SandboxBatch>] [--sandbox-batch-approval 'go batch <id> \$<total>'] [--output-path <dir>]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

ARGS=(
  -NoLogo
  -NoProfile
  -File "$SCRIPT_DIR/Invoke-AvdBenchmark.ps1"
  -ProfileId "$PROFILE_ID"
  -WorkloadClass "$WORKLOAD_CLASS"
  -VmSku "$VM_SKU"
  -OsDiskType "$OS_DISK_TYPE"
  -WdotProfile "$WDOT_PROFILE"
  -FslogixExclusions "$FSLOGIX_EXCLUSIONS"
  -Mode "$MODE"
)

if [ -n "$APPROVAL" ]; then
  ARGS+=(-SandboxBatchApproval "$APPROVAL")
fi

if [ -n "$OUTPUT_PATH" ]; then
  ARGS+=(-OutputPath "$OUTPUT_PATH")
fi

exec pwsh "${ARGS[@]}"
