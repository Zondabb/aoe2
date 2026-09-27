#!/usr/bin/env node
// Local verification server. Use deploy/web/nginx.conf for cloud hosting.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { pathToFileURL } from 'node:url';

const types = { '.html': 'text/html; charset=utf-8', '.js': 'application/javascript; charset=utf-8',
  '.wasm': 'application/wasm', '.pck': 'application/octet-stream', '.json': 'application/json',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml', '.ico': 'image/x-icon',
  '.webmanifest': 'application/manifest+json', '.ogg': 'audio/ogg', '.mp3': 'audio/mpeg' };

export function chooseEncoding(header, available) {
  const values = new Map();
  for (const part of String(header ?? '').toLowerCase().split(',')) {
    const [name, ...parameters] = part.trim().split(';');
    if (!name) continue;
    const parameter = parameters.find((item) => item.trim().startsWith('q='));
    const q = parameter ? Number(parameter.trim().slice(2)) : 1;
    values.set(name, Number.isFinite(q) && q >= 0 && q <= 1 ? q : 0);
  }
  function quality(name) {
    if (values.has(name)) return values.get(name);
    if (name === 'identity') return values.get('*') === 0 ? 0 : 1;
    return values.get('*') ?? 0;
  }
  return ['br', 'gzip', 'identity'].filter((name) => available.includes(name) && quality(name) > 0)
    .sort((a, b) => quality(b) - quality(a))[0] ?? null;
}

export function createWebServer(directory) {
  const root = fs.realpathSync(directory);
  return http.createServer((request, response) => {
    if (!['GET', 'HEAD'].includes(request.method)) {
      response.writeHead(405, { Allow: 'GET, HEAD' }).end(); return;
    }
    try {
      const url = new URL(request.url, 'http://localhost');
      let pathname = decodeURIComponent(url.pathname);
      if (pathname.includes('\0') || pathname.includes('\\')) throw new Error('Invalid URL');
      if (pathname.endsWith('/')) pathname += 'index.html';
      const source = path.resolve(root, `.${pathname}`);
      const isInside = (file) => {
        const relative = path.relative(root, fs.realpathSync(file));
        return relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
      };
      if (!isInside(source) || !fs.statSync(source).isFile()) throw new Error('Missing file');
      const available = ['identity'];
      for (const [encoding, suffix] of [['br', '.br'], ['gzip', '.gz']]) {
        if (fs.existsSync(source + suffix) && isInside(source + suffix)) available.push(encoding);
      }
      const encoding = chooseEncoding(request.headers['accept-encoding'], available);
      if (!encoding) { response.writeHead(406, { Vary: 'Accept-Encoding' }).end(); return; }
      const data = fs.readFileSync(source + ({ br: '.br', gzip: '.gz', identity: '' }[encoding]));
      const etag = `"${crypto.createHash('sha256').update(data).digest('hex')}"`;
      const headers = { 'Content-Type': types[path.extname(source)] ?? 'application/octet-stream',
        'Content-Length': data.length, 'Cache-Control': 'public, max-age=0, must-revalidate',
        Vary: 'Accept-Encoding', ETag: etag };
      if (encoding !== 'identity') headers['Content-Encoding'] = encoding;
      const cached = String(request.headers['if-none-match'] ?? '').split(',')
        .map((value) => value.trim().replace(/^W\//, '')).some((value) => value === '*' || value === etag);
      if (cached) {
        delete headers['Content-Length'];
        response.writeHead(304, headers).end(); return;
      }
      response.writeHead(200, headers).end(request.method === 'HEAD' ? undefined : data);
    } catch {
      response.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }).end('Not found');
    }
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const directory = path.resolve(process.argv[2] ?? 'dist/web');
  const port = Number(process.argv[3] ?? 8080);
  const server = createWebServer(directory);
  server.on('error', (error) => { console.error(error.message); process.exitCode = 1; });
  server.listen(port, '127.0.0.1', () => console.log(`Web preview: http://127.0.0.1:${server.address().port}/`));
}
