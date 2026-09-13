// Local preview server. Run: node serve.cjs
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const files = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/index.html', ['index.html', 'text/html; charset=utf-8']],
  ['/sw.js', ['sw.js', 'text/javascript; charset=utf-8']],
  ['/css/style.css', ['css/style.css', 'text/css; charset=utf-8']],
  ...['app', 'storage', 'tracker'].map(name => [`/js/${name}.js`, [`js/${name}.js`, 'text/javascript; charset=utf-8']])
]);
const server = http.createServer((req, res) => {
  if (!['GET', 'HEAD'].includes(req.method)) { res.writeHead(405, { Allow: 'GET, HEAD' }); return res.end(); }
  const file = files.get(new URL(req.url, 'http://localhost').pathname);
  if (!file) { res.writeHead(404); return res.end('Not found'); }
  fs.readFile(path.join(__dirname, file[0]), (error, body) => {
    if (error) { res.writeHead(500); return res.end('Unable to read app asset'); }
    res.writeHead(200, { 'Content-Type': file[1], 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
    res.end(req.method === 'HEAD' ? undefined : body);
  });
});
server.on('error', error => { console.error(error.message); process.exit(1); });
server.listen(8080, '127.0.0.1', () => console.log('Arajpur East PACS PDS: http://127.0.0.1:8080'));
