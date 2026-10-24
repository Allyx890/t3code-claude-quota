// Official release builds bake public config (Clerk sign-in, T3 Connect relay, relay tracing,
// update repository, telemetry channel) into the bundles from CI variables. A local build
// leaves them empty, which silently disables T3 Connect. This reads them back out of the
// official archives so the patched build matches.
//
// usage: node build-config.mjs env    <officialResources> <source>
//          prints KEY=VALUE lines to set before building
//        node build-config.mjs verify <officialResources> <stagedResources> <source>
//          fails unless the staged bundles carry exactly the official build config
import { pathToFileURL } from 'node:url';
import { readdirSync } from 'node:fs';
import { join } from 'node:path';

const [command, officialResources, ...rest] = process.argv.slice(2);
const source = rest.at(-1);
const pnpm = join(source, 'node_modules/.pnpm');
const asarDir = readdirSync(pnpm).filter((name) => name.startsWith('@electron+asar@')).sort().pop();
const asar = await import(pathToFileURL(join(pnpm, asarDir, 'node_modules/@electron/asar/lib/asar.js')).href);

const files = (archive, prefix, suffix) =>
  asar
    .listPackage(archive, { isPack: false })
    .map((raw) => ({ raw: raw.replace(/^[\\/]/, ''), path: raw.replaceAll('\\', '/').replace(/^\//, '') }))
    .filter(({ path }) => path.startsWith(prefix) && path.endsWith(suffix))
    .map(({ raw, path }) => ({ path, text: asar.extractFile(archive, raw).toString('utf8') }));

/** The `import.meta.env` object Vite inlines into the web client. */
function webEnv(resources) {
  for (const { text } of files(join(resources, 'server.asar'), 'apps/server/dist/client/assets/', '.js')) {
    const match = text.match(/\{APP_VERSION:`[^`]*`,[^{}]*\}/);
    if (!match) continue;
    const env = {};
    for (const [, key, value] of match[0].matchAll(/([A-Z0-9_]+):`([^`]*)`/g)) env[key] = value;
    return env;
  }
  throw new Error(`No web client env object found in ${resources}\\server.asar.`);
}

/** Build-time values the server bundle inlines through `define`. */
function serverValues(resources) {
  const found = new Set();
  for (const { text } of files(join(resources, 'server.asar'), 'apps/server/dist/', '.mjs')) {
    for (const [value] of text.matchAll(
      /readBuildTimeValue\("[^"]*"\)|normalizeSecureRelayUrl\("[^"]*"\)|telemetryChannel = "[^"]*"/g,
    ))
      found.add(value);
  }
  return [...found].sort();
}

if (command === 'env') {
  const env = webEnv(officialResources);
  const lines = Object.entries(env)
    .filter(([key, value]) => /^(VITE|T3CODE)_/.test(key) && value !== '')
    .map(([key, value]) => `${key}=${value}`);
  const channel = serverValues(officialResources)
    .map((value) => value.match(/^telemetryChannel = "(.*)"$/)?.[1])
    .find(Boolean);
  if (channel) lines.push(`T3CODE_TELEMETRY_CHANNEL=${channel}`);
  if (!lines.some((line) => line.startsWith('VITE_CLERK_PUBLISHABLE_KEY=')))
    throw new Error('The official build has no Clerk key; the extraction pattern is probably stale.');
  console.log(lines.join('\n'));
} else if (command === 'verify') {
  const staged = rest[0];
  const problems = [];
  const officialEnv = { ...webEnv(officialResources), APP_VERSION: '' };
  const stagedEnv = { ...webEnv(staged), APP_VERSION: '' };
  if (JSON.stringify(officialEnv) !== JSON.stringify(stagedEnv))
    problems.push(`web client env differs:\n  official ${JSON.stringify(officialEnv)}\n  staged   ${JSON.stringify(stagedEnv)}`);
  const officialServer = serverValues(officialResources).join('\n');
  const stagedServer = serverValues(staged).join('\n');
  if (officialServer !== stagedServer)
    problems.push(`server build values differ:\n  official ${officialServer}\n  staged   ${stagedServer}`);
  // The patch never touches the desktop shell, so apart from bundler path comments it must be identical.
  const strip = (text) => text.replace(/^\/\/#(?:end)?region.*$/gm, '');
  const desktop = (resources) =>
    new Map(files(join(resources, 'app.asar'), 'apps/desktop/dist-electron/', '.cjs').map((f) => [f.path, strip(f.text)]));
  const officialDesktop = desktop(officialResources);
  const stagedDesktop = desktop(staged);
  for (const [path, text] of officialDesktop)
    if (stagedDesktop.get(path) !== text) problems.push(`desktop bundle differs: ${path}`);
  if (stagedDesktop.size !== officialDesktop.size) problems.push('desktop bundle file list differs');
  if (problems.length) {
    console.error(problems.join('\n'));
    process.exit(1);
  }
  console.log('Build config matches the official build (web env, server values, desktop shell).');
} else {
  throw new Error('usage: build-config.mjs env|verify ...');
}
