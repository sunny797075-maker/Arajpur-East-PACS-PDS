// Exercise public signup using an isolated temporary fixture, then remove it.
const {Pool}=require('/opt/pds/api/node_modules/pg');
const {randomBytes,randomInt}=require('node:crypto');
const assert=require('node:assert/strict');
(async()=>{
 const db=new Pool({host:'/var/run/postgresql',database:'pds_saas',user:'postgres'});
 const email='signup-'+randomBytes(10).toString('hex')+'@example.invalid';
 const password=randomBytes(24).toString('base64url');
 const mobile='+919'+String(randomInt(0,1000000000)).padStart(9,'0');
 const data={email,mobile,password,confirmPassword:password,organization:{organizationName:'Automated signup verification',organizationType:'INDEPENDENT',
  ownerName:'Temporary verification',state:'Test',district:'Test',block:'Test',panchayat:'Test',village:'Test',address:'Temporary verification fixture',pinCode:'000000'}};
 async function post(route,body){return fetch('https://15.252.37.89/api/v1/'+route,{method:'POST',headers:{'Content-Type':'application/json',Origin:'https://15.252.37.89'},body:JSON.stringify(body)});}
 try{
  assert.equal((await post('auth/distributor/register',{...data,role:'SUPER_ADMIN'})).status,400);
  const created=await post('auth/distributor/register',data);assert.equal(created.status,201);
  const account=await created.json();assert.match(account.distributorId,/^DIST-\d+$/);
  const repeated=await post('auth/distributor/register',data);assert.equal(repeated.status,201);assert.equal((await repeated.json()).distributorId,account.distributorId);
  const conflict=await post('auth/distributor/register',{...data,password:'another-long-password',confirmPassword:'another-long-password'});assert.equal(conflict.status,409);
  const login=await post('auth/distributor/login',{identifier:email,password,clientType:'WEB',rememberMe:false});assert.equal(login.status,201);
  const session=await login.json();assert.equal(session.role,'DISTRIBUTOR');assert.equal(session.profile.organizationName,data.organization.organizationName);assert.equal(session.profile.phone,mobile);
  const headers={Authorization:'Bearer '+session.accessToken};
  const profile=await fetch('https://15.252.37.89/api/v1/distributor/me',{headers});assert.equal(profile.status,200);assert.equal((await profile.json()).distributor_id,account.distributorId);
  assert.equal((await fetch('https://15.252.37.89/api/v1/admin/distributors',{headers})).status,403);
  const verified=await db.query('SELECT email_verified_at,mobile_verified_at FROM identity.users WHERE email=$1',[email]);assert.equal(verified.rows.length,1);assert.equal(verified.rows[0].email_verified_at,null);assert.equal(verified.rows[0].mobile_verified_at,null);
  console.log('PASS public registration, assigned ID, duplicate-safe retry, conflict feedback, real sign-in, own profile and admin denial');
 }finally{
  const records=await db.query('SELECT u.id,m.distributor_id FROM identity.users u LEFT JOIN control.distributor_users m ON m.user_id=u.id WHERE u.email=$1',[email]);
  for(const row of records.rows){
   await db.query('DELETE FROM identity.refresh_tokens WHERE session_id IN (SELECT id FROM identity.sessions WHERE user_id=$1)',[row.id]);
   await db.query('DELETE FROM identity.sessions WHERE user_id=$1',[row.id]);
   await db.query('DELETE FROM control.platform_audit_logs WHERE user_id=$1',[row.id]);
   await db.query('DELETE FROM control.usage_summaries WHERE distributor_id=$1',[row.distributor_id]);
   await db.query('DELETE FROM control.distributor_users WHERE user_id=$1',[row.id]);
   await db.query('DELETE FROM control.distributors WHERE id=$1',[row.distributor_id]);
   await db.query('DELETE FROM identity.users WHERE id=$1',[row.id]);
  }
  await db.end();console.log('Temporary signup verification account removed.');
 }
})().catch(e=>{console.error('Signup verification failed:',e.message);process.exitCode=1;});
