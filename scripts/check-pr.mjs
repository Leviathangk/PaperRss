import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const placeholder = /\b(?:TODO|TBD|PLACEHOLDER)\b|待填写|请填写/i;
const sections = ['变更', '验证', 'UI'];
function imageURL(text) {
  const match = text.match(/^!\[[^\]\n]+\]\((https:\/\/[^\s)]+)\)$/);
  if (!match) return null;
  try {
    const u = new URL(match[1]);
    if (u.username || u.password || u.port || u.hash) return null;
    if (u.hostname === 'github.com' && /^\/user-attachments\/assets\/[a-f\d-]{36}$/i.test(u.pathname)) return u.origin + u.pathname;
    if (['user-images.githubusercontent.com', 'private-user-images.githubusercontent.com', 'raw.githubusercontent.com'].includes(u.hostname)
      && /\.(png|jpe?g|gif|webp)$/i.test(u.pathname)) return u.origin + u.pathname;
  } catch {}
  return null;
}

// Path guard only: do not open files or print potentially sensitive filenames.
export function validatePaths(files) {
  const generated = /^(?:build(?:-[^/]+)?|DerivedData|\.build|\.swiftpm|dist|\.dist|\.scratch)\//;
  const local = /(?:^|\/)(?:xcuserdata|[^/]+\.xcuserdatad)(?:\/|$)|(?:^|\/)\.DS_Store$|\.xcuserstate$/;
  const fixture = /^(?:Tests|AppTests)\/fixtures\//;
  const secret = /(?:^|\/)(?:\.env(?:\.[^/]+)?|release\.env|id_rsa|id_ed25519)$|\.(?:key|pem|p12|pfx|mobileprovision)$/i;
  const example = /(?:\.example|\.template)$/i;
  const errors = [];
  if (files.some(f => generated.test(f) || local.test(f))) errors.push('变更包含构建产物或本机状态路径，请移出 PR。');
  if (files.some(f => secret.test(f) && !fixture.test(f) && !example.test(f))) errors.push('变更包含疑似凭据文件路径；仅允许明确的模板或测试夹具目录，需人工复核内容。');
  return errors;
}

export function validatePR({ title, body }, files = []) {
  const errors = [];
  if (typeof title !== 'string' || title.trim().length < 8 || placeholder.test(title)) errors.push('标题需具体描述改动（至少 8 字符），并移除占位符。');
  if (typeof body !== 'string') return [...errors, '缺少 PR 正文。'];
  // Comments cannot count as submitted evidence.
  body = body.replace(/<!--[\s\S]*?-->/g, '');
  if (placeholder.test(body)) errors.push('正文仍含 TODO/TBD 等占位符。');
  const parts = {};
  for (const name of sections) {
    const matches = [...body.matchAll(new RegExp(`^## ${name}\\s*$`, 'gm'))];
    if (matches.length !== 1) { errors.push(`必须且只能包含一个“## ${name}”章节。`); continue; }
    const rest = body.slice(matches[0].index + matches[0][0].length);
    parts[name] = rest.split(/^## /m)[0].trim();
  }
  if ((parts['变更'] || '').length < 12) errors.push('变更说明需包含问题与实际行为（至少 12 字符）。');
  const verification = parts['验证'] || '';
  if (!/^环境: .{4,}$/m.test(verification)) errors.push('填写测试环境和工具链版本。');
  const rows = verification.split('\n').filter(line => /^命令:/.test(line));
  if (!rows.length) errors.push('至少提供一条实际测试命令及通过/失败/跳过数。');
  for (const row of rows) {
    const m = row.match(/^命令: `([^`]+)` \| 通过: (\d+) \| 失败: (\d+) \| 跳过: (\d+)\s*$/);
    if (!m || !m[1].trim() || Number(m[2]) < 1 || Number(m[3]) !== 0) errors.push('测试记录格式无效、零通过或存在失败；如实保留失败并修复后更新。');
  }
  if (!/^未测项: \S.+/m.test(verification) && !/^未测项: 无\s*$/m.test(verification)) errors.push('填写未测项及原因，或明确写“无”。');
  const ui = parts.UI || '';
  const fields = {};
  for (const key of ['UI变更', '场景', '修改前', '修改后']) {
    const matches = [...ui.matchAll(new RegExp(`^${key}: (.+)$`, 'gm'))];
    if (matches.length !== 1) errors.push(`UI 部分必须且只能包含一个“${key}:”字段。`);
    else fields[key] = matches[0][1].trim();
  }
  if (!['是', '否'].includes(fields.UI变更)) errors.push('UI变更仅允许“是”或“否”。');
  if (!fields.场景 || fields.场景.length < 8) errors.push('补充可复现的同场景条件或无 UI 改动的具体理由。');
  // Conservative heuristic: maintainers review indirect UI changes and false positives.
  const uiFiles = files.some(f => /^(PaperRss\/Sources\/App\/|PaperRss\/Resources\/|website\/)/.test(f));
  if (uiFiles && fields.UI变更 === '否' && !/^路径说明: .{12,}$/m.test(ui)) errors.push('UI 候选路径声明无可见变化时，须填写至少 12 字符的路径说明，供维护者复核。');
  if (fields.UI变更 === '是') {
    const before = imageURL(fields.修改前 || '');
    const after = imageURL(fields.修改后 || '');
    if (!before || !after || before === after) errors.push('提供两张不同 URL 的 GitHub HTTPS 图片（Markdown），分别对应修改前/后。');
  } else if (fields.UI变更 === '否' && (fields.修改前 !== '不适用' || fields.修改后 !== '不适用')) errors.push('无 UI 变更时，修改前/后均填写“不适用”。');
  return errors;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const event = JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH || process.argv[2], 'utf8'));
    const pr = event.pull_request;
    if (!pr || !/^[a-f\d]{40}$/.test(pr.base?.sha) || !/^[a-f\d]{40}$/.test(pr.head?.sha)) throw new Error('Invalid PR event or SHA');
    const range = `${pr.base.sha}...${pr.head.sha}`;
    const files = execFileSync('git', ['diff', '--no-renames', '--name-only', '-z', range], { encoding: 'utf8' }).split('\0').filter(Boolean);
    execFileSync('git', ['diff', '--check', range], { stdio: ['ignore', 'pipe', 'pipe'] });
    const changed = execFileSync('git', ['diff', '--no-renames', '--diff-filter=ACMRT', '--name-only', '-z', range], { encoding: 'utf8' }).split('\0').filter(Boolean);
    const errors = [...validatePR(pr, files), ...validatePaths(changed)];
    // Fixed messages only; never emit attacker-controlled titles/body as workflow commands.
    for (const error of errors) console.error(`PR policy: ${error}`);
    process.exitCode = errors.length ? 1 : 0;
    if (!errors.length) console.log('PR policy: structure and diff checks passed; claims require human review.');
  } catch { console.error('PR policy: event/diff check failed; ensure full base/head history and no whitespace errors.'); process.exitCode = 1; }
}
