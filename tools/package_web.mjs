#!/usr/bin/env node
// Node 18+; uses only built-in modules. Never changes source artwork or fonts.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { gzipSync, gunzipSync, brotliCompressSync, brotliDecompressSync, constants } from 'node:zlib';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const compressible = new Set(['.wasm', '.pck', '.js', '.html', '.json', '.webmanifest', '.svg']);
const allowed = new Set([...compressible, '.png', '.ico', '.jpg', '.webp', '.ogg', '.mp3', '.woff2']);
const hash = (data) => crypto.createHash('sha256').update(data).digest('hex');

function safeName(name) {
  return typeof name === 'string' && name !== '.' && name !== '..'
    && name === path.basename(name) && !/[\\/\0]/.test(name);
}

export function packageWeb({ input = 'web', output = 'dist/web', entry, quality = 9 } = {}) {
  const source = fs.realpathSync(path.resolve(input));
  const destination = path.resolve(output);
  // Output must not overwrite the export or any of its parent directories.
  const relative = path.relative(destination, source);
  if (relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative))) {
    throw new Error('Output must not equal or contain the input directory.');
  }
  if (fs.existsSync(destination) && fs.lstatSync(destination).isSymbolicLink()) {
    throw new Error('Output directory must not be a symbolic link.');
  }
  if (!Number.isInteger(quality) || quality < 0 || quality > 11) throw new Error('Brotli quality must be 0..11.');
  const names = fs.readdirSync(source);
  if (!entry) {
    const entries = names.filter((name) => name.endsWith('.html'));
    if (entries.length !== 1) throw new Error('Specify --entry when the export contains multiple HTML files.');
    [entry] = entries;
  }
  if (!safeName(entry) || !entry.endsWith('.html')) throw new Error('Entry must be a local HTML filename.');
  const html = fs.readFileSync(path.join(source, entry), 'utf8');
  const configMatch = html.match(/\bconst GODOT_CONFIG\s*=\s*(\{[^\r\n]+\});/);
  if (!configMatch) throw new Error('Entry does not contain the expected Godot export configuration.');
  const config = JSON.parse(configMatch[1]);
  const base = config.executable;
  if (!safeName(base)) throw new Error('Unsupported executable filename in Godot configuration.');
  const files = names.filter((name) => (name === entry || name.startsWith(`${base}.`)) && allowed.has(path.extname(name)));
  if (!files.includes(`${base}.js`)) throw new Error('Godot JavaScript loader is missing.');
  for (const required of [`${base}.wasm`, `${base}.pck`]) {
    if (!config.fileSizes?.[required]) throw new Error(`Godot configuration is missing ${required}.`);
  }
  for (const [name, size] of Object.entries(config.fileSizes)) {
    if (!safeName(name) || !files.includes(name) || fs.statSync(path.join(source, name)).size !== size) {
      throw new Error(`Missing file or mismatched export size: ${name}. Re-export the complete game.`);
    }
  }
  // Refuse extensions that require unhandled external files instead of creating a broken package.
  if (config.gdextensionLibs?.length) throw new Error('GDExtension Web exports need a separate packaging manifest.');
  const permitted = new Set(['.gdignore']);
  for (const name of [...files, 'index.html']) {
    permitted.add(name);
    if (compressible.has(path.extname(name))) {
      permitted.add(`${name}.gz`);
      permitted.add(`${name}.br`);
    }
  }
  fs.mkdirSync(destination, { recursive: true });
  for (const name of fs.readdirSync(destination)) {
    if (!permitted.has(name) || !fs.lstatSync(path.join(destination, name)).isFile()) {
      throw new Error(`Output contains unmanaged files: ${name}. Use a new output directory.`);
    }
  }
  // Godot otherwise imports the generated icons during the next project scan.
  fs.writeFileSync(path.join(destination, '.gdignore'), '');
  const report = { entry, brotliQuality: quality, files: [], totals: { raw: 0, gzip: 0, brotli: 0 } };
  function write(name, data, count = true) {
    if (!fs.lstatSync(path.join(source, count ? name : entry)).isFile()) throw new Error(`Not a regular file: ${name}`);
    fs.writeFileSync(path.join(destination, name), data);
    const record = { name, raw: data.length, sha256: hash(data) };
    if (compressible.has(path.extname(name))) {
      const gzip = gzipSync(data, { level: 9 });
      const brotli = brotliCompressSync(data, { params: {
        [constants.BROTLI_PARAM_QUALITY]: quality,
        [constants.BROTLI_PARAM_SIZE_HINT]: data.length,
      } });
      if (!gunzipSync(gzip).equals(data) || !brotliDecompressSync(brotli).equals(data)) {
        throw new Error(`Compression round-trip mismatch: ${name}`);
      }
      for (const [extension, content] of [['gz', gzip], ['br', brotli]]) {
        const target = path.join(destination, `${name}.${extension}`);
        if (content.length < data.length) {
          fs.writeFileSync(target, content);
          record[extension === 'gz' ? 'gzip' : 'brotli'] = content.length;
        } else if (fs.existsSync(target)) {
          fs.unlinkSync(target); // Only this file's generated sidecar inside the checked output.
        }
      }
    }
    if (count) {
      report.files.push(record);
      report.totals.raw += record.raw;
      report.totals.gzip += record.gzip ?? record.raw;
      report.totals.brotli += record.brotli ?? record.gzip ?? record.raw;
    }
  }
  for (const name of files.sort()) write(name, fs.readFileSync(path.join(source, name)));
  if (entry !== 'index.html') write('index.html', Buffer.from(html), false);
  const reportPath = path.join(path.dirname(destination), `${path.basename(destination)}-compression-report.json`);
  fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
  return { ...report, output: destination, reportPath };
}

