import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync, mkdtempSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { validatePR, validatePaths } from '../scripts/check-pr.mjs';
const valid = {
  title: '修复阅读器重复加载内容的问题',
  body: '## 变更\n修复重复选择文章时重复加载的问题，保持缓存状态。\n\n## 验证\n环境: macOS 15 / Node 22\n命令: `node --test Tests/*.test.mjs` | 通过: 12 | 失败: 0 | 跳过: 2\n未测项: GUI 交互未执行，当前只改缓存策略。\n\n## UI\nUI变更: 否\n场景: 此改动仅修复后台缓存，不改变界面。\n修改前: 不适用\n修改后: 不适用\n',
};
const image1 = '![before](https://github.com/user-attachments/assets/12345678-1234-1234-1234-123456789abc)';
const image2 = '![after](https://user-images.githubusercontent.com/123/456.png)';
const ui = { ...valid, body: valid.body.replace('UI变更: 否', 'UI变更: 是').replace('修改前: 不适用', `修改前: ${image1}`).replace('修改后: 不适用', `修改后: ${image2}`) };
const errors = (body, files=[]) => validatePR({ ...valid, body }, files);
test('non UI and explicit UI evidence accepted', () => {
  assert.deepEqual(validatePR(valid), []);
  assert.deepEqual(validatePR(ui, ['website/index.html']), []);
});
test('template cannot pass without actual evidence', () => assert.ok(errors(readFileSync(new URL('../.github/pull_request_template.md', import.meta.url), 'utf8')).length));
for (const [name, body] of [
  ['missing section', valid.body.replace('## 验证', '## Checks')],
  ['duplicate section', valid.body + '\n## 验证\nanything'],
  ['placeholder', valid.body.replace('修复重复', 'TODO 修复重复')],
  ['empty body', ''],
  ['checkbox only', valid.body.replace(/^命令:.*$/m, '- [x] tests passed')],
  ['failure', valid.body.replace('失败: 0', '失败: 1')],
  ['zero pass', valid.body.replace('通过: 12', '通过: 0')],
  ['negative count', valid.body.replace('跳过: 2', '跳过: -1')],
  ['missing environment', valid.body.replace(/^环境:.*\n/m, '')],
  ['missing untested', valid.body.replace(/^未测项:.*\n/m, '')],
  ['commented tests', valid.body.replace(/(命令:.*)/, '<!--$1-->')],
  ['invalid UI choice', valid.body.replace('UI变更: 否', 'UI变更: maybe')],
]) test(`rejects ${name}`, () => assert.ok(errors(body).length));
test('UI path is a heuristic requiring explanation, including renamed new paths', () => {
  assert.ok(errors(valid.body, ['PaperRss/Sources/App/RootView.swift']).length);
  assert.deepEqual(errors(valid.body + '\n路径说明: 只修改后台缓存释放时机，视图结构与渲染输出保持一致。', ['PaperRss/Sources/App/RootView.swift']), []);
  assert.deepEqual(errors(valid.body, ['Tests/fixtures/example.html']), []);
});
for (const bad of ['https://evil.example/a.png', 'http://user-images.githubusercontent.com/1/2.png', 'https://github.com.evil.example/a.png', 'javascript:alert(1)', 'https://user-images.githubusercontent.com/a.txt', 'https://user:pass@raw.githubusercontent.com/a/b.png']) {
  test(`rejects invalid image ${bad}`, () => assert.ok(errors(ui.body.replace(image2, `![after](${bad})`)).length));
}
test('same screenshot and duplicate UI fields rejected', () => {
  assert.ok(errors(ui.body.replace(image2, image1)).length);
  assert.ok(errors(valid.body + '\nUI变更: 是').length);
});
test('literal hostile shell payload is data', () => assert.deepEqual(errors(valid.body.replace('修复重复', '$(touch /tmp/SHOULD_NOT_EXIST) `id` 修复重复')), []));
test('real CLI checks committed diff, not only clean working tree; payload never executed', () => {
  const dir = mkdtempSync(join(tmpdir(), 'pr-policy-'));
  const script = resolve('scripts/check-pr.mjs');
  const git = (...args) => execFileSync('git', ['-c', 'core.fsmonitor=false', ...args], { cwd: dir, encoding: 'utf8' }).trim();
  try {
    git('init', '-q'); git('config', 'user.name', 'Fixture'); git('config', 'user.email', 'fixture@example.invalid');
    writeFileSync(join(dir, 'file.txt'), 'base\n'); git('add', '.'); git('commit', '-qm', 'base'); const base = git('rev-parse', 'HEAD');
    writeFileSync(join(dir, 'file.txt'), 'clean\n'); git('add', '.'); git('commit', '-qm', 'clean'); const head = git('rev-parse', 'HEAD');
    const marker = join(dir, 'pwned');
    const pr = { ...valid, title: `Fix $(touch ${marker})`, body: valid.body, base: { sha: base }, head: { sha: head } };
    const event = join(dir, 'event.json');
    const run = () => { writeFileSync(event, JSON.stringify({ pull_request: pr })); return spawnSync(process.execPath, [script, event], { cwd: dir, env: { ...process.env, GITHUB_EVENT_PATH: event } }); };
    assert.equal(run().status, 0); assert.equal(existsSync(marker), false);
    writeFileSync(join(dir, 'file.txt'), 'trailing space \n'); git('add', 'file.txt'); git('commit', '-qm', 'bad whitespace'); pr.head.sha = git('rev-parse', 'HEAD');
    assert.equal(run().status, 1);
    pr.head.sha = '$(touch anything)'; assert.equal(run().status, 1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
test('workflow has read-only PR execution, fixed action SHAs and an unconditional aggregate gate', () => {
  const source = readFileSync(new URL('../.github/workflows/pr-checks.yml', import.meta.url), 'utf8');
  assert.doesNotMatch(source, /pull_request_target|secrets\.|write-all|: write\b|paths-ignore:|\n\s+paths:/);
  assert.match(source, /contents: read/);
  assert.match(source, /types: \[opened, synchronize, reopened, edited, ready_for_review\]/);
  assert.match(source, /if: \$\{\{ always\(\) \}\}/);
  assert.match(source, /needs: \[policy, web, core\]/);
  for (const [, action] of source.matchAll(/uses: (.+)/g)) assert.match(action, /@[a-f0-9]{40}(?:\s|$)/);
  assert.equal((source.match(/persist-credentials: false/g) || []).length, 3);
  assert.doesNotMatch(source, /\$\{\{[^\n]*(?:\.body|\.title)/);
});
test('filled real template passes for docs and UI changes', () => {
  const template = readFileSync(new URL('../.github/pull_request_template.md', import.meta.url), 'utf8');
  let body = template.replace('TODO: 说明问题、改动后的行为及影响范围。', '补充贡献指南的测试证据示例，减少提交者填写歧义。')
    .replace('TODO: 系统及工具链版本', 'macOS 15 / Node 22')
    .replace('`TODO` | 通过: 0', '`node --test Tests/pr-policy.test.mjs` | 通过: 25')
    .replace('TODO: 列出未测行为、跳过原因；全部已测则写“无”。', '无')
    .replace('TODO: 是 / 否', '否')
    .replace('TODO: 是时填写系统、相同数据、窗口大小、主题、复现操作；否时说明无可见变化的理由。', '仅修改贡献文档，未更改应用与官网的可见界面。')
    .replace('TODO: 涉及 App/Resources/website 但无 UI 变化时解释，否则写“不适用”。', '不适用')
    .replaceAll('TODO: 是时提供图片 Markdown；否时写“不适用”。', '不适用');
  assert.deepEqual(errors(body, ['.github/CONTRIBUTING.md']), []);
  body = body.replace('UI变更: 否', 'UI变更: 是')
    .replace('仅修改贡献文档，未更改应用与官网的可见界面。', 'macOS 15，浅色，1280x800，相同示例订阅；选择首篇文章。')
    .replace('修改前: 不适用', `修改前: ${image1}`)
    .replace('修改后: 不适用', `修改后: ${image2}`);
  assert.deepEqual(errors(body, ['PaperRss/Sources/App/RootView.swift']), []);
});
test('same image with different query strings is not before/after evidence', () => {
  const body = ui.body.replace(image1, image2.replace('.png)', '.png?token=one)')).replace(`修改后: ${image2}`, `修改后: ${image2.replace('.png)', '.png?token=two)')}`);
  assert.ok(errors(body).length);
});
test('path guard rejects known outputs and credentials while allowing synthetic fixtures and templates', () => {
  for (const file of ['build/a', 'build-community-ui/a', '.build/a', 'DerivedData/a', 'dist/app.dmg', '.scratch/a', 'a/xcuserdata/state', 'a/private.pem', '.env', '.env.local', 'scripts/sparkle/release.env', 'a/id_ed25519']) {
    assert.ok(validatePaths([file]).length, file);
  }
  assert.deepEqual(validatePaths(['Tests/fixtures/https/key.pem', 'AppTests/fixtures/key.pem', '.env.example', 'scripts/sparkle/release.env.template', 'PaperRss/Sources/Core/Model.swift']), []);
});
test('aggregate gate succeeds only when every prerequisite succeeded', () => {
  const source = readFileSync(new URL('../.github/workflows/pr-checks.yml', import.meta.url), 'utf8');
  const command = source.match(/run: (test "\$POLICY"[^\n]+)/)[1];
  for (const status of ['success', 'failure', 'cancelled', 'skipped', '']) {
    for (const key of ['POLICY', 'WEB', 'CORE']) {
      const env = { ...process.env, POLICY: 'success', WEB: 'success', CORE: 'success', [key]: status };
      assert.equal(spawnSync('/bin/bash', ['-c', command], { env }).status, status === 'success' ? 0 : 1);
    }
  }
});
test('CLI blocks added credentials, permits removal, and keeps code-to-doc renames visible', () => {
  const dir = mkdtempSync(join(tmpdir(), 'pr-path-policy-'));
  const script = resolve('scripts/check-pr.mjs');
  const git = (...args) => execFileSync('git', ['-c', 'core.fsmonitor=false', ...args], { cwd: dir, encoding: 'utf8' }).trim();
  try {
    git('init', '-q'); git('config', 'user.name', 'Fixture'); git('config', 'user.email', 'fixture@example.invalid');
    writeFileSync(join(dir, 'code.swift'), 'let value = 1\n'); git('add', '.'); git('commit', '-qm', 'base');
    const base = git('rev-parse', 'HEAD');
    writeFileSync(join(dir, '.env'), 'SYNTHETIC_TEST_VALUE=placeholder\n'); git('add', '.env'); git('commit', '-qm', 'synthetic prohibited path');
    const badHead = git('rev-parse', 'HEAD');
    const event = join(dir, 'event.json');
    const run = (baseSHA, headSHA) => {
      writeFileSync(event, JSON.stringify({ pull_request: { ...valid, base: { sha: baseSHA }, head: { sha: headSHA } } }));
      return spawnSync(process.execPath, [script, event], { cwd: dir, env: { ...process.env, GITHUB_EVENT_PATH: event } }).status;
    };
    assert.equal(run(base, badHead), 1);
    git('rm', '.env'); git('commit', '-qm', 'remove prohibited path');
    assert.equal(run(badHead, git('rev-parse', 'HEAD')), 0);
    git('mv', 'code.swift', 'code.md'); git('commit', '-qm', 'rename code to docs');
    const names = git('diff', '--no-renames', '--name-only', `${base}...HEAD`).split('\n');
    assert.ok(names.includes('code.swift'));
    assert.equal(names.every(f => f.endsWith('.md')), false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
