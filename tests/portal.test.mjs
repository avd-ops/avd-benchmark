/* Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft. MIT.
   tests/portal.test.mjs: verifies the avd-benchmark Explorer & Runner Portal, vendored design system,
   standalone Cloud Shell command blocks (lesson 0015), C25 corpus, and benchmark-core.js pure functions. */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const read = (f) => readFileSync(join(root, f), 'utf8');
const core = require('../site/portal/benchmark-core.js');

const walk = (dir) => readdirSync(dir).flatMap((name) => {
  const p = join(dir, name);
  return statSync(p).isDirectory() ? walk(p) : [p];
});

test('README and LICENSE keep the avd-ops brand line and research-only warning block', () => {
  assert.match(read('LICENSE'), /^MIT License[\s\S]*PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND/);
  const top = read('README.md').split('\n## ')[0];
  assert.match(top, /Part of \[avd-ops\]\(https:\/\/avd-ops\.dev\/\), the open toolkit for Azure Virtual Desktop\./);
  for (const re of [
    /Personal project\. Research and learning only\. Not for production\. No warranty\./,
    /not affiliated with, endorsed by or supported by my employer, Liquidware or Microsoft/,
    /"as is", without warranty of any kind/,
    /Contributions and forks are welcome and encouraged\./
  ]) {
    assert.match(top, re, `README intro missing ${re}`);
  }
});

