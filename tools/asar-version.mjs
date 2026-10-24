// usage: node asar-version.mjs <app.asar> <sourceCheckout>  -> prints the archive's package version
import { pathToFileURL } from 'node:url';
import { readdirSync } from 'node:fs';
import { join } from 'node:path';

const [archive, source] = process.argv.slice(2);
const pnpm = join(source, 'node_modules/.pnpm');
const dir = readdirSync(pnpm).filter((name) => name.startsWith('@electron+asar@')).sort().pop();
const asar = await import(pathToFileURL(join(pnpm, dir, 'node_modules/@electron/asar/lib/asar.js')).href);
console.log(JSON.parse(asar.extractFile(archive, 'package.json').toString()).version);
