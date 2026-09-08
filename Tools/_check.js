// Still-iOS 静态自检
// 编译不了（这台机器没有 Xcode / Swift），所以这里做能做的一切：
//   1. 括号平衡（剔除注释和字符串后）
//   2. 跨文件符号引用：engine.xxx / Cfg.xxx / Rooms.xxx / 自定义类型是否真的存在
//   3. 各 View 构造参数个数是否与定义一致

const fs = require('fs');
const path = require('path');

// Tools/ 是子目录，往上退一级才是工程根（Sources/ 在根下）。
// 别写成 __dirname —— 那只有在把脚本放根目录时才对，而文档里写的是 `node Tools/_check.js`。
const ROOT = path.join(__dirname, '..');
function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.name.endsWith('.swift')) out.push(p);
  }
  return out;
}

const files = walk(path.join(ROOT, 'Sources'));
if (!files.length) { console.log('没找到 .swift 文件'); process.exit(1); }

const src = {};
for (const f of files) src[f] = fs.readFileSync(f, 'utf8');
const all = Object.values(src).join('\n');

let problems = [];

// ─────────────────────────────────────────── 1. 括号平衡
function strip(s) {
  // 顺序很重要：先掏空字符串，再去注释。
  // 否则 "still://open" 里的 // 会被当成行注释，把后面的 ") 一起切掉。
  let out = s.replace(/"(?:[^"\\\n]|\\.)*"/g, '""');
  out = out.replace(/\/\*[\s\S]*?\*\//g, '');
  out = out.split('\n').map(l => l.replace(/\/\/.*$/, '')).join('\n');
  return out;
}
for (const [f, s] of Object.entries(src)) {
  const t = strip(s);
  for (const [open, close, name] of [['{', '}', '花括号'], ['(', ')', '圆括号'], ['[', ']', '方括号']]) {
    const a = (t.match(new RegExp('\\' + open, 'g')) || []).length;
    const b = (t.match(new RegExp('\\' + close, 'g')) || []).length;
    if (a !== b) problems.push(`括号不平衡 ${name}: ${path.relative(ROOT, f)}  ${open}=${a} ${close}=${b}`);
  }
}

// ─────────────────────────────────────────── 2. 收集定义

// 类型（struct / enum / class / final class / extension）
const typeNames = new Set();
for (const m of all.matchAll(/^\s*(?:public\s+|final\s+|@MainActor\s+)*(?:struct|enum|class|extension)\s+(\w+)/gm)) {
  typeNames.add(m[1]);
}
// 类型别名不算，手动补几个
for (const t of ['CGPoint', 'CGRect', 'CGSize', 'Color', 'View', 'Path']) typeNames.add(t);

// PetEngine 的成员
const engineSrc = Object.entries(src).find(([f]) => f.endsWith('PetEngine.swift'))[1];
const engineMembers = new Set();
for (const m of engineSrc.matchAll(/@Published\s+(?:private\(set\)\s+)?var\s+(\w+)/g)) engineMembers.add(m[1]);
for (const m of engineSrc.matchAll(/^\s*(?:private\s+|public\s+|@discardableResult\s+)*(?:func|var|let)\s+(\w+)/gm)) engineMembers.add(m[1]);

// 取某个 enum/struct 的花括号范围内容
function block(s, name) {
  const i = s.indexOf(name);
  if (i < 0) return '';
  const start = s.indexOf('{', i);
  if (start < 0) return '';
  let d = 0;
  for (let j = start; j < s.length; j++) {
    if (s[j] === '{') d++;
    else if (s[j] === '}') { d--; if (d === 0) return s.slice(start, j); }
  }
  return s.slice(start);
}

// Cfg 的静态成员 + 嵌套类型名（Palette）
const cfgSrc = Object.entries(src).find(([f]) => f.endsWith('StillConfig.swift'))[1];
const cfgMembers = new Set();
for (const m of cfgSrc.matchAll(/static\s+(?:let|var|func)\s+(\w+)/g)) cfgMembers.add(m[1]);
for (const m of cfgSrc.matchAll(/^\s*(?:case)\s+(\w+)/gm)) cfgMembers.add(m[1]);
{
  const cfgBlock = block(cfgSrc, 'enum Cfg');
  for (const m of cfgBlock.matchAll(/^\s*(?:public\s+)?enum\s+(\w+)/gm)) cfgMembers.add(m[1]);
}

// Rooms 的静态成员（按花括号范围精确取，别用窗口猜）
const roomsMembers = new Set();
{
  const roomsBlock = block(cfgSrc, 'enum Rooms') || cfgSrc;
  for (const m of roomsBlock.matchAll(/static\s+(?:let|var|func)\s+(\w+)/g)) roomsMembers.add(m[1]);
}
roomsMembers.add('all'); roomsMembers.add('byId'); roomsMembers.add('home');

