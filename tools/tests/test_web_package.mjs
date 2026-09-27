import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import { once } from 'node:events';
import { gunzipSync, brotliDecompressSync } from 'node:zlib';
import { packageWeb } from '../package_web.mjs';
import { createWebServer, chooseEncoding } from '../serve_web.mjs';

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'aoe2-web-test-'));
  const input = path.join(root, 'input');
  const output = path.join(root, 'output');
  fs.mkdirSync(input);
  t.after(() => {
    const target = fs.realpathSync(root);
    const temp = fs.realpathSync(os.tmpdir());
    assert.equal(path.dirname(target), temp, 'cleanup must stay inside the temporary directory');
    assert(path.basename(target).startsWith('aoe2-web-test-'));
    fs.rmSync(target, { recursive: true, force: true });
  });
  const data = Buffer.from('The game world and WebAssembly data. '.repeat(2000));
  const config = { executable: 'AoE2 RTS', fileSizes: { 'AoE2 RTS.wasm': data.length, 'AoE2 RTS.pck': data.length }, gdextensionLibs: [] };
  for (const name of ['AoE2 RTS.wasm', 'AoE2 RTS.pck', 'AoE2 RTS.js']) fs.writeFileSync(path.join(input, name), data);
  fs.writeFileSync(path.join(input, 'AoE2 RTS.html'), `<!doctype html><html><script>const GODOT_CONFIG = ${JSON.stringify(config)};</script></html>`);
  fs.writeFileSync(path.join(input, 'AoE2 RTS.icon.png.import'), 'editor metadata');
  fs.writeFileSync(path.join(input, 'token.txt'), 'test-only-placeholder');
  return { root, input, output, data };
}

test('packages only runtime files and validates gzip/Brotli round trips', (t) => {
  const f = fixture(t);
  const report = packageWeb({ ...f, quality: 4 });
  assert.equal(report.files.length, 4);
  assert(report.totals.gzip < report.totals.raw);
  for (const row of report.files) {
    const original = fs.readFileSync(path.join(f.input, row.name));
    assert.deepEqual(fs.readFileSync(path.join(f.output, row.name)), original);
    if (row.gzip) assert.deepEqual(gunzipSync(fs.readFileSync(path.join(f.output, `${row.name}.gz`))), original);
    if (row.brotli) assert.deepEqual(brotliDecompressSync(fs.readFileSync(path.join(f.output, `${row.name}.br`))), original);
  }
  assert.equal(fs.existsSync(path.join(f.output, 'token.txt')), false);
  assert.equal(fs.existsSync(path.join(f.output, 'AoE2 RTS.icon.png.import')), false);
  assert(fs.existsSync(path.join(f.output, '.gdignore')));
  assert.deepEqual(fs.readFileSync(path.join(f.output, 'index.html')), fs.readFileSync(path.join(f.input, 'AoE2 RTS.html')));
  assert(fs.existsSync(report.reportPath));
  assert.equal(packageWeb({ ...f, quality: 4 }).totals.raw, report.totals.raw);
});

test('fails on incomplete exports and refuses overwriting input or unrelated files', (t) => {
  const f = fixture(t);
  assert.throws(() => packageWeb({ ...f, output: f.input }), /must not equal/);
  assert.throws(() => packageWeb({ ...f, output: f.root }), /must not equal/);
  fs.mkdirSync(f.output);
  fs.writeFileSync(path.join(f.output, 'keep.txt'), 'keep');
  assert.throws(() => packageWeb(f), /unmanaged/);
  fs.writeFileSync(path.join(f.input, 'AoE2 RTS.pck'), 'truncated');
  assert.throws(() => packageWeb({ ...f, output: path.join(f.root, 'clean') }), /mismatched/);
  assert.equal(fs.readFileSync(path.join(f.output, 'keep.txt'), 'utf8'), 'keep');
});

test('encoding preferences respect disabled encodings, weights and identity fallback', () => {
  const all = ['br', 'gzip', 'identity'];
  assert.equal(chooseEncoding('gzip, br', all), 'br');
  assert.equal(chooseEncoding('br;q=0, gzip', all), 'gzip');
  assert.equal(chooseEncoding('br;q=0.5, gzip;q=0.8, identity;q=0', all), 'gzip');
  assert.equal(chooseEncoding('', all), 'identity');
  assert.equal(chooseEncoding('*;q=0', all), null);
  assert.equal(chooseEncoding('br, gzip', ['identity']), 'identity');
});

function request(port, headers = {}, method = 'GET') {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path: '/AoE2%20RTS.wasm', headers, method }, (res) => {
      const parts = [];
      res.on('data', (part) => parts.push(part));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(parts) }));
    });
    req.on('error', reject); req.end();
  });
}

test('HTTP returns correct encoded bytes, MIME, cache validators and uncompressed fallback', async (t) => {
  const f = fixture(t);
  packageWeb({ ...f, quality: 4 });
  const server = createWebServer(f.output);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  try {
    const port = server.address().port;
    for (const encoding of ['gzip', 'br', 'identity']) {
      const response = await request(port, { 'Accept-Encoding': encoding });
      assert.equal(response.status, 200);
      assert.equal(response.headers['content-type'], 'application/wasm');
      assert.equal(response.headers.vary, 'Accept-Encoding');
      assert.equal(Number(response.headers['content-length']), response.body.length);
      assert.equal(response.headers['content-encoding'], encoding === 'identity' ? undefined : encoding);
      const decoded = encoding === 'br' ? brotliDecompressSync(response.body) : encoding === 'gzip' ? gunzipSync(response.body) : response.body;
      assert.deepEqual(decoded, f.data);
      const cached = await request(port, { 'Accept-Encoding': encoding, 'If-None-Match': response.headers.etag });
      assert.equal(cached.status, 304);
      assert.equal(cached.body.length, 0);
      const head = await request(port, { 'Accept-Encoding': encoding }, 'HEAD');
      assert.equal(head.status, 200);
      assert.equal(head.body.length, 0);
      assert.equal(head.headers['content-length'], response.headers['content-length']);
    }
    assert.equal((await request(port, { 'Accept-Encoding': '*;q=0' })).status, 406);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
