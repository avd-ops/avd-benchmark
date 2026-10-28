/* Personal project, not for production, as is; not affiliated with the author's employer or Microsoft. MIT.
   portal.js: browser wiring for the AVD Benchmark Explorer & Runner Portal (site/portal/index.html). */
(function () {
  'use strict';

  const core = window.BenchmarkCore;
  if (!core) return;

  const STEPS = [
    { id: 'explore', stage: 'Explore', label: '1. Explorer (Compare)' },
    { id: 'run', stage: 'Run', label: '2. Run Harness' },
    { id: 'submit', stage: 'Submit', label: '3. Validate & Submit (C25)' }
  ];

  let currentStep = 0;
  let corpusData = { profiles: [], records: [] };

  function byId(id) {
    return document.getElementById(id);
  }

  function clearChildren(el) {
    while (el && el.firstChild) el.removeChild(el.firstChild);
  }

  function renderStepper() {
    const list = byId('steps');
    const bar = byId('steps-bar');
    clearChildren(list);
    clearChildren(bar);

    STEPS.forEach(function (s, idx) {
      const li = document.createElement('li');
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'step';
      if (idx === currentStep) btn.setAttribute('aria-current', 'step');
      const num = document.createElement('span');
      num.className = 'n';
      num.textContent = String(idx + 1);
      const txt = document.createElement('span');
      txt.textContent = s.label;
      btn.appendChild(num);
      btn.appendChild(txt);
      btn.addEventListener('click', function () {
        showStep(idx);
      });
      li.appendChild(btn);
      list.appendChild(li);

      const phaseLi = document.createElement('li');
      phaseLi.className = idx === currentStep ? 'phase now' : 'phase';
      const pName = document.createElement('span');
      pName.className = 'phase-name';
      pName.textContent = s.stage;
      const segs = document.createElement('div');
      segs.className = 'segs';
      const segBtn = document.createElement('button');
      segBtn.type = 'button';
      segBtn.className = idx === currentStep ? 'seg current' : 'seg';
      segBtn.setAttribute('aria-label', s.label);
      segBtn.addEventListener('click', function () {
        showStep(idx);
      });
      segs.appendChild(segBtn);
      phaseLi.appendChild(pName);
      phaseLi.appendChild(segs);
      bar.appendChild(phaseLi);
    });

    STEPS.forEach(function (s, idx) {
      const sec = byId(`stage-${s.id}`);
      if (sec) sec.classList.toggle('hidden', idx !== currentStep);
    });

    const backBtn = byId('back');
    const nextBtn = byId('next');
    const where = byId('where');
    if (backBtn) backBtn.disabled = currentStep === 0;
    if (nextBtn) nextBtn.disabled = currentStep === STEPS.length - 1;
    if (where) where.textContent = `Step ${currentStep + 1} of ${STEPS.length}: ${STEPS[currentStep].label}`;
  }

  function showStep(idx) {
    if (idx < 0 || idx >= STEPS.length) return;
    currentStep = idx;
    renderStepper();
  }

  function renderComparison() {
    const profileId = byId('filter-profile') ? byId('filter-profile').value : 'multisession-density';
    const skuA = byId('compare-sku-a') ? byId('compare-sku-a').value : '';
    const skuB = byId('compare-sku-b') ? byId('compare-sku-b').value : '';
    const diskFilter = byId('filter-disk') ? byId('filter-disk').value : '';
    const wdotFilter = byId('filter-wdot') ? byId('filter-wdot').value : '';

    const matching = core.filterCorpus(corpusData.records, {
      profileId: profileId,
      osDiskType: diskFilter,
      wdotProfile: wdotFilter
    });

    const recA = matching.find(function (r) { return !skuA || r.environment.vmSku === skuA; }) || matching[0] || null;
    const recB = matching.find(function (r) { return r !== recA && (!skuB || r.environment.vmSku === skuB); }) || matching[1] || null;

    const cards = core.compareRecords(recA, recB);
    const grid = byId('compare-grid');
    clearChildren(grid);

    if (cards.length === 0) {
      const empty = document.createElement('p');
      empty.className = 'muted';
      empty.textContent = 'No corpus records match the selected filters.';
      grid.appendChild(empty);
      return;
    }

    cards.forEach(function (c) {
      const card = document.createElement('article');
      card.className = 'compare-card';

      const h3 = document.createElement('h3');
      h3.textContent = `${c.vmSku} (${c.vcpu} vCPU, ${c.memoryGiB} GiB)`;
      card.appendChild(h3);

      const meta = document.createElement('p');
      meta.className = 'compare-meta';
      meta.textContent = `OS disk: ${c.osDiskType} | WDOT: ${c.wdotProfile} | Defender pre-seal: ${c.defenderCachePresealed ? 'on' : 'off'} | FSLogix exclusions: ${c.fslogixExclusions} | Sessions band: ${c.sampleSessionsBand} | Source: ${c.source}`;
      card.appendChild(meta);

      const pill = document.createElement('span');
      pill.className = `outcome o-${c.experienceGate === 'pass' ? 'pass' : c.experienceGate === 'warn' ? 'warn' : 'gap'}`;
      pill.textContent = `Experience gate: ${c.experienceGate}`;
      card.appendChild(pill);

      const ul = document.createElement('ul');
      ul.className = 'bar-list';
      c.bars.forEach(function (b) {
        const li = document.createElement('li');
        li.className = 'bar-row';
        const lbl = document.createElement('span');
        lbl.textContent = b.label;
        const track = document.createElement('span');
        track.className = 'bar-track';
        const fill = document.createElement('span');
        fill.className = `bar-fill ${b.bucketClass}`;
        track.appendChild(fill);
        const val = document.createElement('span');
        val.textContent = b.value;
        li.appendChild(lbl);
        li.appendChild(track);
        li.appendChild(val);
        ul.appendChild(li);
      });
      card.appendChild(ul);

      const citeBox = document.createElement('div');
      citeBox.className = 'cite-box';
      citeBox.textContent = c.citation;
      card.appendChild(citeBox);

      const act = document.createElement('div');
      act.className = 'actions';
      const copyBtn = document.createElement('button');
      copyBtn.type = 'button';
      copyBtn.className = 'secondary';
      copyBtn.textContent = 'Copy citation';
      copyBtn.addEventListener('click', function () {
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(c.citation);
          copyBtn.textContent = 'Copied';
        }
      });
      act.appendChild(copyBtn);
      card.appendChild(act);

      grid.appendChild(card);
    });
  }

  function updateRunCommand() {
    const shellEl = document.querySelector('input[name="run-shell"]:checked');
    const shell = shellEl ? shellEl.value : 'pwsh';
    const profileId = byId('run-profile') ? byId('run-profile').value : 'multisession-density';
    const workloadClass = byId('run-workload') ? byId('run-workload').value : 'medium';
    const vmSku = byId('run-sku') ? byId('run-sku').value : 'Standard_E4s_v5';
    const osDiskType = byId('run-disk') ? byId('run-disk').value : 'Premium_LRS';
    const wdotProfile = byId('run-wdot') ? byId('run-wdot').value : 'avd-ops-reviewed-v1';
    const fslogixExclusions = byId('run-exclusions') ? byId('run-exclusions').value : 'full';
    const mode = byId('run-mode') ? byId('run-mode').value : 'OfflineFixture';
    const approval = byId('run-approval') ? byId('run-approval').value : '';

    const out = core.buildCommandBlock({
      shell: shell,
      profileId: profileId,
      workloadClass: workloadClass,
      vmSku: vmSku,
      osDiskType: osDiskType,
      wdotProfile: wdotProfile,
      fslogixExclusions: fslogixExclusions,
      mode: mode,
      sandboxBatchApproval: approval
    });

    const pre = byId('run-cmd');
    if (pre) pre.textContent = out.command;
    const term = byId('run-term');
    if (term) term.setAttribute('data-shell', out.shell);
    const note = byId('run-approval-note');
    if (note) {
      note.textContent = out.approvalCheck.reason;
      note.hidden = !out.approvalCheck.requiresGo;
    }
  }

  function runValidation() {
    const raw = byId('c25-input') ? byId('c25-input').value : '';
    const res = core.validateC25(raw);
    const statusBox = byId('c25-result');
    const submitLink = byId('c25-submit-link');
    clearChildren(statusBox);

    if (res.valid) {
      const reply = document.createElement('div');
      reply.className = 'reply';
      const bl = document.createElement('p');
      bl.className = 'bl good';
      bl.textContent = `Valid C25 benchmark result (${res.doc.id}). Zero leaks detected.`;
      const cite = document.createElement('p');
      cite.className = 'muted';
      cite.textContent = `Citation: ${core.buildCitation(res.doc)}`;
      reply.appendChild(bl);
      reply.appendChild(cite);
      statusBox.appendChild(reply);
      if (submitLink) {
        submitLink.href = core.buildSubmissionIssueUrl(res.doc);
        submitLink.classList.remove('hidden');
      }
    } else {
      const errBox = document.createElement('div');
      errBox.className = 'errors';
      const strong = document.createElement('strong');
      strong.textContent = 'C25 validation failed:';
      const ul = document.createElement('ul');
      res.errors.forEach(function (e) {
        const li = document.createElement('li');
        li.textContent = e;
        ul.appendChild(li);
      });
      errBox.appendChild(strong);
      errBox.appendChild(ul);
      statusBox.appendChild(errBox);
      if (submitLink) {
        submitLink.href = '#';
        submitLink.classList.add('hidden');
      }
    }
  }

  function init() {
    renderStepper();

    const backBtn = byId('back');
    const nextBtn = byId('next');
    if (backBtn) backBtn.addEventListener('click', function () { showStep(currentStep - 1); });
    if (nextBtn) nextBtn.addEventListener('click', function () { showStep(currentStep + 1); });

    ['filter-profile', 'compare-sku-a', 'compare-sku-b', 'filter-disk', 'filter-wdot'].forEach(function (id) {
      const el = byId(id);
      if (el) el.addEventListener('change', renderComparison);
    });

    ['run-profile', 'run-workload', 'run-sku', 'run-disk', 'run-wdot', 'run-exclusions', 'run-mode', 'run-approval'].forEach(function (id) {
      const el = byId(id);
      if (el) {
        el.addEventListener('change', updateRunCommand);
        el.addEventListener('input', updateRunCommand);
      }
    });
    document.querySelectorAll('input[name="run-shell"]').forEach(function (el) {
      el.addEventListener('change', updateRunCommand);
    });

    const copyCmdBtn = byId('copy-run-cmd');
    if (copyCmdBtn) {
      copyCmdBtn.addEventListener('click', function () {
        const pre = byId('run-cmd');
        if (pre && navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(pre.textContent || '');
          copyCmdBtn.textContent = 'Copied';
        }
      });
    }

    const validateBtn = byId('c25-validate-btn');
    if (validateBtn) validateBtn.addEventListener('click', runValidation);

    const loadSampleBtn = byId('c25-load-sample');
    if (loadSampleBtn) {
      loadSampleBtn.addEventListener('click', function () {
        const sample = corpusData.records[0];
        if (sample && byId('c25-input')) {
          byId('c25-input').value = JSON.stringify(sample, null, 2);
          runValidation();
        }
      });
    }

    fetch('corpus.json')
      .then(function (r) { return r.json(); })
      .then(function (data) {
        corpusData = data;
        renderComparison();
      })
      .catch(function () {
        renderComparison();
      });

    updateRunCommand();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
