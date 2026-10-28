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
    'control-plane-autoscale',
    'bcdr-profile-recovery'
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

  const ALLOWED_OS_DISK_TYPES = ['Premium_LRS', 'Premium_ZRS', 'Ephemeral', 'StandardSSD_LRS', 'Standard_LRS'];
  const ALLOWED_OS_IMAGES = [
    'win11-24h2-avd-m365',
    'win11-23h2-avd-m365',
    'win11-24h2-avd',
    'winserver-2022-datacenter',
    'winserver-2025-datacenter'
  ];
  const ALLOWED_WDOT = ['avd-ops-reviewed-v1', 'wdot-default', 'none'];
  const ALLOWED_EXCLUSIONS = ['full', 'partial', 'none'];
  const ALLOWED_JOIN_TYPES = ['entra-joined', 'hybrid-entra-joined', 'adds-joined', 'entra-ds-joined'];
  const ALLOWED_PROFILE_STORAGE = [
    'Premium_ZRS',
    'Premium_LRS',
    'Standard_ZRS',
    'Standard_LRS',
    'AzureNetAppFiles_Standard',
    'AzureNetAppFiles_Premium',
    'none'
  ];
  const ALLOWED_PROFILE_AUTH = ['entra-kerberos', 'adds-kerberos', 'entra-ds-kerberos', 'storage-key', 'none'];
  const ALLOWED_SMB_ENC = ['AES-128-GCM+AES-256-GCM', 'AES-128-GCM', 'AES-256-GCM', 'AES-128-CCM', 'unencrypted', 'none'];
  const ALLOWED_EGRESS = ['nat-gateway', 'public-ip', 'azure-firewall', 'nva-forced-tunnel'];
  const ALLOWED_SAMPLE_BANDS = ['1-2', '3-9', '10-25', '26-100', '100+'];
  const ALLOWED_SOURCES = ['sandbox', 'lab', 'estate', 'prior'];
  const ALLOWED_TIERS = ['synthetic', 'observational'];
  const ALLOWED_WORKLOAD_CLASSES = ['light', 'medium', 'heavy', 'power', 'n/a'];
  const ALLOWED_PERCENTILE_KEYS = ['p10', 'p50', 'p90', 'p95', 'p99', 'min', 'max'];

  const LEAK_PATTERNS = [
    { name: 'GUID', re: /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/ },
    { name: 'Email or UPN', re: /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/ },
    { name: 'IPv4 address', re: /\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b/ },
    { name: 'Azure resource ID or UNC path', re: /\/subscriptions\/|\/resourcegroups\/|\\\\[a-zA-Z0-9._-]+\\/i },
    { name: 'Domain or hostname', re: /\b[a-z0-9-]+\.(?:onmicrosoft\.com|contoso\.com|corp|local|internal|windows\.net|azure\.com)\b/i }
  ];

  function buildCitation(record) {
    if (!record || !record.profile || !record.id) return '';
    const commit = (record.profile.assessCommit || 'cfcc302').slice(0, 7);
    return `avd-assess@${commit}:evidence/${record.profile.id}/${record.id}.json`;
  }

  function filterCorpus(records, filters) {
    const list = Array.isArray(records) ? records : [];
    const f = filters && typeof filters === 'object' ? filters : {};
    return list.filter(function (r) {
      if (!r || !r.profile || !r.environment) return false;
      if (f.profileId && r.profile.id !== f.profileId) return false;
      if (f.vmSku && r.environment.vmSku !== f.vmSku) return false;
      if (f.osDiskType && r.environment.osDiskType !== f.osDiskType) return false;
      if (f.wdotProfile && r.environment.wdotProfile !== f.wdotProfile) return false;
      if (f.fslogixExclusions && r.environment.fslogixExclusions !== f.fslogixExclusions) return false;
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
      const max = Math.max(5000, m.readIopsP95 || 1000);
      return [
        { label: 'Read p50', value: `${m.readIopsP50} IOPS`, bucketClass: widthBucketClass(m.readIopsP50, max) },
        { label: 'Read p95', value: `${m.readIopsP95} IOPS`, bucketClass: widthBucketClass(m.readIopsP95, max) },
        { label: 'VHDX p95', value: `${m.vhdxAttachMsP95} ms`, bucketClass: widthBucketClass(m.vhdxAttachMsP95, 4000) }
      ];
    }
    if (pid === 'host-logon-storm') {
      const max = 35000;
      return [
        { label: 'Conn p50', value: `${m.timeToConnectMsP50} ms`, bucketClass: widthBucketClass(m.timeToConnectMsP50, max) },
        { label: 'Conn p95', value: `${m.timeToConnectMsP95} ms`, bucketClass: widthBucketClass(m.timeToConnectMsP95, max) },
        { label: 'Prof p95', value: `${m.profileLoadMsP95} ms`, bucketClass: widthBucketClass(m.profileLoadMsP95, 10000) }
      ];
    }
    if (pid === 'control-plane-autoscale') {
      const max = 400;
      return [
        { label: 'Boot p95', value: `${m.coldBootToAvailableSecP95} s`, bucketClass: widthBucketClass(m.coldBootToAvailableSecP95, max) },
        { label: 'Wake p95', value: `${m.startOnConnectWaitSecP95} s`, bucketClass: widthBucketClass(m.startOnConnectWaitSecP95, max) },
        { label: 'Drain p95', value: `${m.drainToDeallocateSecP95} s`, bucketClass: widthBucketClass(m.drainToDeallocateSecP95, max) }
      ];
    }
    if (pid === 'bcdr-profile-recovery') {
      const max = 180;
      return [
        { label: 'RTO', value: `${m.measuredRtoMinutes} min`, bucketClass: widthBucketClass(m.measuredRtoMinutes, max) },
        { label: 'RPO', value: `${m.measuredRpoMinutes} min`, bucketClass: widthBucketClass(m.measuredRpoMinutes, max) }
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
        defenderCachePresealed: Boolean(r.environment.defenderCachePresealed),
        fslogixExclusions: r.environment.fslogixExclusions,
        sampleSessionsBand: r.environment.sampleSessionsBand,
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
    const workloadClass = sanitizeToken(o.workloadClass, ALLOWED_WORKLOAD_CLASSES, 'medium');
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

    return { valid: errors.length === 0, errors, doc };
  }

  function buildSubmissionIssueUrl(input) {
    const check = validateC25(input);
    if (!check.valid || !check.doc) return '';
    const doc = check.doc;
    const profileId = doc.profile && doc.profile.id ? doc.profile.id : 'benchmark';
    const src = doc.source === 'prior' ? 'sandbox' : doc.source;
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
