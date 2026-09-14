// Creates isolated verification tenants, exercises HTTPS endpoints, then removes only its own fixtures.
const {Pool}=require('/opt/pds/api/node_modules/pg');
const {hashPassword}=require('/opt/pds/api/dist/security');
const {randomUUID,randomBytes}=require('node:crypto');
const assert=require('node:assert/strict');
(async()=>{
 const db=new Pool({host:'/var/run/postgresql',database:'pds_saas',user:'postgres'});
 const users=[],tenants=[],tokens=[];const password=randomBytes(24).toString('base64url');const hash=await hashPassword(password);
 async function api(token,method,path,body,expected=200){
  const response=await fetch('https://15.252.37.89/api/v1/'+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},...(body?{body:JSON.stringify(body)}:{})});
  const data=await response.json();assert.equal(response.status,expected,method+' '+path+': '+JSON.stringify(data));return data;
 }
 try{
  for(let n=0;n<2;n++){
   const uid=randomUUID(),tid=randomUUID(),code='DIST-91000000'+n;users.push(uid);tenants.push(tid);const email='workflow-'+uid+'@example.invalid';
   await db.query("INSERT INTO identity.users(id,name,password_hash,status,email) VALUES($1,'Workflow verification',$2,'ACTIVE',$3)",[uid,hash,email]);
   await db.query(`INSERT INTO control.distributors(id,distributor_id,organization_name,organization_type,owner_name,email,mobile,state,district,block,panchayat,village,address,pin_code,status) VALUES($1,$2,'Workflow verification','INDEPENDENT','Test','test@example.invalid','+919999999999','Test','Test','Test','Test','Test','Temporary test','000000','ACTIVE')`,[tid,code]);
   await db.query("INSERT INTO control.distributor_users(distributor_id,user_id,role_id) VALUES($1,$2,'DISTRIBUTOR')",[tid,uid]);
   await db.query("INSERT INTO control.access_grants(distributor_id,source,expires_at,reason) VALUES($1,'MANUAL',now()+interval '1 day','Temporary workflow verification')",[tid]);
   tokens.push((await api(null,'POST','auth/distributor/login',{identifier:email,password,clientType:'NATIVE',rememberMe:false},201)).accessToken);
  }
  const month=new Date().toISOString().slice(0,7),previous=new Date(new Date().getFullYear(),new Date().getMonth()-1,15).toISOString().slice(0,7);
  const values={cardNumber:'00001',name:'Test family',mobile:'9999999999',units:4,category:'PHH',address:'Test address',village:'Test'};
  const a=await api(tokens[0],'POST','work/beneficiaries',values,201);
  const b=await api(tokens[1],'POST','work/beneficiaries',values,201);
  assert.equal((await api(tokens[0],'GET','work/beneficiaries?month='+month)).total,1);
  await api(tokens[0],'PATCH','work/beneficiaries/'+b.id,{...values,cardNumber:'FOREIGN'},404);
  await api(tokens[0],'GET','platform/distributors',null,403);
  await api(tokens[0],'POST','work/distribute',{beneficiaryId:b.id,month,commandId:randomUUID()},404);
  const sale={beneficiaryId:a.id,month,commandId:randomUUID()};
  const first=await api(tokens[0],'POST','work/distribute',sale,201);
  assert.equal((await api(tokens[0],'POST','work/distribute',sale,201)).id,first.id);
  assert.equal((await api(tokens[0],'GET','work/beneficiaries?month='+month+'&filter=REMAINING')).total,0);
  assert.equal((await api(tokens[0],'GET','work/beneficiaries?month='+previous+'&filter=REMAINING')).total,1);
  assert.equal((await api(tokens[0],'GET','work/overview?month='+month)).distributed,1);
  const staff=await api(tokens[0],'POST','work/staff',{name:'Test staff',mobile:'9999999999',workDetails:'Distribution',active:true},201);
  const attendance={staffId:staff.id,date:month+'-01',status:'PRESENT'};
  await api(tokens[0],'POST','work/attendance',attendance,201);
  await api(tokens[0],'POST','work/attendance',{...attendance,status:'ABSENT'},201);
  assert.equal((await api(tokens[0],'GET','work/attendance?month='+month)).length,1);
  await api(tokens[1],'POST','work/attendance',attendance,404);
  const batch={fileName:'verification.csv',rows:[{...values,cardNumber:'00002'}],preview:true};
  assert.equal((await api(tokens[0],'POST','work/import',batch,201)).valid,true);
  assert.equal((await api(tokens[0],'POST','work/import',{...batch,preview:false},201)).imported,1);
  assert.equal((await api(tokens[0],'POST','work/import',batch,201)).valid,false);
  await api(tokens[0],'DELETE','work/beneficiaries/'+a.id);
  assert.equal((await db.query('SELECT * FROM tenant.pds_transactions WHERE distributor_id=$1',[tenants[0]])).rows.length,1);
  console.log('PASS HTTPS beneficiary CRUD/import, monthly distribution/retry, remaining list, metrics, staff/attendance and tenant isolation.');
 }finally{
  for(const table of ['attendance','staff','audit_logs','pds_transactions','beneficiaries'])await db.query('DELETE FROM tenant.'+table+' WHERE distributor_id=ANY($1::uuid[])',[tenants]);
  await db.query('DELETE FROM control.access_grants WHERE distributor_id=ANY($1::uuid[])',[tenants]);
  await db.query('DELETE FROM identity.refresh_tokens WHERE session_id IN(SELECT id FROM identity.sessions WHERE user_id=ANY($1::uuid[]))',[users]);
  await db.query('DELETE FROM identity.sessions WHERE user_id=ANY($1::uuid[])',[users]);
  await db.query('DELETE FROM control.platform_audit_logs WHERE user_id=ANY($1::uuid[])',[users]);
  await db.query('DELETE FROM control.distributor_users WHERE user_id=ANY($1::uuid[])',[users]);
  await db.query('DELETE FROM control.distributors WHERE id=ANY($1::uuid[])',[tenants]);
  await db.query('DELETE FROM identity.users WHERE id=ANY($1::uuid[])',[users]);await db.end();
  console.log('Temporary workflow fixtures removed.');
 }
})().catch(e=>{console.error('Workflow verification failed:',e.message);process.exitCode=1;});
