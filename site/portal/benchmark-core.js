/* Personal project, not for production, as is; not affiliated with the author's employer or Microsoft. MIT.
   benchmark-core.js: pure functions for the AVD Benchmark Explorer & Runner Portal (site/portal/).
   Runs in the browser (window.BenchmarkCore) and in Node (tests/portal.test.mjs). */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) {
    module.exports = factory();
  } else {
    root.BenchmarkCore = factory();
  }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const ALLOWED_PROFILES = [
    'storage-fslogix-io',
    'host-logon-storm',
    'multisession-density',
    'rpa-ui-responsiveness',
    'control-plane-autoscale',
    'bcdr-profile-recovery',
    'insights-observational'
  ];

  const ALLOWED_VM_SKUS = [
    'Standard_D4s_v5',
    'Standard_D8s_v5',
    'Standard_D16s_v5',
    'Standard_D4as_v5',
    'Standard_D8as_v5',
    'Standard_D4ads_v5',
    'Standard_D8ads_v5',
    'Standard_E4s_v5',
    'Standard_E8s_v5',
    'Standard_E4as_v5',
    'Standard_E8as_v5',
    'Standard_F8s_v2',
    'Standard_NV8as_v4'
  ];

  const ALLOWED_OS_DISK_TYPES = ['Premium_LRS', 'Premium_ZRS', 'PremiumV2_LRS', 'StandardSSD_LRS', 'StandardSSD_ZRS', 'Standard_LRS', 'Ephemeral'];
  const ALLOWED_OS_IMAGES = [
    'win11-24h2-avd-m365',
    'win11-24h2-avd',
    'win11-23h2-avd-m365',
    'win11-23h2-avd',
    'win10-22h2-avd',
    'ws2025-datacenter',
    'ws2022-datacenter',
    'custom-optimized',
    'custom-unoptimized'
  ];
  const ALLOWED_WDOT = ['avd-ops-reviewed-v1', 'wdot-default', 'none', 'other'];
  const ALLOWED_EXCLUSIONS = ['full', 'partial', 'none'];
  const ALLOWED_JOIN_TYPES = ['entra-joined', 'hybrid-entra-joined', 'ad-domain-joined'];
  const ALLOWED_PROFILE_STORAGE = [
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
  ];
  const ALLOWED_PROFILE_AUTH = ['entra-kerberos', 'ad-ds', 'entra-ds', 'none'];
  const ALLOWED_SMB_ENC = ['AES-128-GCM+AES-256-GCM', 'AES-256-GCM-only', 'includes-CCM', 'default', 'none'];
  const ALLOWED_EGRESS = ['nat-gateway', 'azure-firewall', 'nva', 'default-outbound', 'public-ip', 'private-link'];
  const ALLOWED_SAMPLE_BANDS = ['1-2', '3-9', '10-25', '26-100', '100+'];
  const ALLOWED_SOURCES = ['sandbox', 'lab', 'estate', 'fixture'];
  const ALLOWED_TIERS = ['synthetic', 'observational'];
  const ALLOWED_WORKLOAD_CLASSES = ['light', 'medium', 'heavy', 'power'];
  const ALLOWED_PERCENTILE_KEYS = ['n', 'p10', 'p50', 'p90', 'p95', 'p99', 'min', 'max'];

  const LEAK_PATTERNS = [
    { name: 'GUID', re: /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/ },
    { name: 'Email or UPN', re: /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/ },
    { name: 'IPv4 address', re: /\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b/ },
    { name: 'IPv6 address', re: /(?:[0-9a-f]{1,4}:){2,7}[0-9a-f]{0,4}|::1/i },
    { name: 'Azure resource ID or UNC path', re: /\/subscriptions\/|\/resourcegroups\/|\\\\[a-zA-Z0-9._-]+\\/i }
  ];

  function getGeneratorKind(record) {
    if (record && record.extensions && record.extensions.generator && record.extensions.generator.kind) {
      return record.extensions.generator.kind;
    }
    return 'native';
  }

  function buildCitation(record) {
    if (!record || !record.profile || !record.id) return '';
    const commit = (record.profile.assessCommit || 'cfcc302').slice(0, 7);
    return `avd-assess@${commit}:evidence/${record.profile.id}/${record.id}.json`;
  }

  function filterCorpus(records, filters) {
    const list = Array.isArray(records) ? records : [];
    const f = filters && typeof filters === 'object' ? filters : {};
    return list.filter(function (r) {
      if (!r || !r.profile || !r.environment || r.source === 'fixture') return false;
      if (f.profileId && r.profile.id !== f.profileId) return false;
      if (f.vmSku && r.environment.vmSku !== f.vmSku) return false;
      if (f.osDiskType && r.environment.osDiskType !== f.osDiskType) return false;
      if (f.wdotProfile && r.environment.wdotProfile !== f.wdotProfile) return false;
      if (f.fslogixExclusions && r.environment.fslogixExclusions !== f.fslogixExclusions) return false;
      const genKind = getGeneratorKind(r);
      if (f.generatorKind) {
        if (genKind !== f.generatorKind) return false;
      } else if (!f.includeExternal && genKind !== 'native') {
        return false;
      }
      return true;
    });
  }

  function widthBucketClass(value, maxVal) {
    const max = maxVal > 0 ? maxVal : 100;
    const pct = Math.max(10, Math.min(100, Math.round((Number(value || 0) / max) * 10) * 10));
    return `w-${pct}`;
  }

  function extractDistributionBars(record) {
    if (!record || !record.metrics || !record.profile) return [];
    const m = record.metrics;
    const pid = record.profile.id;
    if (pid === 'multisession-density' && m.inputDelayMs) {
      const d = m.inputDelayMs;
      const max = Math.max(150, d.p95 || 100);
      return [
        { label: 'p50', value: `${d.p50} ms`, bucketClass: widthBucketClass(d.p50, max) },
        { label: 'p90', value: `${d.p90} ms`, bucketClass: widthBucketClass(d.p90, max) },
        { label: 'p95', value: `${d.p95} ms`, bucketClass: widthBucketClass(d.p95, max) }
      ];
    }
    if (pid === 'storage-fslogix-io') {
      const r50 = m.readIops && typeof m.readIops === 'object' ? m.readIops.p50 : m.readIopsP50;
      const r95 = m.readIops && typeof m.readIops === 'object' ? m.readIops.p95 : m.readIopsP95;
      const v95 = m.vhdxAttachMs && typeof m.vhdxAttachMs === 'object' ? m.vhdxAttachMs.p95 : m.vhdxAttachMsP95;
      const max = Math.max(5000, r95 || 1000);
      return [
        { label: 'Read p50', value: `${r50} IOPS`, bucketClass: widthBucketClass(r50, max) },
        { label: 'Read p95', value: `${r95} IOPS`, bucketClass: widthBucketClass(r95, max) },
        { label: 'VHDX p95', value: `${v95} ms`, bucketClass: widthBucketClass(v95, 4000) }
      ];
    }
    if (pid === 'host-logon-storm') {
      const c50 = m.timeToConnectMs && typeof m.timeToConnectMs === 'object' ? m.timeToConnectMs.p50 : m.timeToConnectMsP50;
      const c95 = m.timeToConnectMs && typeof m.timeToConnectMs === 'object' ? m.timeToConnectMs.p95 : m.timeToConnectMsP95;
      const p95 = m.profileLoadMs && typeof m.profileLoadMs === 'object' ? m.profileLoadMs.p95 : m.profileLoadMsP95;
      const max = 35000;
      return [
        { label: 'Conn p50', value: `${c50} ms`, bucketClass: widthBucketClass(c50, max) },
        { label: 'Conn p95', value: `${c95} ms`, bucketClass: widthBucketClass(c95, max) },
        { label: 'Prof p95', value: `${p95} ms`, bucketClass: widthBucketClass(p95, 10000) }
      ];
    }
    if (pid === 'control-plane-autoscale') {
      const b95 = m.coldBootToAvailableSec && typeof m.coldBootToAvailableSec === 'object' ? m.coldBootToAvailableSec.p95 : m.coldBootToAvailableSecP95;
      const w95 = m.startOnConnectWaitSec && typeof m.startOnConnectWaitSec === 'object' ? m.startOnConnectWaitSec.p95 : m.startOnConnectWaitSecP95;
      const d95 = m.drainToDeallocateSec && typeof m.drainToDeallocateSec === 'object' ? m.drainToDeallocateSec.p95 : m.drainToDeallocateSecP95;
      const max = 400;
      return [
        { label: 'Boot p95', value: `${b95} s`, bucketClass: widthBucketClass(b95, max) },
        { label: 'Wake p95', value: `${w95} s`, bucketClass: widthBucketClass(w95, max) },
        { label: 'Drain p95', value: `${d95} s`, bucketClass: widthBucketClass(d95, max) }
      ];
    }
    if (pid === 'bcdr-profile-recovery') {
      const max = 180;
      return [
        { label: 'RTO', value: `${m.measuredRtoMinutes} min`, bucketClass: widthBucketClass(m.measuredRtoMinutes, max) },
        { label: 'RPO', value: `${m.measuredRpoMinutes} min`, bucketClass: widthBucketClass(m.measuredRpoMinutes, max) }
      ];
    }
    if (pid === 'insights-observational') {
      const rtt50 = m.rttMs && typeof m.rttMs === 'object' ? m.rttMs.p50 : 0;
      const rtt95 = m.rttMs && typeof m.rttMs === 'object' ? m.rttMs.p95 : 0;
      const id95 = m.inputDelayMs && typeof m.inputDelayMs === 'object' ? m.inputDelayMs.p95 : 0;
      return [
        { label: 'RTT p50', value: `${rtt50} ms`, bucketClass: widthBucketClass(rtt50, 150) },
        { label: 'RTT p95', value: `${rtt95} ms`, bucketClass: widthBucketClass(rtt95, 150) },
        { label: 'Delay p95', value: `${id95} ms`, bucketClass: widthBucketClass(id95, 150) }
      ];
    }
    if (pid === 'rpa-ui-responsiveness') {
      const launch95 = m.appLaunchMs && typeof m.appLaunchMs === 'object' ? (m.appLaunchMs.p95 ?? m.appLaunchMs.p50 ?? 0) : 0;
      const ready95 = m.windowReadyMs && typeof m.windowReadyMs === 'object' ? (m.windowReadyMs.p95 ?? m.windowReadyMs.p50 ?? 0) : 0;
      const act95 = m.actionLatencyMs && typeof m.actionLatencyMs === 'object' ? (m.actionLatencyMs.p95 ?? m.actionLatencyMs.p50 ?? 0) : 0;
      const id95 = m.inputDelayMs && typeof m.inputDelayMs === 'object' ? (m.inputDelayMs.p95 ?? 0) : 0;
      return [
        { label: 'Launch p95', value: `${launch95} ms`, bucketClass: widthBucketClass(launch95, 2000) },
        { label: 'Ready p95', value: `${ready95} ms`, bucketClass: widthBucketClass(ready95, 1000) },
        { label: 'Action p95', value: `${act95} ms`, bucketClass: widthBucketClass(act95, 500) },
        { label: 'Delay p95', value: `${id95} ms`, bucketClass: widthBucketClass(id95, 150) }
      ];
    }
    return [];
  }

  function compareRecords(recordA, recordB) {
    return [recordA, recordB].filter(Boolean).map(function (r) {
      return {
        id: r.id,
        source: r.source,
        profileId: r.profile.id,
        vmSku: r.environment.vmSku,
        vcpu: r.environment.vcpu,
        memoryGiB: r.environment.memoryGiB,
        osDiskType: r.environment.osDiskType,
        wdotProfile: r.environment.wdotProfile,
        defenderCachePresealed: Boolean(r.environment.defenderCacheMaintained !== undefined ? r.environment.defenderCacheMaintained : r.environment.defenderCachePresealed),
        defenderCacheMaintained: Boolean(r.environment.defenderCacheMaintained !== undefined ? r.environment.defenderCacheMaintained : r.environment.defenderCachePresealed),
        fslogixExclusions: r.environment.fslogixExclusions,
        sampleSessionsBand: r.environment.sampleSessionsBand,
        generatorKind: getGeneratorKind(r),
        generatorPersona: r.extensions && r.extensions.generator ? r.extensions.generator.persona || null : null,
        experienceGate: r.verdict && r.verdict.experienceGate ? r.verdict.experienceGate : 'unknown',
        bars: extractDistributionBars(r),
        citation: buildCitation(r)
      };
    });
  }

  function checkSandboxApproval(mode, approvalText) {
    if (mode !== 'SandboxBatch') {
      return { approved: true, requiresGo: false, reason: 'OfflineFixture and ExistingHostPool modes do not provision new billing resources.' };
    }
    const text = String(approvalText || '').trim();
    const m = text.match(/^go batch ([a-z0-9][a-z0-9-]{1,39}) \$([0-9]+(?:\.[0-9]{1,2})?)$/);
    if (!m || Number(m[2]) <= 0) {
      return {
        approved: false,
        requiresGo: true,
        reason: 'SandboxBatch mode requires exact owner approval matching "go batch <id> $<total>". Defaulting command to OfflineFixture.'
      };
    }
    return { approved: true, requiresGo: true, batchId: m[1], budgetUsd: Number(m[2]), reason: `Approved batch ${m[1]} ($${m[2]}).` };
  }

  function sanitizeToken(val, allowlist, fallback) {
    return allowlist.includes(val) ? val : fallback;
  }

  function buildCommandBlock(opts) {
    const o = opts && typeof opts === 'object' ? opts : {};
    const shell = o.shell === 'bash' ? 'bash' : 'pwsh';
    const profileId = sanitizeToken(o.profileId, ALLOWED_PROFILES, 'multisession-density');
    const workloadClass = sanitizeToken(o.workloadClass, [...ALLOWED_WORKLOAD_CLASSES, 'n/a'], 'medium');
    const vmSku = sanitizeToken(o.vmSku, ALLOWED_VM_SKUS, 'Standard_E4s_v5');
    const osDiskType = sanitizeToken(o.osDiskType, ALLOWED_OS_DISK_TYPES, 'Premium_LRS');
    const wdotProfile = sanitizeToken(o.wdotProfile, ALLOWED_WDOT, 'avd-ops-reviewed-v1');
    const fslogixExclusions = sanitizeToken(o.fslogixExclusions, ALLOWED_EXCLUSIONS, 'full');
    const requestedMode = o.mode === 'SandboxBatch' ? 'SandboxBatch' : o.mode === 'ExistingHostPool' ? 'ExistingHostPool' : 'OfflineFixture';
    const approvalCheck = checkSandboxApproval(requestedMode, o.sandboxBatchApproval);
    const effectiveMode = approvalCheck.approved ? requestedMode : 'OfflineFixture';

    if (shell === 'bash') {
      const lines = [
        'if [ ! -d "$HOME/avd-benchmark" ]; then git clone https://github.com/avd-ops/avd-benchmark.git "$HOME/avd-benchmark"; fi',
        'cd "$HOME/avd-benchmark" && git checkout -q main && git pull -q --ff-only'
      ];
      let cmd = `bash ./scripts/run-benchmark.sh --profile ${profileId} --workload-class ${workloadClass} --vm-sku ${vmSku} --os-disk-type ${osDiskType} --wdot-profile ${wdotProfile} --fslogix-exclusions ${fslogixExclusions} --mode ${effectiveMode}`;
      if (effectiveMode === 'SandboxBatch' && approvalCheck.approved) {
        cmd += ` --sandbox-batch-approval "go batch ${approvalCheck.batchId} $${approvalCheck.budgetUsd}"`;
      }
      lines.push(cmd);
      return { shell: 'bash', effectiveMode, approvalCheck, command: lines.join('\n') };
    }

    const lines = [
      'if (-not (Test-Path ~/avd-benchmark)) { git clone https://github.com/avd-ops/avd-benchmark.git ~/avd-benchmark }',
      'Set-Location ~/avd-benchmark; git checkout -q main; git pull -q --ff-only'
    ];
    let cmd = `pwsh -NoLogo -File ./Invoke-AvdBenchmark.ps1 -ProfileId ${profileId} -WorkloadClass ${workloadClass} -VmSku ${vmSku} -OsDiskType ${osDiskType} -WdotProfile ${wdotProfile} -FslogixExclusions ${fslogixExclusions} -Mode ${effectiveMode}`;
    if (effectiveMode === 'SandboxBatch' && approvalCheck.approved) {
      cmd += ` -SandboxBatchApproval 'go batch ${approvalCheck.batchId} $${approvalCheck.budgetUsd}'`;
    }
    lines.push(cmd);
    return { shell: 'pwsh', effectiveMode, approvalCheck, command: lines.join('\n') };
  }

  function validateC25(input) {
    const errors = [];
    const raw = typeof input === 'string' ? input : JSON.stringify(input || {});
    let doc = null;
    try {
      doc = typeof input === 'string' ? JSON.parse(input) : input;
    } catch (e) {
      return { valid: false, errors: [`Invalid JSON: ${e.message}`], doc: null };
    }
    if (!doc || typeof doc !== 'object' || Array.isArray(doc)) {
      return { valid: false, errors: ['Root value must be a JSON object.'], doc: null };
    }

    for (const pat of LEAK_PATTERNS) {
      if (pat.re.test(raw)) {
        errors.push(`Leak detected: ${pat.name} pattern found in payload.`);
      }
    }
    const domainMatches = raw.match(/\b(?:[a-z0-9-]+\.)+[a-z]{2,}\b/gi) || [];
    for (const d of domainMatches) {
      if (d.toLowerCase() !== 'assess.avd-ops.dev') {
        errors.push('Leak detected: Domain or hostname pattern found in payload.');
        break;
      }
    }

    if (doc.schema !== 'avd-benchmark-result/v1') errors.push('schema must be "avd-benchmark-result/v1".');
    if (!/^bm-[0-9]{8}-[a-z0-9-]+$/.test(String(doc.id || ''))) errors.push('id must match "^bm-YYYYMMDD-<slug>$".');
    if (!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(String(doc.date || ''))) errors.push('date must match "YYYY-MM-DD".');
    if (!ALLOWED_SOURCES.includes(doc.source)) errors.push(`source must be one of: ${ALLOWED_SOURCES.join(', ')}.`);
    if (!ALLOWED_TIERS.includes(doc.tier)) errors.push(`tier must be one of: ${ALLOWED_TIERS.join(', ')}.`);

    const p = doc.profile;
    if (!p || typeof p !== 'object') {
      errors.push('profile object is required.');
    } else {
      if (!ALLOWED_PROFILES.includes(p.id)) errors.push(`profile.id "${p.id}" is not in the closed enum.`);
      if (!/^[0-9]+\.[0-9]+\.[0-9]+$/.test(String(p.version || ''))) errors.push('profile.version must be semver.');
      if (p.workloadClass !== undefined && !ALLOWED_WORKLOAD_CLASSES.includes(p.workloadClass)) {
        errors.push(`profile.workloadClass "${p.workloadClass}" is not in the closed enum.`);
      }
      if (!/^[0-9a-f]{40}$/.test(String(p.assessCommit || ''))) errors.push('profile.assessCommit must be a 40-char hex SHA-1.');
      if (!/^[0-9a-f]{40}$/.test(String(p.benchmarkCommit || ''))) errors.push('profile.benchmarkCommit must be a 40-char hex SHA-1.');
    }

    const env = doc.environment;
    if (!env || typeof env !== 'object') {
      errors.push('environment object is required.');
    } else {
      if (!ALLOWED_VM_SKUS.includes(env.vmSku)) errors.push(`environment.vmSku "${env.vmSku}" is not an allowed public VM SKU.`);
      if (!ALLOWED_OS_DISK_TYPES.includes(env.osDiskType)) errors.push(`environment.osDiskType "${env.osDiskType}" is not in the closed enum.`);
      if (!ALLOWED_OS_IMAGES.includes(env.osImage)) errors.push(`environment.osImage "${env.osImage}" is not in the closed enum.`);
      if (!ALLOWED_WDOT.includes(env.wdotProfile)) errors.push(`environment.wdotProfile "${env.wdotProfile}" is not in the closed enum.`);
      if (!ALLOWED_EXCLUSIONS.includes(env.fslogixExclusions)) errors.push(`environment.fslogixExclusions "${env.fslogixExclusions}" is not in the closed enum.`);
      if (!ALLOWED_JOIN_TYPES.includes(env.joinType)) errors.push(`environment.joinType "${env.joinType}" is not in the closed enum.`);
      if (!ALLOWED_PROFILE_STORAGE.includes(env.profileStorageSku)) errors.push(`environment.profileStorageSku "${env.profileStorageSku}" is not in the closed enum.`);
      if (!ALLOWED_PROFILE_AUTH.includes(env.profileAuth)) errors.push(`environment.profileAuth "${env.profileAuth}" is not in the closed enum.`);
      if (!ALLOWED_SMB_ENC.includes(env.smbChannelEncryption)) errors.push(`environment.smbChannelEncryption "${env.smbChannelEncryption}" is not in the closed enum.`);
      if (!ALLOWED_EGRESS.includes(env.networkEgress)) errors.push(`environment.networkEgress "${env.networkEgress}" is not in the closed enum.`);
      if (!ALLOWED_SAMPLE_BANDS.includes(env.sampleHostsBand)) errors.push('environment.sampleHostsBand must be a banded count (1-2, 3-9, 10-25, 26-100, 100+).');
      if (!ALLOWED_SAMPLE_BANDS.includes(env.sampleSessionsBand)) errors.push('environment.sampleSessionsBand must be a banded count (1-2, 3-9, 10-25, 26-100, 100+).');
    }

    const m = doc.metrics;
    if (!m || typeof m !== 'object' || Array.isArray(m) || Object.keys(m).length === 0) {
      errors.push('metrics object must be non-empty.');
    } else {
      for (const [k, v] of Object.entries(m)) {
        if (Array.isArray(v)) {
          errors.push(`metrics.${k} cannot be a raw array; only aggregate percentiles or scalars are permitted.`);
        } else if (v && typeof v === 'object') {
          for (const subKey of Object.keys(v)) {
            if (!ALLOWED_PERCENTILE_KEYS.includes(subKey)) {
              errors.push(`metrics.${k}.${subKey} is not an allowed percentile key.`);
            }
          }
        }
      }
    }

    const v = doc.verdict;
    if (!v || typeof v !== 'object' || !['pass', 'warn', 'fail'].includes(v.experienceGate)) {
      errors.push('verdict.experienceGate must be pass, warn, or fail.');
    }

    if (doc.extensions && typeof doc.extensions === 'object') {
      for (const ek of Object.keys(doc.extensions)) {
        if (!['generator', 'rpa'].includes(ek)) errors.push(`extensions.${ek} is not an allowed extension namespace.`);
      }
      if (doc.extensions.rpa !== undefined) {
        const rpa = doc.extensions.rpa;
        if (!rpa || typeof rpa !== 'object' || Array.isArray(rpa)) {
          errors.push('extensions.rpa must be an object.');
        } else {
          for (const rk of Object.keys(rpa)) {
            if (!['engine', 'version'].includes(rk)) errors.push(`extensions.rpa.${rk} is not an allowed property.`);
          }
          if (rpa.engine !== 'in-session-uia') errors.push('extensions.rpa.engine must be in-session-uia.');
          if (!/^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$/.test(String(rpa.version || ''))) {
            errors.push('extensions.rpa.version must be semver.');
          }
        }
      }
    }
    if (doc.extensions && typeof doc.extensions === 'object' && doc.extensions.generator !== undefined) {
      const g = doc.extensions.generator;
      if (!g || typeof g !== 'object' || Array.isArray(g)) {
        errors.push('extensions.generator must be an object.');
      } else {
        const allowedGenKeys = ['kind', 'version', 'persona', 'licenseSelfDeclared', 'exportSha256'];
        for (const k of Object.keys(g)) {
          if (!allowedGenKeys.includes(k)) errors.push(`extensions.generator.${k} is not an allowed property.`);
        }
        if (!['native', 'euc-score-byo'].includes(g.kind)) errors.push('extensions.generator.kind must be native or euc-score-byo.');
        if (!/^(?:[0-9]+\.[0-9]+(?:\.[0-9]+)?|unknown)$/.test(String(g.version || ''))) errors.push('extensions.generator.version must be semver or unknown.');
        if (!['author', 'knowledge-worker', 'power-user', 'media-user', 'other'].includes(g.persona)) errors.push('extensions.generator.persona is not in the closed enum.');
        if (g.licenseSelfDeclared !== 'community-public-results') errors.push('extensions.generator.licenseSelfDeclared must be community-public-results.');
        if (!/^[0-9a-f]{64}$/.test(String(g.exportSha256 || ''))) errors.push('extensions.generator.exportSha256 must be a 64-char hex SHA-256.');
      }
    }

    return { valid: errors.length === 0, errors, doc };
  }

  function buildSubmissionIssueUrl(input) {
    const check = validateC25(input);
    if (!check.valid || !check.doc || check.doc.source === 'fixture') return '';
    const doc = check.doc;
    const profileId = doc.profile && doc.profile.id ? doc.profile.id : 'benchmark';
    const src = doc.source;
    const params = new URLSearchParams({
      template: 'baseline-evidence.yml',
      title: `Evidence: ${profileId} ${src}`,
      source: src,
      file: JSON.stringify(doc, null, 2)
    });
    return `https://github.com/avd-ops/avd-assess/issues/new?${params.toString()}`;
  }

  return {
    ALLOWED_PROFILES,
    ALLOWED_VM_SKUS,
    ALLOWED_OS_DISK_TYPES,
    ALLOWED_WDOT,
    ALLOWED_EXCLUSIONS,
    ALLOWED_SAMPLE_BANDS,
    buildCitation,
    filterCorpus,
    extractDistributionBars,
    compareRecords,
    checkSandboxApproval,
    buildCommandBlock,
    validateC25,
    buildSubmissionIssueUrl
  };
});
