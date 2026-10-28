@AGENTS.md

# CLAUDE.md

avd-benchmark: the active Tier 1 synthetic and control-plane benchmark harness (`Invoke-AvdBenchmark.ps1`, `scripts/run-benchmark.sh`, `scripts/AvdBenchmark.psm1`) and the static Benchmark Explorer & Runner Portal (`site/portal/`). Benchmark profile definitions, experience gates, and the public corpus live in `avd-assess` and are pinned in `PINS.json`.

## Validate before pushing

```bash
pwsh -c "Invoke-Pester -Path ./tests -CI"
node --test "tests/*.test.mjs"
```

## Rules

- Every portal page keeps the research-only notice in the brand bar before its first `<h2>`, uses the vendored `avd-ops` design system (`site/assets/`), has no inline styles (`style=`), names no partner product or HCL tooling, and ends with the credit line.
- Every Cloud Shell command block stands alone (`git clone ...`, `Set-Location ...; git checkout -q ...; git pull -q --ff-only`, no `...` or `\` line continuations).
- Never provision or start cloud resources without `-SandboxBatchApproval "go batch <id> $<total>"`.
- Every `C25` (`avd-benchmark-result/v1`) output must pass `Test-AvdBenchmarkResult` (closed enums, banded sample sizes, aggregate percentiles only, zero GUIDs/emails/IPs/domains).
