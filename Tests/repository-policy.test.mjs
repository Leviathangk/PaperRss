import assert from 'node:assert/strict';
import { access, copyFile, lstat, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { execFile } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const root = fileURLToPath(new URL('../', import.meta.url));

const fromRoot = (path) => resolve(root, path);
const readRepoFile = (path) => readFile(fromRoot(path), 'utf8');
const execFileAsync = promisify(execFile);

// Run the real CLI routing against record-only tools: no compiler, App, or GUI runs.
async function verificationCalls(t, args, inheritedEnv = {}) {
  const fixture = await mkdtemp(join(tmpdir(), 'paperrss-verification-'));
  t.after(() => rm(fixture, { recursive: true, force: true }));
  const scripts = join(fixture, 'scripts');
  const bin = join(fixture, 'bin');
  await Promise.all([mkdir(scripts), mkdir(bin)]);
  await copyFile(fromRoot('scripts/verify.sh'), join(scripts, 'verify.sh'));
  const callsPath = join(fixture, 'calls.jsonl');
  const recorder = `#!${process.execPath}
const { appendFileSync } = require('node:fs');
const { basename } = require('node:path');
appendFileSync(process.env.PAPERRSS_VERIFY_CALLS, JSON.stringify({
  tool: basename(process.argv[1]), args: process.argv.slice(2),
  gui: process.env.PAPERRSS_RUN_GUI_TESTS,
  diagnostics: process.env.PAPERRSS_RUN_MAGAZINE_DIAGNOSTICS,
}) + '\\n');
`;
  for (const tool of ['python3', 'git']) {
    await writeFile(join(bin, tool), recorder, { mode: 0o755 });
  }
  let error;
  try {
    await execFileAsync('/bin/bash', [join(scripts, 'verify.sh'), ...args], {
      env: { ...process.env, ...inheritedEnv, DEVELOPER_DIR: '/fixture/Xcode',
        PATH: `${bin}:${process.env.PATH}`, PAPERRSS_VERIFY_CALLS: callsPath },
    });
  } catch (caught) { error = caught; }
  const records = await readFile(callsPath, 'utf8').catch((caught) => {
    if (caught.code === 'ENOENT') return '';
    throw caught;
  });
  return { calls: records.trim() ? records.trim().split('\n').map(JSON.parse) : [], error };
}

function swiftArgs(calls) {
  const call = calls.find(({ args }) => args.includes('swift'));
  assert.ok(call, 'verification must dispatch Swift tests');
  return call.args.slice(call.args.indexOf('swift'));
}

test('core verification selects only Core tests and clears inherited GUI opt-ins', async (t) => {
  const { calls, error } = await verificationCalls(t, ['--core'], {
    PAPERRSS_RUN_GUI_TESTS: '1', PAPERRSS_RUN_MAGAZINE_DIAGNOSTICS: '1',
  });
  assert.ifError(error);
  const args = swiftArgs(calls);
  const filter = new RegExp(args[args.indexOf('--filter') + 1]);
  assert.ok(filter.test('PaperRssCoreTests.DatabaseSchemaTests/testMigration'));
  assert.equal(filter.test('PaperRssAppTests.MagazineFoldEffectTests/testTurn'), false);
  assert.equal(calls[0].gui, '0');
  assert.equal(calls[0].diagnostics, '0');
});

test('default and all verification retain full Swift, Web, build, and diff coverage without GUI', async (t) => {
  for (const args of [[], ['--all']]) {
    const { calls, error } = await verificationCalls(t, args, {
      PAPERRSS_RUN_GUI_TESTS: '1', PAPERRSS_RUN_MAGAZINE_DIAGNOSTICS: '1',
    });
    assert.ifError(error);
    assert.equal(swiftArgs(calls).includes('--filter'), false);
    assert.ok(calls.some(({ args }) => args.includes('node') && args.includes('--test')));
    assert.ok(calls.some(({ args }) => args.includes('xcodebuild')));
    assert.ok(calls.some(({ tool, args }) => tool === 'git' && args.includes('--check')));
    assert.ok(calls.every(({ gui, diagnostics }) => gui === '0' && diagnostics === '0'));
  }
});

test('feature and custom filter verification do not inherit visible-window permissions', async (t) => {
  for (const args of [['--feature'], ['--filter', 'MagazineFoldEffectTests']]) {
    const { calls, error } = await verificationCalls(t, args, {
      PAPERRSS_RUN_GUI_TESTS: '1', PAPERRSS_RUN_MAGAZINE_DIAGNOSTICS: '1',
    });
    assert.ifError(error);
    assert.equal(calls[0].gui, '0');
    assert.equal(calls[0].diagnostics, '0');
  }
});

test('visible-window regression and diagnostic modes are distinct explicit opt-ins', async (t) => {
  for (const args of [['--gui'], ['--gui', 'MagazineFoldEffectTests/testRepeatedMetalDrawsReleaseDrawableAndLeaveWindowResponsive']]) {
    const { calls, error } = await verificationCalls(t, args, { PAPERRSS_RUN_MAGAZINE_DIAGNOSTICS: '1' });
    assert.ifError(error);
    assert.equal(calls[0].gui, '1');
    assert.equal(calls[0].diagnostics, '0');
    if (args[1]) assert.ok(swiftArgs(calls).includes(args[1]));
  }
  const { calls, error } = await verificationCalls(t, ['--diagnostics']);
  assert.ifError(error);
  assert.equal(calls[0].gui, '1');
  assert.equal(calls[0].diagnostics, '1');
  assert.ok(swiftArgs(calls).includes('MagazineFoldEffectTests/testDiagnoseEdgeLine'));
});

test('malformed verification commands fail before dispatching tools', async (t) => {
  for (const args of [['--filter'], ['--core', '--gui'], ['--unknown']]) {
    const { calls, error } = await verificationCalls(t, args);
    assert.ok(error);
    assert.deepEqual(calls, []);
  }
});

test('App tests route every foreground presentation through the explicit GUI gate', async () => {
  const entries = await readdir(fromRoot('AppTests'), { recursive: true });
  for (const entry of entries.filter((path) => path.endsWith('.swift'))) {
    if (entry === 'VisibleWindowTestSupport.swift') continue;
    const source = await readRepoFile(`AppTests/${entry}`);
    assert.doesNotMatch(source, /\.(?:orderFront|orderFrontRegardless|makeKeyAndOrderFront|activate)\s*\(/,
      `AppTests/${entry}: foreground presentation must use VisibleWindowTestSupport`);
  }
});

async function markdownFiles(path) {
  const absolutePath = fromRoot(path);
  const stat = await lstat(absolutePath);
  if (stat.isFile()) return [absolutePath];

  const entries = await readdir(absolutePath, { withFileTypes: true });
  const nested = await Promise.all(
    entries
      .filter((entry) => entry.isDirectory() || entry.name.endsWith('.md'))
      .map((entry) => markdownFiles(`${path}/${entry.name}`)),
  );
  return nested.flat();
}

test('all agents share one lightweight entry and exactly one principle document', async () => {
  const [agents, claude, principles, ruleFiles] = await Promise.all([
    readRepoFile('AGENTS.md'),
    readRepoFile('CLAUDE.md'),
    readRepoFile('.agents/rules/principle.md'),
    readdir(fromRoot('.agents/rules')),
  ]);

  const expectedPointer = '开始任何工作前，完整读取并遵循 [`.agents/rules/principle.md`](.agents/rules/principle.md)。';
  assert.equal(agents.trim(), expectedPointer);
  assert.equal(claude.trim(), expectedPointer);
  assert.deepEqual(ruleFiles.sort(), ['principle.md']);
  await assert.rejects(access(fromRoot('.agents/README.md')), { code: 'ENOENT' });
  assert.match(principles, /^---\ntrigger: always_on\n---/);
  assert.ok(principles.trim().length > 0);
  assert.doesNotMatch(
    principles,
    /engineering_standards|verification_workflow|privacy_and_docs_hygiene|prompt_design_language|DIRECTORY_SPEC/,
  );
});

test('repository layout keeps source, knowledge, local work, and generated output separate', async () => {
  const requiredPaths = [
    'PaperRss/Sources/Core',
    'PaperRss/Sources/App',
    'PaperRss/Resources',
    'Tests',
    'website',
    'assets',
    'scripts',
    'documents/README.md',
    'documents/features',
    'documents/technical',
    'documents/audits',
    '.agents/rules',
    '.agents/docs',
  ];

  await Promise.all(requiredPaths.map((path) => access(fromRoot(path))));
  for (const retiredPath of [
    'docs',
    'documents/specs',
    'documents/drafts/implemented',
    '.out-of-scope',
  ]) {
    await assert.rejects(access(fromRoot(retiredPath)), { code: 'ENOENT' });
  }

  const gitignore = await readRepoFile('.gitignore');
  for (const ignored of ['.scratch/', '.build/', 'build/', 'dist/']) {
    assert.match(gitignore, new RegExp(`^${ignored.replace('.', '\\.')}$`, 'm'));
  }
});

test('governance markdown uses portable links that resolve inside the repository', async () => {
  const files = [
    fromRoot('AGENTS.md'),
    fromRoot('CLAUDE.md'),
    ...(await markdownFiles('.agents')),
    ...(await markdownFiles('documents')),
  ];

  for (const file of files) {
    const markdown = await readFile(file, 'utf8');
    assert.doesNotMatch(markdown, /\]\(file:\/\//, `${file} contains a file URL link`);

    const links = markdown.matchAll(/\[[^\]]*\]\(([^)]+)\)/g);
    for (const [, rawTarget] of links) {
      if (/^(https?:|mailto:|#)/.test(rawTarget)) continue;
      const target = decodeURIComponent(rawTarget.split('#')[0].split('?')[0]);
      if (!target) continue;
      await access(resolve(dirname(file), target));
    }
  }
});

test('test and deployment configuration follow the documented source roots', async () => {
  const [packageFile, pagesWorkflow] = await Promise.all([
    readRepoFile('Package.swift'),
    readRepoFile('.github/workflows/deploy-pages.yml'),
  ]);

  assert.match(packageFile, /"repository-policy\.test\.mjs"/);
  assert.match(pagesWorkflow, /path:\s*'website'/);
  assert.doesNotMatch(pagesWorkflow, /path:\s*'(?:docs|documents)'/);
});

test('agent assets do not contain absolute user-directory symlinks', async () => {
  const entries = await readdir(fromRoot('.agents'), { recursive: true });

  for (const entry of entries) {
    const stat = await lstat(fromRoot(`.agents/${entry}`));
    if (stat.isSymbolicLink()) {
      assert.fail(`.agents/${entry} must be a portable repository file, not a symlink`);
    }
  }
});

test('release script generates version-focused notes without repetitive marketing copy', async () => {
  const releaseScript = await readRepoFile('scripts/release.sh');
  const publishScript = await readRepoFile('scripts/sparkle/publish_release.sh');

  assert.doesNotMatch(
    releaseScript,
    /原生 macOS 三栏布局 RSS 阅读器/,
    'scripts/release.sh must not contain hardcoded marketing slogans',
  );
  assert.doesNotMatch(
    releaseScript,
    /集成 DeepSeek \/ OpenAI 兼容 API/,
    'scripts/release.sh must not contain hardcoded marketing slogans',
  );
  assert.match(
    publishScript,
    /--notes-file|--title/,
    'publish chain must support custom release notes/title flags',
  );
  assert.match(
    releaseScript,
    /publish_release\.sh/,
    'release.sh publish 子命令必须委托受审计的发布编排器（默认 dry-run）',
  );
});

test('update pipeline keeps Sparkle as the single authority and bans legacy update paths', async () => {
  const sources = ['PaperRss/Sources/App', 'PaperRss/Sources/AppUpdateSupport'];
  for (const dir of sources) {
    const entries = [];
    async function walk(p) {
      for (const e of await readdir(fromRoot(p), { withFileTypes: true })) {
        const rel = `${p}/${e.name}`;
        if (e.isDirectory()) await walk(rel);
        else if (e.name.endsWith('.swift')) entries.push({ rel, text: await readRepoFile(rel) });
      }
    }
    await walk(dir);
    assert.ok(entries.length > 0);

    for (const { rel, text } of entries) {
      assert.doesNotMatch(
        text,
        /SPUStandardUpdaterController|SPUStandardUserDriver/,
        `${rel} 禁止绑定 Sparkle 标准 UI（ADR-0001：唯一入口是左下角胶囊）`,
      );
      assert.doesNotMatch(text, /UpdateCheckService/, `${rel} 旧 GitHub 检查器已由 Sparkle 取代`);
      assert.doesNotMatch(text, /ignoredVersion|ignoreVersion\(/, `${rel} 不允许永久忽略版本`);
      assert.doesNotMatch(text, /ScheduledUpdateReminder/, `${rel} 右上角通知条形态已被否决`);
    }
  }

  // 胶囊是唯一入口：RootView 只挂载一次
  const rootView = await readRepoFile('PaperRss/Sources/App/RootView.swift');
  assert.match(rootView, /UpdateCapsule\(/);
  assert.equal((rootView.match(/UpdateCapsule\(/g) || []).length, 1);

  // 生产 Info.plist 不允许硬编码 feed/公钥（构建期注入，缺键 fail-closed）
  for (const plist of ['PaperRss/Resources/macOS-Info.plist', 'PaperRss/Resources/iOS-Info.plist']) {
    const text = await readRepoFile(plist);
    assert.doesNotMatch(text, /SUFeedURL|SUBetaFeedURL|SUPublicEDKey/, `${plist} 更新配置必须构建期注入`);
  }

  // Package.swift 锁定 Sparkle 版本并排除 node 契约测试
  const packageSwift = await readRepoFile('Package.swift');
  assert.match(packageSwift, /sparkle-project\/Sparkle\.git", exact: "2\.\d+\.\d+"/);
  for (const t of ['sparkle-release.test.mjs','sparkle-release-gates.test.mjs','sparkle-publish-dry-run.test.mjs']) {
    assert.match(packageSwift, new RegExp(`"${t.replace(/\./g,'\\.')}"`));
  }

  // 凭据文件不入库
  const gitignore = await readRepoFile('.gitignore');
  assert.match(gitignore, /release\.env/);
});
