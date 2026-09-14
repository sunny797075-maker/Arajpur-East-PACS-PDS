const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');
const base = 'https://15.252.37.89';
async function request(route, body, headers={}) {
  const response = await fetch(base+'/api/v1/'+route, {method:body===undefined?'GET':'POST', headers:{'Content-Type':'application/json',...headers}, ...(body===undefined?{}:{body:JSON.stringify(body)})});
  const json = await response.json();
  return {response,json};
}
(async()=>{
  const text=fs.readFileSync(path.join(os.homedir(),'.aws','pds-owner-login.txt'),'utf8');
  const password=/^Password: (.+)$/m.exec(text)[1];
  const login=await request('auth/super-admin/login',{identifier:'ADMIN-001',password,clientType:'NATIVE',rememberMe:false});
  assert.equal(login.response.status,201);assert.equal(login.json.role,'SUPER_ADMIN');assert.equal(login.json.distributorId,null);
  const authorization='Bearer '+login.json.accessToken;
  assert.equal((await request('admin/distributors',undefined,{authorization})).response.status,200);
  assert.equal((await request('distributor/me',undefined,{authorization})).response.status,403);
  await request('auth/logout',{}, {authorization});
  assert.equal((await request('auth/me',undefined,{authorization})).response.status,401);
  console.log('PASS owner login, platform access, business-data denial, logout and revocation');
  const web=await request('auth/super-admin/login',{identifier:'ADMIN-001',password,clientType:'WEB',rememberMe:true},{Origin:base});
  assert.equal(web.response.status,201);assert.equal(web.json.refreshToken,undefined);
  const cookies=web.response.headers.getSetCookie();
  assert(cookies.some(c=>c.startsWith('pds_refresh=') && /HttpOnly/.test(c) && /Secure/.test(c) && /SameSite=Strict/.test(c)));
  const cookie=cookies.map(c=>c.split(';')[0]).join('; ');
  const csrf=decodeURIComponent(cookies.find(c=>c.startsWith('pds_csrf=')).split(';')[0].slice(9));
  assert.equal((await request('auth/refresh',{}, {Origin:base,Cookie:cookie,'X-CSRF-Token':'wrong'})).response.status,403);
  const refreshed=await request('auth/refresh',{}, {Origin:base,Cookie:cookie,'X-CSRF-Token':csrf});
  assert.equal(refreshed.response.status,201);assert.equal(refreshed.json.role,'SUPER_ADMIN');
  assert.equal((await request('auth/refresh',{}, {Origin:base,Cookie:cookie,'X-CSRF-Token':csrf})).response.status,401);
  assert.equal((await request('auth/me',undefined,{Authorization:'Bearer '+refreshed.json.accessToken})).response.status,401);
  console.log('PASS browser HttpOnly/Secure cookies, CSRF checks, refresh rotation and replay revocation');
  assert.equal((await request('auth/super-admin/login',{identifier:'ADMIN-001',password:'Preview@12345',clientType:'NATIVE',rememberMe:false})).response.status,401);
  console.log('PASS public demo password rejected');
})().catch(e=>{console.error('Live verification failed:',e.message);process.exitCode=1;});
