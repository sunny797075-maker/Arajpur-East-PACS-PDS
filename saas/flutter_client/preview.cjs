// Serve only the compiled Flutter web directory on localhost.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, 'build/web');
const types = {'.html':'text/html', '.js':'text/javascript', '.json':'application/json', '.css':'text/css', '.wasm':'application/wasm', '.png':'image/png', '.svg':'image/svg+xml', '.otf':'font/otf', '.ttf':'font/ttf'};
http.createServer((req,res) => {
  if (!['GET','HEAD'].includes(req.method)) {res.writeHead(405);return res.end();}
  let name; try {name = decodeURIComponent(new URL(req.url,'http://localhost').pathname);} catch {res.writeHead(400);return res.end();}
  const file = path.resolve(root, '.' + (name === '/' ? '/index.html' : name));
  if (!file.startsWith(root + path.sep)) {res.writeHead(403);return res.end();}
  fs.readFile(file, (err,data) => {
    if(err){res.writeHead(404);return res.end('Not found');}
    res.writeHead(200,{'Content-Type':types[path.extname(file)] || 'application/octet-stream','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});
    res.end(req.method === 'HEAD' ? undefined : data);
  });
}).listen(8090,'127.0.0.1',()=>console.log('PDS Connect preview: http://127.0.0.1:8090'));
