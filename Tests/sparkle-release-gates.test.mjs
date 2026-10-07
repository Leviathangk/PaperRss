import assert from 'node:assert/strict';
import test from 'node:test';
import { execFileSync, spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, existsSync, readFileSync, chmodSync, cpSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const SPARKLE = join(ROOT, 'scripts', 'sparkle');

/**
 * 假二进制契约测试：用受控 fake 替换 Apple 工具链，逐个触发失败点，断言：
 *  1) 脚本立即非零退出并输出 [FAIL]；
 *  2) 失败之后的步骤不再执行（调用序列截断）；
 *  3) skip-notarization 模式绝不调用公证/Staple 工具。
 */

function writeFake(bin, name, body) {
  const p = join(bin, name);
  // 先记录调用序列，再执行受控行为；失败也留痕。
  writeFileSync(p, `#!/bin/sh\n[ -n "$FAKE_CALLS" ] && printf '%s\\n' "${name} $*" >> "$FAKE_CALLS"\n${body}\n`);
  chmodSync(p, 0o755);
}

const CODESIGN_OK = `
case "\$1" in
  --verify) exit 0 ;;
  -dv|-dvv)
    echo "CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+0 location=embedded"
    echo "Authority=Developer ID Application: Test (TEAM)"
    echo "TeamIdentifier=TEAM";;
  --entitlements) echo "{}";;
esac
exit 0`;

const EXPORT_MKAPP = `
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-exportPath" ]; then mkdir -p "\$a/PaperRss.app/Contents/MacOS"; fi
  prev="\$a"
done
exit 0`;

const CREATE_DMG_TOUCH = `
for a in "\$@"; do case "\$a" in *.dmg) : > "\$a";; esac; done
exit 0`;

function makeFakeBin(behavior = {}) {
  const bin = mkdtempSync(join(tmpdir(), 'fakebin-'));
  const defaults = {
    xcodebuild: EXPORT_MKAPP,
    codesign: CODESIGN_OK,
    spctl: 'echo "accepted"\necho "source=Notarized Developer ID"',
    security: 'echo \'1) AAAA1111 "Developer ID Application: Test (TEAM)"\'',
    stapler: ':;',
    hdiutil: ':;',
    ditto: ':;',
    'create-dmg': CREATE_DMG_TOUCH,
    notarytool: 'echo "Inserted distribution ID: 11111111-2222-3333-4444-555555555555"\necho "status: Accepted"',
    open: 'echo "unexpected GUI launch" >&2; exit 91',
    pgrep: 'echo "unexpected process lookup" >&2; exit 92',
    pkill: 'echo "unexpected process cleanup" >&2; exit 93',
  };
  // 脚本通过 `xcrun notarytool|stapler …` 调用：shim 路由回同目录 fake
  writeFake(bin, 'xcrun', `
tool="$1"; shift
case "$tool" in
  notarytool|stapler|hdiutil|codesign) exec "$(dirname "$0")/$tool" "$@" ;;
esac
echo "unexpected xcrun $tool" >&2; exit 127
`);  for (const [name, body] of Object.entries({ ...defaults, ...behavior })) {
    if (body === false) continue;
    writeFake(bin, name, body);
  }
  return bin;
}

function run(script, args, extraEnv = {}) {
  return execFileSync('bash', [script, ...args], {
    cwd: ROOT,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    env: {
      ...process.env,
      FAKE_CALLS: extraEnv.FAKE_CALLS ?? '',
      PAPERRSS_RUN_LAUNCH_SMOKE: '',
      PAPERRSS_SKIP_LAUNCH_SMOKE: '',
      ...extraEnv,
    },
  });
}

function runExpectFailure(script, args, extraEnv = {}) {
  let out = '';
  try {
    run(script, args, extraEnv);
  } catch (error) {
    out = `${error.stdout || ''}\n${error.stderr || ''}`;
    assert.match(out, /\[FAIL\]/, '失败输出必须包含 [FAIL]');
    return out;
  }
  assert.fail('脚本应当失败退出');
}

function withSandbox(callback) {
  const dir = mkdtempSync(join(tmpdir(), 'gates-'));
  const calls = join(dir, 'calls.log');
  writeFileSync(calls, '');
  const app = join(dir, 'PaperRss.app');
  mkdirSync(join(app, 'Contents', 'MacOS'), { recursive: true });
  writeFileSync(join(app, 'Contents', 'Info.plist'), '<?xml version="1.0"?><plist version="1.0"><dict/></plist>');
  const archive = join(dir, 'PaperRss.xcarchive');
  const bins = [];
  try {
    callback({
      dir, calls, app, archive,
      makeBin(behavior) { const b = makeFakeBin(behavior); bins.push(b); return b; },
      newCalls(name) {
        const p = join(dir, name);
        writeFileSync(p, '');
        return p;
      },
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
    for (const b of bins) rmSync(b, { recursive: true, force: true });
  }
}

const NOTARIZE_ARGS = (dir, archive) => [
  '--archive', archive,
  '--output-dir', join(dir, 'out'),
  '--team-id', 'TEAM',
  '--notary-profile', 'prof',
];

test('export_and_notarize 全链路：导出→签名门禁→公证→Staple 依次 PASS', () => {
  withSandbox(({ dir, archive, makeBin, calls }) => {
    const bin = makeBin({});
    const out = run(join(SPARKLE, 'export_and_notarize.sh'), NOTARIZE_ARGS(dir, archive), {
      PATH: `${bin}:${process.env.PATH}`,
      FAKE_CALLS: calls,
    });
    assert.match(out, /\[PASS 3\]/);
    assert.match(out, /\[PASS 4\][^\n]*Developer ID[^\n]*Hardened Runtime/);
    assert.match(out, /\[PASS 5\][^\n]*Accepted/);
    assert.match(out, /\[PASS 6\]/);
    assert.match(out, /\[SKIP\] 启动冒烟未验证/);
    assert.doesNotMatch(out, /\[PASS 4b\]/);
    assert.doesNotMatch(readFileSync(calls, 'utf8'), /^(open|pgrep|pkill) /m);
    assert.equal(out.trim().split('\n').pop(), join(dir, 'out', 'PaperRss.app'));
  });
});

test('显式 SKIP 优先于 RUN：导出不拉起 App，也不查找或清理用户进程', () => {
  withSandbox(({ dir, archive, makeBin, calls }) => {
    const bin = makeBin({});
    const out = run(join(SPARKLE, 'export_and_notarize.sh'), NOTARIZE_ARGS(dir, archive), {
      PATH: `${bin}:${process.env.PATH}`,
      FAKE_CALLS: calls,
      PAPERRSS_RUN_LAUNCH_SMOKE: '1',
      PAPERRSS_SKIP_LAUNCH_SMOKE: '1',
    });
    assert.match(out, /\[SKIP\] 启动冒烟未验证.*SKIP_LAUNCH_SMOKE 优先/);
    assert.doesNotMatch(readFileSync(calls, 'utf8'), /^(open|pgrep|pkill) /m);
  });
});

function smokeFixture(dir, makeBin, source) {
  const executable = join(dir, 'fake-smoke-app');
  writeFileSync(executable, `#!/usr/bin/env node\n${source}\n`);
  chmodSync(executable, 0o755);
  const bin = makeBin({ xcodebuild: `
prev=""
for a in "$@"; do
  if [ "$prev" = "-exportPath" ]; then
    mkdir -p "$a/PaperRss.app/Contents/MacOS"
    cp "$FAKE_SMOKE_SOURCE" "$a/PaperRss.app/Contents/MacOS/PaperRss"
  fi
  prev="$a"
done
` });
  return { PATH: `${bin}:${process.env.PATH}`, FAKE_SMOKE_SOURCE: executable, PAPERRSS_RUN_LAUNCH_SMOKE: '1' };
}

test('显式冒烟使用临时数据目录，完整观察 3 秒并只清理本次 PID', () => {
  withSandbox(({ dir, archive, makeBin, calls }) => {
    const record = join(dir, 'smoke.json');
    const unrelated = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { stdio: 'ignore' });
    const env = smokeFixture(dir, makeBin, `
const { writeFileSync } = require('node:fs');
writeFileSync(process.env.FAKE_SMOKE_RECORD, JSON.stringify({ pid: process.pid, home: process.env.CFFIXED_USER_HOME, started: Date.now() }));
setInterval(() => {}, 1000);
`);
    try {
      const out = run(join(SPARKLE, 'export_and_notarize.sh'), NOTARIZE_ARGS(dir, archive), {
        ...env, FAKE_CALLS: calls, FAKE_SMOKE_RECORD: record,
      });
      const { pid, home, started } = JSON.parse(readFileSync(record, 'utf8'));
      assert.ok(Date.now() - started >= 2900, '不能在首次发现进程存活后提前通过');
      assert.ok(home && home !== process.env.HOME && home !== process.env.CFFIXED_USER_HOME);
      assert.match(home, /paperrss-notary\..*\/launch-smoke-home$/);
      assert.equal(existsSync(home), false, '退出时清理本次临时数据');
      assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' }, '本次进程已结束');
      assert.doesNotThrow(() => process.kill(unrelated.pid, 0), '其他进程仍存活');
      assert.match(out, /\[PASS 4b\].*完整存活 3 秒.*本次 PID/);
      assert.doesNotMatch(readFileSync(calls, 'utf8'), /^(open|pgrep|pkill) /m);
    } finally {
      unrelated.kill();
    }
  });
});

test('冒烟在 3 秒内退出则失败，保留日志且不进入公证', () => {
  withSandbox(({ dir, archive, makeBin, calls }) => {
    const env = smokeFixture(dir, makeBin, 'console.error("fixture early exit"); setTimeout(() => process.exit(0), 1000);');
    const out = runExpectFailure(join(SPARKLE, 'export_and_notarize.sh'), NOTARIZE_ARGS(dir, archive), {
      ...env, FAKE_CALLS: calls,
    });
    assert.match(out, /未存活完整 3 秒/);
    assert.match(readFileSync(join(dir, 'out', 'launch-smoke.log'), 'utf8'), /fixture early exit/);
    assert.doesNotMatch(readFileSync(calls, 'utf8'), /^(notarytool|stapler|open|pgrep|pkill) /m);
  });
});

test('build_dmg 只代理本地 build，兼容直接参数与显式子命令', () => {
  withSandbox(({ dir, calls }) => {
    const scripts = join(dir, 'scripts');
    mkdirSync(scripts);
    const wrapper = join(scripts, 'build_dmg.sh');
    cpSync(join(ROOT, 'scripts', 'build_dmg.sh'), wrapper);
    writeFake(scripts, 'release.sh', 'exit 0');
    const env = { FAKE_CALLS: calls };
    assert.match(run(wrapper, [], env), /无参数.*只显示/);
    assert.equal(readFileSync(calls, 'utf8'), '', '无参数不得触发构建或发布');
    assert.match(run(wrapper, ['--help'], env), /仅生成本地产物/);
    assert.match(run(wrapper, ['build', '--help'], env), /仅生成本地产物/);
    assert.match(run(wrapper, ['build'], env), /无参数.*只显示/);
    run(wrapper, ['--version', '9.9.9', '--build', '42'], env);
    run(wrapper, ['build', '--version', '9.9.9', '--build', '43'], env);
    assert.equal(readFileSync(calls, 'utf8'),
      'release.sh build --version 9.9.9 --build 42\nrelease.sh build --version 9.9.9 --build 43\n');
    assert.throws(() => run(wrapper, ['publish'], env), { status: 2 });
    assert.throws(() => run(wrapper, ['verify'], env), { status: 2 });
    assert.doesNotMatch(readFileSync(calls, 'utf8'), /--local|publish|verify/);
  });
});

test('release 提示的 publish 命令包含必填参数，重复执行使用新计划目录', () => {
  withSandbox(({ dir, calls }) => {
    const source = readFileSync(join(ROOT, 'scripts', 'release.sh'), 'utf8');
    const start = source.indexOf('  echo "下一步:"');
    const end = source.indexOf('  exit 0', start);
    assert.ok(start >= 0 && end > start);
    const scripts = join(dir, 'scripts');
    mkdirSync(scripts);
    writeFake(scripts, 'release.sh', 'exit 0');
    const releaseDir = join(dir, 'release with spaces');
    mkdirSync(releaseDir);
    const output = execFileSync('bash', ['-c', source.slice(start, end)], {
      cwd: dir, encoding: 'utf8',
      env: { ...process.env, MANIFEST_PATH: join(releaseDir, 'manifest.json'), TAG: 'v9.9.9', CHANNEL: 'stable', RELEASE_DIR: releaseDir },
    });
    const command = output.split('\n').find((line) => line.includes('release.sh publish'));
    assert.ok(command);
    assert.match(command, /--output-dir/);
    for (let index = 0; index < 2; index += 1) {
      execFileSync('bash', ['-c', command], { cwd: dir, env: { ...process.env, FAKE_CALLS: calls } });
    }
    const plans = readFileSync(calls, 'utf8').trim().split('\n').map((line) => line.split('--output-dir ')[1]);
    assert.equal(plans.length, 2);
    assert.notEqual(plans[0], plans[1]);
    assert.ok(plans.every((path) => existsSync(path)));
  });
});

test('export_and_notarize 支持不依赖钥匙串的 App Store Connect API Key', () => {
  withSandbox(({ dir, archive, makeBin, newCalls }) => {
    const key = join(dir, 'AuthKey_TEST.p8');
    const calls = newCalls('direct-key-calls.log');
    writeFileSync(key, 'fixture-private-key');
    const bin = makeBin({});
    const out = run(join(SPARKLE, 'export_and_notarize.sh'), [
      '--archive', archive,
      '--output-dir', join(dir, 'out'),
      '--team-id', 'TEAM',
    ], {
      PATH: `${bin}:${process.env.PATH}`,
      FAKE_CALLS: calls,
      PAPERRSS_NOTARY_KEY: key,
      PAPERRSS_NOTARY_KEY_ID: 'KEYID12345',
      PAPERRSS_NOTARY_ISSUER: '11111111-2222-3333-4444-555555555555',
    });
    assert.match(out, /\[PASS 5\][^\n]*Accepted/);
    const log = readFileSync(calls, 'utf8');
    assert.match(log, new RegExp(`notarytool submit .*--key ${key}`));
    assert.match(log, /--key-id KEYID12345/);
    assert.match(log, /--issuer 11111111-2222-3333-4444-555555555555/);
    assert.doesNotMatch(log, /--keychain-profile/);
  });
});

test('codesign 校验失败 → 立即终止，且不进入公证与 Staple', () => {
  withSandbox(({ dir, archive, makeBin }) => {
    const bin = makeBin({
      codesign: 'if [ "$1" = "--verify" ]; then echo invalid >&2; exit 1; fi\nexit 0',
      notarytool: false,
    });
    const out = runExpectFailure(
      join(SPARKLE, 'export_and_notarize.sh'), NOTARIZE_ARGS(dir, archive),
      { PATH: `${bin}:${process.env.PATH}` });
    assert.match(out, /\[PASS 3\]/, '导出应已成功');
    assert.doesNotMatch(out, /\[PASS 5\]|\[PASS 6\]/);
  });
});

test('公证前不做 spctl 评估（未公证 Developer ID 被拒是预期），Staple 后必须复验', () => {
  withSandbox(({ dir, archive, makeBin, newCalls }) => {
    // stapler validate 失败 → FAIL（此时公证已完成，资产不得流出）
    const bin = makeBin({
      stapler: 'if [ "$1" = "validate" ]; then echo "invalid staple" >&2; exit 1; fi',
    });
    runExpectFailure(
      join(SPARKLE, 'export_and_notarize.sh'), NOTARIZE_ARGS(dir, archive),
      { PATH: `${bin}:${process.env.PATH}` });

    // happy path 中 spctl 只应在公证/Staple 之后被调用（调用序列断言）
    const calls2 = newCalls('calls-order.log');
    const bin2 = makeBin({});
    run(join(SPARKLE, 'export_and_notarize.sh'), NOTARIZE_ARGS(dir, archive),
      { PATH: `${bin2}:${process.env.PATH}`, FAKE_CALLS: calls2 });
    const log = readFileSync(calls2, 'utf8').trim().split('\n');
    const firstSpctl = log.findIndex((l) => l.startsWith('spctl'));
    const notaryIdx = log.findIndex((l) => l.startsWith('notarytool'));
    const stapleIdx = log.findIndex((l) => l.startsWith('stapler'));
    assert.ok(notaryIdx > -1 && stapleIdx > -1);
    assert.ok(firstSpctl > stapleIdx, 'spctl 只允许在 Staple 之后做 Gatekeeper 复验');
  });
});

test('公证 Rejected → FAIL；skip 模式则完全绕开公证与 Staple', () => {
  withSandbox(({ dir, archive, makeBin, newCalls }) => {
    const bin = makeBin({ notarytool: 'echo "status: Rejected"\nexit 1' });
    runExpectFailure(
      join(SPARKLE, 'export_and_notarize.sh'), NOTARIZE_ARGS(dir, archive),
      { PATH: `${bin}:${process.env.PATH}` });

    const calls2 = newCalls('calls2.log');
    const bin2 = makeBin({});
    // 重建 bin2 但去掉 notarytool/stapler，验证 skip 模式零调用
    rmSync(join(bin2, 'notarytool'), { force: true });
    rmSync(join(bin2, 'stapler'), { force: true });
    const out = run(join(SPARKLE, 'export_and_notarize.sh'),
      ['--archive', archive, '--output-dir', join(dir, 'out2'), '--team-id', 'T', '--skip-notarization'],
      { PATH: `${bin2}:${process.env.PATH}`, FAKE_CALLS: calls2 });
    assert.match(out, /\[SKIP\] \[PASS 5\]/);
    assert.match(out, /\[SKIP\] \[PASS 6\]/);
    const log = readFileSync(calls2, 'utf8');
    assert.doesNotMatch(log, /notarytool/);
    assert.doesNotMatch(log, /stapler/);
  });
});

test('make_release_dmg：skip 模式产出 DMG；hdiutil verify 失败则 FAIL', () => {
  withSandbox(({ dir, app, makeBin, newCalls }) => {
    const dmg = join(dir, 'PaperRss-v9.9.9.dmg');
    const bin = makeBin({ notarytool: false });
    const out = run(join(SPARKLE, 'make_release_dmg.sh'), [
      '--app', app, '--output', dmg, '--version', '9.9.9', '--skip-notarization',
    ], { PATH: `${bin}:${process.env.PATH}` });
    assert.match(out, /\[PASS 7\]/);
    assert.match(out, /\[SKIP\] \[PASS 8\]/);
    assert.equal(existsSync(dmg), true);

    const calls2 = newCalls('calls-dmg.log');
    const bin2 = makeBin({
      hdiutil: 'if [ "$1" = "verify" ]; then exit 1; fi',
      'create-dmg': CREATE_DMG_TOUCH,
    });
    runExpectFailure(join(SPARKLE, 'make_release_dmg.sh'), [
      '--app', app, '--output', join(dir, 'b.dmg'), '--version', '9.9.9',
      '--notary-profile', 'p',
    ], { PATH: `${bin2}:${process.env.PATH}` });
  });
});

test('build_with_provenance：缺参 fail-fast；版本不一致拒绝出归档', () => {
  withSandbox(({ dir, archive, makeBin }) => {
    const bin = makeBin({ xcodebuild: ':;' });
    const head = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: ROOT, encoding: 'utf8' }).trim();
    runExpectFailure(join(SPARKLE, 'build_with_provenance.sh'), [
      '--archive-path', archive,
    ], { PATH: `${bin}:${process.env.PATH}` });

    // 预置错误版本的 Info.plist，验证回读校验 fail-closed
    const infoDir = join(archive, 'Products', 'Applications', 'PaperRss.app', 'Contents');
    mkdirSync(infoDir, { recursive: true });
    writeFileSync(join(infoDir, 'Info.plist'),
      '<?xml version="1.0"?><plist version="1.0"><dict>' +
      '<key>CFBundleShortVersionString</key><string>0.0.0</string>' +
      '<key>CFBundleVersion</key><string>7</string>' +
      '<key>SUFeedURL</key><string>https://feed.example/stable.xml</string>' +
      '<key>SUPublicEDKey</key><string>PUBKEY</string>' +
      `<key>PaperRssSourceCommit</key><string>${head}</string>` +
      '</dict></plist>');
    const out = runExpectFailure(join(SPARKLE, 'build_with_provenance.sh'), [
      '--archive-path', archive,
      '--version', '9.9.9', '--build', '7',
      '--feed-url-stable', 'https://feed.example/stable.xml',
      '--public-ed-key', 'PUBKEY',
      '--source-commit', head,
    ], { PATH: `${bin}:${process.env.PATH}`, PAPERRSS_ALLOW_DIRTY: '1' });
    assert.match(out, /版本不一致/);
  });
});
