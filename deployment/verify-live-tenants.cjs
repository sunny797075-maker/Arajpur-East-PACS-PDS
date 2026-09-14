// Temporary, explicitly marked verification fixtures; removed in finally.
const {Pool}=require('/opt/pds/api/node_modules/pg');
const {hashPassword}=require('/opt/pds/api/dist/security');
const {randomUUID,randomBytes}=require('node:crypto');
const assert=require('node:assert/strict');
(async()=>{
 const db=new Pool({host:'/var/run/postgresql',database:'pds_saas',user:'postgres'});
 const users=[], tenants=[];const secret=randomBytes(24).toString('base64url');
 const hash=await hashPassword(secret);
 try {
  for(let i=0;i<2;i++){
   const uid=randomUUID(),tid=randomUUID(),code='DIST-90000000'+(i+1);users.push(uid);tenants.push(tid);
   await db.query("INSERT INTO identity.users(id,name,password_hash,status,email) VALUES($1,'Deployment verification',$2,'ACTIVE',$3)",[uid,hash,'verify-'+uid+'@example.invalid']);
   await db.query(`INSERT INTO control.distributors(id,distributor_id,organization_name,organization_type,owner_name,email,mobile,state,district,block,panchayat,village,address,pin_code,status)
    VALUES($1,$2,$3,'INDEPENDENT','Verification fixture','verification@example.invalid','+910000000000','Test','Test','Test','Test','Test','Temporary automated test','000000','ACTIVE')`,[tid,code,'Verification '+i]);
   await db.query("INSERT INTO control.distributor_users(distributor_id,user_id,role_id) VALUES($1,$2,'DISTRIBUTOR')",[tid,uid]);
  }
  for(let i=0;i<2;i++){
   const code='DIST-90000000'+(i+1);
   const response=await fetch('https://15.252.37.89/api/v1/auth/distributor/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({identifier:'verify-'+users[i]+'@example.invalid',password:secret,clientType:'NATIVE',rememberMe:false})});
   const session=await response.json();assert.equal(response.status,201);assert.equal(session.distributorId,code);
   assert.equal(session.profile.distributorId,code);assert.equal(session.profile.organizationName,'Verification '+i);
   await db.query('UPDATE control.distributors SET organization_name=$1,mobile=$2 WHERE id=$3',['Updated verification '+i,'+91000000000'+i,tenants[i]]);
   const renewed=await fetch('https://15.252.37.89/api/v1/auth/refresh',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({refreshToken:session.refreshToken})});
   assert.equal(renewed.status,201);const renewedSession=await renewed.json();
   assert.equal(renewedSession.profile.organizationName,'Updated verification '+i);assert.equal(renewedSession.profile.phone,'+91000000000'+i);
   const headers={Authorization:'Bearer '+session.accessToken};
   const profile=await fetch('https://15.252.37.89/api/v1/distributor/me',{headers});assert.equal(profile.status,200);assert.equal((await profile.json()).id,tenants[i]);
   const denied=await fetch('https://15.252.37.89/api/v1/admin/distributors',{headers});assert.equal(denied.status,403);
   const client=await db.connect();
   try {await client.query('BEGIN');await client.query('SET LOCAL ROLE pds_tenant');await client.query("SELECT set_config('app.distributor_id',$1,true)",[tenants[i]]);
    assert.equal((await client.query('SELECT id FROM control.distributors')).rows.length,1);
    assert.equal((await client.query('SELECT id FROM control.distributors WHERE id=$1',[tenants[1-i]])).rows.length,0);
    await client.query('ROLLBACK');
   }finally{client.release();}
   await db.query("UPDATE control.distributors SET status='SUSPENDED' WHERE id=$1",[tenants[i]]);
   assert.equal((await fetch('https://15.252.37.89/api/v1/auth/me',{headers})).status,403);
  }
  console.log('PASS live distributor login, assigned ID/profile, platform denial, PostgreSQL tenant isolation and suspension');
 }finally{
  await db.query('DELETE FROM identity.refresh_tokens WHERE session_id IN (SELECT id FROM identity.sessions WHERE user_id=ANY($1::uuid[]))',[users]);
  await db.query('DELETE FROM identity.sessions WHERE user_id=ANY($1::uuid[])',[users]);
  await db.query('DELETE FROM control.platform_audit_logs WHERE user_id=ANY($1::uuid[])',[users]);
  await db.query('DELETE FROM control.distributor_users WHERE user_id=ANY($1::uuid[])',[users]);
  await db.query('DELETE FROM control.distributors WHERE id=ANY($1::uuid[])',[tenants]);
  await db.query('DELETE FROM identity.users WHERE id=ANY($1::uuid[])',[users]);await db.end();
  console.log('Temporary verification accounts removed.');
 }
})().catch(e=>{console.error('Tenant verification failed:',e.message);process.exitCode=1;});