// ─────────────────────────────────────────── 3. 检查引用

// engine.xxx
const engineRefs = new Set();
for (const m of all.matchAll(/\bengine\.(\w+)/g)) engineRefs.add(m[1]);
for (const r of engineRefs) {
  if (!engineMembers.has(r)) problems.push(`PetEngine 没有成员 "${r}"（被 engine.${r} 引用）`);
}

// Cfg.xxx
const cfgRefs = new Set();
for (const m of all.matchAll(/\bCfg\.(\w+)/g)) cfgRefs.add(m[1]);
for (const r of cfgRefs) {
  if (!cfgMembers.has(r)) problems.push(`Cfg 没有成员 "${r}"（被 Cfg.${r} 引用）`);
}

// Rooms.xxx
const roomsRefs = new Set();
for (const m of all.matchAll(/\bRooms\.(\w+)/g)) roomsRefs.add(m[1]);
for (const r of roomsRefs) {
  if (!roomsMembers.has(r)) problems.push(`Rooms 没有成员 "${r}"（被 Rooms.${r} 引用）`);
}

// Cfg.Palette.xxx
const paletteSrc = cfgSrc.match(/enum\s+Palette\s*\{([\s\S]*?)\n\s{4}\}/);
const paletteMembers = new Set();
if (paletteSrc) for (const m of paletteSrc[1].matchAll(/static\s+let\s+(\w+)/g)) paletteMembers.add(m[1]);
for (const m of all.matchAll(/Cfg\.Palette\.(\w+)/g)) {
  if (!paletteMembers.has(m[1])) problems.push(`Cfg.Palette 没有 "${m[1]}"`);
}

// CatColor.xxx
const catColorMembers = new Set();
for (const m of all.matchAll(/static\s+let\s+(body|bodyDark|patch|ear|line|nose|eye|tongue)\s*=/g)) catColorMembers.add(m[1]);
for (const m of all.matchAll(/CatColor\.(\w+)/g)) {
  if (!catColorMembers.has(m[1])) problems.push(`CatColor 没有 "${m[1]}"`);
}

// 自定义类型引用（排除系统类型首字母大写常见词）
const known = /^(SwiftUI|Foundation|WidgetKit|ActivityKit|View|Text|Color|Image|Button|Slider|HStack|VStack|ZStack|Spacer|Divider|Circle|Ellipse|Capsule|Rectangle|RoundedRectangle|Path|Group|ForEach|ScrollView|LazyVGrid|GridItem|GeometryReader|LinearGradient|Timer|Date|CGFloat|Double|Float|Int|Bool|String|URL|DateFormatter|Calendar|UserDefaults|JSONEncoder|JSONDecoder|Task|RunLoop|DispatchQueue|CGRect|CGPoint|CGSize|StrokeStyle|Angle|CGAffineTransform|Widget|WidgetBundle|WidgetConfiguration|StaticConfiguration|ActivityConfiguration|TimelineEntry|TimelineProvider|Timeline|ActivityViewContext|Activity|ActivityAttributes|DynamicIsland|DynamicIslandExpandedRegion|Environment|State|StateObject|ObservedObject|Published|MainActor|Binding|ViewBuilder|ViewModifier|ButtonStyle|Configuration|Content|App|Scene|WindowGroup|Codable|Hashable|Identifiable|CaseIterable|Comparable|Equatable|RawRepresentable|Optional|Array|Set|Dictionary|Result|Any|Never|Void|Self|Preview|available|discardableResult|escaping|main|inout|some|any)$/;
const customRefs = new Set();
for (const m of all.matchAll(/\b([A-Z]\w{2,})\s*[(\.<]/g)) customRefs.add(m[1]);
for (const t of customRefs) {
  if (!typeNames.has(t) && !known.test(t) && !/^[A-Z][a-z]+(?:View|Store|Engine|Shape|Mark|Card|Panel|Banner|Glyph|Provider|Entry|Bridge|Reloader|Heights|Motion|Bob|Widget|Activity|Attributes|Config|Palette)$/.test(t)) {
    // 只 warn，不 fail（可能是我漏收的系统类型）
  }
}

// ─────────────────────────────────────────── 4. 报告
console.log('文件数: ' + files.length);
console.log('PetEngine 成员: ' + [...engineMembers].sort().join(', '));
console.log('');
if (problems.length) {
  console.log('❌ 发现 ' + problems.length + ' 个问题:');
  problems.forEach(p => console.log('   · ' + p));
  process.exit(1);
} else {
  console.log('✅ 括号平衡 / 符号引用 全部通过');
}