function main(args) {
  const opts = {};
  for (let i = 0; i < args.length; i += 2) {
    if (args[i] === '--help') {
      console.log('node tools/package_web.mjs [--input web] [--output dist/web] [--entry "AoE2 RTS.html"] [--brotli-quality 9] [--godot <executable>]');
      return;
    }
    const key = { '--input': 'input', '--output': 'output', '--entry': 'entry', '--brotli-quality': 'quality', '--godot': 'godot' }[args[i]];
    if (!key || !args[i + 1]) throw new Error(`Unknown or incomplete option: ${args[i]}`);
    opts[key] = key === 'quality' ? Number(args[i + 1]) : args[i + 1];
  }
  if (opts.godot) {
    opts.input ??= path.join(projectRoot, '.godot', 'web-export');
    opts.entry ??= 'index.html';
    if (!safeName(opts.entry)) throw new Error('Invalid export entry.');
    fs.mkdirSync(opts.input, { recursive: true });
    const result = spawnSync(opts.godot, ['--headless', '--path', projectRoot,
      '--log-file', path.join(projectRoot, '.godot', 'web-export.log').replaceAll('\\', '/'),
      '--export-release', 'Web', path.resolve(opts.input, opts.entry).replaceAll('\\', '/')],
    { stdio: 'inherit', windowsHide: true, timeout: 300_000 });
    if (result.error || result.status !== 0) throw new Error(`Godot export failed: ${result.error?.message ?? result.status}`);
  }
  const report = packageWeb(opts);
  const mb = (value) => `${(value / 1_000_000).toFixed(2)} MB`;
  console.log(`Raw ${mb(report.totals.raw)} -> gzip ${mb(report.totals.gzip)} / Brotli ${mb(report.totals.brotli)}`);
  console.log(`Package: ${report.output}\nReport: ${report.reportPath}`);
  console.log('Deploy with Content-Encoding negotiation; .gz/.br sidecars alone do not enable compression.');
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try { main(process.argv.slice(2)); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
