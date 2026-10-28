# avd-benchmark

Part of [avd-ops](https://avd-ops.dev/), the open toolkit for Azure Virtual Desktop.

Active Tier 1 synthetic and control-plane benchmark harness (`Invoke-AvdBenchmark.ps1`, `scripts/run-benchmark.sh`) and interactive OpenBenchmarking-style **Benchmark Explorer & Runner Portal** (`site/portal/`) for Azure Virtual Desktop. Benchmark profile definitions, experience gates, and the public corpus live in [avd-assess](https://github.com/avd-ops/avd-assess), while passive Tier 2 observational telemetry lives in [avd-current-state](https://github.com/avd-ops/avd-current-state).

> [!WARNING]
> **Personal project. Research and learning only. Not for production. No warranty.**
>
> - This is my own personal project, built on my own time **for research and learning**. It is **not affiliated with, endorsed by or supported by my employer, Liquidware or Microsoft**, and it does not represent their views, products or guidance. It is not an official Microsoft product, and it is not a certified or supported tool.
> - **Do not run active synthetic load profiles on production session hosts.** Use an isolated lab host pool or an approved ephemeral sandbox batch (`-SandboxBatchApproval "go batch <id> $<total>"`). Output is not a production-readiness certification, a compliance attestation or a security audit.
> - It is provided **"as is", without warranty of any kind**, under the [MIT License](LICENSE). You use it at your own risk. You are responsible for where you run it and for what you do with its output.
> - **Contributions and forks are welcome and encouraged.** See [Contributing](#contributing).

## Tier 1 Benchmark Profiles

`avd-benchmark` implements five declarative Tier 1 benchmark profiles defined in `avd-assess`:

| Profile ID | What It Measures | Probe / Open-Source Tool | Key Output Metrics (`C25`) |
|---|---|---|---|
| `storage-fslogix-io` | Profile share and local OS disk IOPS and latency (`p50`/`p95`/`p99`) plus VHDX mount time | Pinned MIT [Microsoft `diskspd`](https://github.com/microsoft/diskspd) (SHA-256 verified before execution) + PowerShell VHDX attach timer | `readIopsP50`, `readIopsP95`, `writeIopsP95`, `readLatencyMsP95`, `writeLatencyMsP99`, `vhdxAttachMsP95` |
| `host-logon-storm` | Concurrent or staggered session connection and FSLogix profile load timings | Windows Event Logs (`FSLogix-Apps/Operational`, `TerminalServices`) + `WVDConnections` | `timeToConnectMsP50`, `timeToConnectMsP95`, `profileLoadMsP95`, `peakCpuPct`, `availMemMiBMin` |
| `multisession-density` | Multi-session CPU, processor queue length, available memory, memory per session, and user input delay across `light`, `medium`, `heavy`, and `power` personas | Native PowerShell worker processes + PerfMon (`\User Input Delay per Session(Max)\Max Input Delay`, `\Processor(_Total)\% Processor Time`, `\System\Processor Queue Length`, `\Memory\Available MBytes`) | `sessionsPerVcpuTested`, `cpuPct`, `pqlPerCore`, `availableMemoryMiB`, `memoryPerSessionMiB`, `inputDelayMs` |
| `control-plane-autoscale` | Session host cold boot to `Available`, `StartVMOnConnect` wake latency, and scaling plan drain-to-deallocate time | Azure Resource Graph + `WVDConnections` + `WVDAgentHealthStatus` timer | `coldBootToAvailableSecP95`, `startOnConnectWaitSecP95`, `drainToDeallocateSecP95` |
| `bcdr-profile-recovery` | Measured RTO and RPO for R0 (rebuild), R1 (restore anywhere), and R2 (warm standby) profile recovery drills and backup verification | Recovery drill timer + Azure Backup job status | `measuredRtoMinutes`, `measuredRpoMinutes`, `backupJobSuccess` |

## Usage (`Invoke-AvdBenchmark.ps1` & `scripts/run-benchmark.sh`)

By default, `Invoke-AvdBenchmark.ps1` runs in `-Mode OfflineFixture` or `-Mode ExistingHostPool` without provisioning or starting cloud resources. Any mode that provisions, starts, or scales cloud resources (`-Mode SandboxBatch` or `-StartStoppedHosts`) requires an explicit `-SandboxBatchApproval "go batch <id> $<total>"` string under the family spend rule.

### PowerShell 7

```powershell
if (-not (Test-Path ~/avd-benchmark)) { git clone https://github.com/avd-ops/avd-benchmark.git ~/avd-benchmark }
Set-Location ~/avd-benchmark; git checkout -q main; git pull -q --ff-only
pwsh -NoLogo -File ./Invoke-AvdBenchmark.ps1 -ProfileId multisession-density -WorkloadClass medium -VmSku Standard_E4s_v5 -Mode OfflineFixture -OutputPath ./out
```

### Bash

```bash
if [ ! -d "$HOME/avd-benchmark" ]; then git clone https://github.com/avd-ops/avd-benchmark.git "$HOME/avd-benchmark"; fi
cd "$HOME/avd-benchmark" && git checkout -q main && git pull -q --ff-only
bash ./scripts/run-benchmark.sh --profile multisession-density --workload-class medium --vm-sku Standard_E4s_v5 --mode OfflineFixture --output-path ./out
```

## Contract C25 (`avd-benchmark-result/v1`) and Redaction Guard

Every result written by `Invoke-AvdBenchmark.ps1` is validated by `scripts/AvdBenchmark.psm1` (`Test-AvdBenchmarkResult`) before it touches disk:

- **Closed enums and public VM SKUs only** in `environment.*` (`Standard_E4s_v5`, `Standard_D8s_v5`, `Premium_LRS`, `Ephemeral`, etc.).
- **Banded sample counts** (`1-2`, `3-9`, `10-25`, `26-100`, `100+`) so exact host or user counts cannot fingerprint an organization.
- **Aggregate percentiles only** (`p50`, `p90`, `p95`, `p99`, `min`, `max`) in `metrics.*`.
- **Fail-closed leak scanner:** rejects any payload containing a GUID, email/UPN, IPv4/IPv6 address, UNC path, Azure resource ID (`/subscriptions/...`), or private domain name.

## Interactive Benchmark Explorer & Runner Portal (`site/portal/`)

[`site/portal/`](site/portal/) is a static single-page portal built on the vendored `avd-ops` design system (`site/assets/`):

1. **Explorer (Compare):** Filter by Tier 1 profile (`multisession-density`, `storage-fslogix-io`, `host-logon-storm`, `control-plane-autoscale`, `bcdr-profile-recovery`), compare side-by-side across VM SKUs (`Standard_E4s_v5` vs `Standard_D8s_v5`), OS disk types (`Premium_LRS` vs `Ephemeral`), and WDOT/Defender settings; inspect `p50`/`p90`/`p95` distribution bars, experience gate verdicts, and one-click citation strings (`avd-assess@<commit>:evidence/<profile>/<id>.json`).
2. **Run Harness (Cloud Shell / Host):** Interactive command generator for PowerShell and Bash producing standalone Cloud Shell blocks.
3. **Validate & Submit Evidence (`C25`):** Client-side JSON schema validator and leak scanner that verifies a `C25` JSON file in your browser and opens the prefilled `baseline-evidence.yml` GitHub Issue Form on `avd-assess`.

## Contributing

Contributions and forks are welcome and encouraged. Before opening a pull request, run both offline test suites:

```bash
pwsh -c "Invoke-Pester -Path ./tests -CI"
node --test "tests/*.test.mjs"
```

Keep tenant data, IDs and secrets out of the repo, issues and pull requests. By contributing, you agree your contributions are licensed under the repo's [MIT License](LICENSE).

## License

This project is licensed under the [MIT License](LICENSE), provided "as is", without warranty of any kind.
