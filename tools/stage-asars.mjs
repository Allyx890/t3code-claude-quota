// Builds patched copies of the official app.asar / server.asar: identical except
// for the compiled server/web bundle and package version metadata.
// Keep the official desktop shell: this patch changes no desktop source, and
// rebuilding its shared RPC schemas would cause unrelated bundle churn.
// Native files keep exactly the official unpacked layout.
//
// usage: node stage-asars.mjs <officialResourcesDir> <sourceCheckout> <outResourcesDir> <version>
import { pathToFileURL } from 'node:url';
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, relative, sep } from 'node:path';

const [officialResources, source, out, version] = process.argv.slice(2);
if (!version) throw new Error('usage: stage-asars.mjs <officialResources> <source> <out> <version>');
const pnpm = join(source, 'node_modules/.pnpm');
const asarDir = readdirSync(pnpm).filter((name) => name.startsWith('@electron+asar@')).sort().pop();
const asar = await import(pathToFileURL(join(pnpm, asarDir, 'node_modules/@electron/asar/lib/asar.js')).href);

const walk = (dir) =>
  readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
    entry.isDirectory() ? walk(join(dir, entry.name)) : [join(dir, entry.name)],
  );
const posix = (p) => p.split(sep).join('/').replace(/^\//, '');
const work = `${out}.work`;
rmSync(work, { recursive: true, force: true });
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

const archives = [
  { name: 'app.asar', bundle: 'apps/desktop/dist-electron' },
  { name: 'server.asar', bundle: 'apps/server/dist' },
];
const report = { version, archives: [] };
for (const { name, bundle } of archives) {
  const original = join(officialResources, name);
  const tree = join(work, name);
  asar.extractAll(original, tree);
  const officialVersion = JSON.parse(readFileSync(join(tree, 'package.json'), 'utf8')).version;
  if (!version.startsWith(`${officialVersion}+`))
    throw new Error(`${name} is ${officialVersion}, but the build is ${version}; versions must match.`);
  const unpacked = existsSync(`${original}.unpacked`)
    ? walk(`${original}.unpacked`).map((p) => posix(relative(`${original}.unpacked`, p))).sort()
    : [];
  if (name === 'server.asar') {
    rmSync(join(tree, bundle), { recursive: true, force: true });
    cpSync(join(source, bundle), join(tree, bundle), { recursive: true, filter: (p) => !p.endsWith('.map') });
  }
  const pkgPath = join(tree, 'package.json');
  const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'));
  pkg.version = version;
  writeFileSync(pkgPath, `${JSON.stringify(pkg, null, 2)}\n`);

  const target = join(out, name);
  await asar.createPackageWithOptions(tree, target, {
    dot: true,
    ...(unpacked.length === 1 ? { unpack: `**/${unpacked[0]}` } : {}),
    ...(unpacked.length > 1 ? { unpack: `{${unpacked.map((p) => `**/${p}`).join(',')}}` } : {}),
  });
  const after = existsSync(`${target}.unpacked`)
    ? walk(`${target}.unpacked`).map((p) => posix(relative(`${target}.unpacked`, p))).sort()
    : [];
  if (JSON.stringify(after) !== JSON.stringify(unpacked))
    throw new Error(`${name}: unpacked native files changed (${unpacked.length} -> ${after.length}).`);
  const inside = (p) => p === bundle || p.startsWith(`${bundle}/`);
  const before = new Set(asar.listPackage(original, { isPack: false }).map(posix).filter((p) => !inside(p)));
  const now = new Set(asar.listPackage(target, { isPack: false }).map(posix).filter((p) => !inside(p)));
  const changed = [...before].filter((p) => !now.has(p)).concat([...now].filter((p) => !before.has(p)));
  if (changed.length) throw new Error(`${name}: files outside ${bundle} changed: ${changed.slice(0, 5).join(', ')}`);
  report.archives.push({ name, officialVersion, entries: now.size, unpacked: after.length });
}
rmSync(work, { recursive: true, force: true });
writeFileSync(join(out, '..', 'stage-report.json'), `${JSON.stringify(report, null, 2)}\n`);
console.log(JSON.stringify(report));