test('portal HTML follows all avd-ops portal rules: shell portal class, notice before first h2, no inline styles, no partner/HCL names, credit line', () => {
  const html = read('site/portal/index.html');
  assert.match(html, /<body class="shell portal">/);
  const beforeH2 = html.split('<h2')[0];
  for (const re of [
    /Personal project\. Research and learning only\. Not for production\. No warranty\./,
    /Not affiliated with, endorsed by or supported by my employer/,
    /Don't run any of it in production\./,
    /"as is", without warranty of any kind/,
    /Contributions and forks are welcome and encouraged\./
  ]) {
    assert.match(beforeH2, re, `portal notice before first <h2> missing ${re}`);
  }
  assert.doesNotMatch(html, /<style|\sstyle="|\son[a-z]+\s*=/i, 'no inline styles or event handlers');
  assert.doesNotMatch(html, /<script(?![^>]*\ssrc=)[^>]*>/, 'no inline script blocks');
  assert.match(html, /<p class="credit">A <a href="https:\/\/prignano\.ai\/">prignano\.ai<\/a> production<\/p>/);

  for (const f of ['site/portal/index.html', 'site/portal/portal.css', 'site/portal/benchmark-core.js', 'site/portal/portal.js']) {
    const content = read(f);
    assert.doesNotMatch(content, /liquidware|nerdio|login ?vsi|goliath|terraform|packer|\.tf\b/i, `${f} names partner or HCL tooling`);
    assert.doesNotMatch(content, /[^\x00-\x7e]/, `${f} must stay strictly ASCII`);
  }

  for (const f of ['site/portal/benchmark-core.js', 'site/portal/portal.js']) {
    assert.doesNotMatch(read(f), /\beval\s*\(|new Function|innerHTML|outerHTML|insertAdjacentHTML|document\.write/, `${f} uses unsafe DOM APIs`);
  }
});

test('vendored design system in site/assets/ matches MANIFEST.json hashes and portal.css uses only design-system tokens', () => {
  const manifest = JSON.parse(read('site/assets/MANIFEST.json'));
  const baseCss = read('site/assets/avd-ops.css');
  assert.match(baseCss, new RegExp(`^/\\* avd-ops design system v${manifest.version.replace(/\./g, '\\.')} `));

  for (const [relPath, expectedSha] of Object.entries(manifest.files)) {
    const full = join(root, 'site/assets', relPath);
    assert.ok(existsSync(full), `missing vendored asset ${relPath}`);
    const actualSha = createHash('sha256').update(readFileSync(full)).digest('hex');
    assert.equal(actualSha, expectedSha, `${relPath} hash mismatch`);
  }

  const portalCss = read('site/portal/portal.css');
  assert.doesNotMatch(portalCss, /#[0-9a-fA-F]{3,6}\b|rgba?\(|:root|@font-face/, 'portal.css must use design system tokens only');
  const definedTokens = new Set([...baseCss.matchAll(/(--[\w-]+):/g)].map((m) => m[1]));
  for (const [, token] of portalCss.matchAll(/var\((--[\w-]+)/g)) {
    assert.ok(definedTokens.has(token), `${token} is not defined in avd-ops.css`);
  }

  const html = read('site/portal/index.html');
  for (const [, href] of html.matchAll(/(?:href|src)="([^"]+)"/g)) {
    if (/^(https?:|mailto:|#|\.\/$)/.test(href)) continue;
    const target = join(root, dirname('site/portal/index.html'), href.split('#')[0]);
    assert.ok(existsSync(target), `unresolved relative link ${href}`);
  }
});

test('every command block in HTML and benchmark-core.js stands alone in Cloud Shell (lesson 0015)', () => {
  const html = read('site/portal/index.html');
  for (const [, block] of html.matchAll(/<pre[^>]*>([\s\S]*?)<\/pre>/g)) {
    assert.match(block, /git clone https:\/\/github\.com\/avd-ops\/avd-benchmark\.git/);
    assert.match(block, /Set-Location ~\/avd-benchmark; git checkout -q \w+; git pull -q --ff-only/);
    assert.doesNotMatch(block, /\.\.\.|\\\n/);
  }

  const pwshBlock = core.buildCommandBlock({
    shell: 'pwsh',
    profileId: 'storage-fslogix-io',
    vmSku: 'Standard_D8s_v5',
    osDiskType: 'Ephemeral',
    mode: 'OfflineFixture'
  });
  assert.match(pwshBlock.command, /git clone https:\/\/github\.com\/avd-ops\/avd-benchmark\.git ~\/avd-benchmark/);
  assert.match(pwshBlock.command, /Set-Location ~\/avd-benchmark; git checkout -q main; git pull -q --ff-only/);
  assert.match(pwshBlock.command, /-ProfileId storage-fslogix-io/);
  assert.doesNotMatch(pwshBlock.command, /\.\.\.|\\\n/);

  const bashBlock = core.buildCommandBlock({
    shell: 'bash',
    profileId: 'host-logon-storm',
    vmSku: 'Standard_E4s_v5',
    mode: 'OfflineFixture'
  });
  assert.match(bashBlock.command, /git clone https:\/\/github\.com\/avd-ops\/avd-benchmark\.git "\$HOME\/avd-benchmark"/);
  assert.match(bashBlock.command, /cd "\$HOME\/avd-benchmark" && git checkout -q main && git pull -q --ff-only/);
  assert.match(bashBlock.command, /--profile host-logon-storm/);
  assert.doesNotMatch(bashBlock.command, /\.\.\.|\\\n/);
});

test('benchmark-core.js enforces SandboxBatch approval gate and validates all seeded corpus records', () => {
  const unapproved = core.buildCommandBlock({
    shell: 'pwsh',
    profileId: 'multisession-density',
    mode: 'SandboxBatch',
    sandboxBatchApproval: 'go'
  });
  assert.equal(unapproved.effectiveMode, 'OfflineFixture');
  assert.equal(unapproved.approvalCheck.approved, false);

  const approved = core.buildCommandBlock({
    shell: 'pwsh',
    profileId: 'multisession-density',
    mode: 'SandboxBatch',
    sandboxBatchApproval: 'go batch bm-01 $12.50'
  });
  assert.equal(approved.effectiveMode, 'SandboxBatch');
  assert.equal(approved.approvalCheck.approved, true);
  assert.match(approved.command, /-SandboxBatchApproval 'go batch bm-01 \$12\.5'/);

  const corpus = JSON.parse(read('site/portal/corpus.json'));
  assert.equal(corpus.schema, 'avd-benchmark-corpus/v1');
  assert.equal(corpus.profiles.length, 5);
  assert.ok(corpus.records.length >= 6);

  for (const rec of corpus.records) {
    const check = core.validateC25(rec);
    assert.equal(check.valid, true, `${rec.id} failed validation: ${check.errors.join('; ')}`);
    assert.match(core.buildCitation(rec), /^avd-assess@cfcc302:evidence\/[a-z0-9-]+\/bm-\d{8}-[a-z0-9-]+\.json$/);
  }

  const densityRecords = core.filterCorpus(corpus.records, { profileId: 'multisession-density' });
  assert.equal(densityRecords.length, 2);
  const compared = core.compareRecords(densityRecords[0], densityRecords[1]);
  assert.equal(compared.length, 2);
  assert.equal(compared[0].vmSku, 'Standard_E4s_v5');
  assert.equal(compared[1].vmSku, 'Standard_D8s_v5');
  assert.equal(compared[0].bars.length, 3);

  const issueUrl = core.buildSubmissionIssueUrl(corpus.records[0]);
  assert.match(issueUrl, /^https:\/\/github\.com\/avd-ops\/avd-assess\/issues\/new\?.*template=baseline-evidence\.yml/);

  const dirty = JSON.parse(JSON.stringify(corpus.records[0]));
  dirty.id = 'bm-20261028-123e4567-e89b-12d3-a456-426614174000';
  const dirtyCheck = core.validateC25(dirty);
  assert.equal(dirtyCheck.valid, false);
  assert.match(dirtyCheck.errors.join(' '), /GUID/);
});
