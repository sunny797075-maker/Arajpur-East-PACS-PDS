import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';
import { Database } from '../src/database';
import { Principal } from '../src/auth.service';
import { Workflows } from '../src/workflows';
import { PlatformController } from '../src/platform';

test('live workflows preserve monthly history, enforce ownership, attendance limits and payment approval',async()=>{
 const engine=new PGlite();
 try{
  await engine.exec(await readFile('../database/001_schema.sql','utf8'));
  await engine.exec(await readFile('../database/002_workflows.sql','utf8'));
  const a=randomUUID(),b=randomUUID(),ua=randomUUID(),ub=randomUUID(),admin=randomUUID();
  await engine.query("INSERT INTO identity.users(id,name,email,password_hash,status) VALUES($1,'Admin','admin@test.invalid','hash','ACTIVE')",[admin]);
  for(const [id,uid,email] of [[a,ua,'a@test.invalid'],[b,ub,'b@test.invalid']]){
   await engine.query("INSERT INTO identity.users(id,name,email,password_hash,status) VALUES($1,'Owner',$2,'hash','ACTIVE')",[uid,email]);
   await engine.query(`INSERT INTO control.distributors(id,organization_name,organization_type,owner_name,email,mobile,state,district,block,panchayat,village,address,pin_code,status) VALUES($1,'Shop','INDEPENDENT','Owner',$2,'+919999999999','Bihar','District','Block','Panchayat','Village','Address','853204','ACTIVE')`,[id,email]);
   await engine.query("INSERT INTO control.distributor_users(distributor_id,user_id,role_id,status) VALUES($1,$2,'DISTRIBUTOR','ACTIVE')",[id,uid]);
  }
  const client={query:async(sql:string,args?:unknown[])=>{const r=await engine.query(sql,args);return {...r,rowCount:r.rows.length || r.affectedRows || 0};}};
  const platformPool={};
  const tx=async(role:string,work:(c:any)=>Promise<any>,id?:string)=>{
   await engine.exec('BEGIN');
   try{await engine.exec(`SET LOCAL ROLE ${role}`);if(id)await engine.query("SELECT set_config('app.distributor_id',$1,true)",[id]);const result=await work(client);await engine.exec('COMMIT');return result;}catch(e){await engine.exec('ROLLBACK');throw e;}
  };
  const db={platform:platformPool,withinTenant:(id:string,_uid:string,work:(c:any)=>Promise<any>)=>tx('pds_tenant',work,id),transaction:(_pool:unknown,work:(c:any)=>Promise<any>)=>tx('pds_platform',work)} as unknown as Database;
  const w=new Workflows(db),platform=new PlatformController(db);
  const pa={userId:ua,distributorId:a} as Principal,pb={userId:ub,distributorId:b} as Principal;
  const approval={principal:{userId:admin} as Principal};
  await assert.rejects(()=>w.beneficiaries(pa,{month:'2026-09'}),/Subscription expired/);
  await platform.approve(a,{days:30,reason:'Manual approval without payment'},approval);
  await platform.approve(b,{days:30,reason:'Manual approval without payment'},approval);
  const values={cardNumber:'00123',name:'Family A',mobile:'9999999999',units:4,category:'PHH',address:'Road',village:'Village'};
  const family=await w.tenant(pa,c=>w.saveBeneficiary(c,pa,values));
  const other=await w.tenant(pb,c=>w.saveBeneficiary(c,pb,{...values,name:'Family B'}));
  assert.equal((await w.beneficiaries(pa,{month:'2026-09'})).rows.length,1);
  await assert.rejects(()=>w.tenant(pa,c=>w.saveBeneficiary(c,pa,{...values,cardNumber:'HACK'},other.id)),/not found/);
  await assert.rejects(()=>w.distribute(pa,{beneficiaryId:other.id,month:'2026-08',commandId:randomUUID()}),/not found/);
  const command={beneficiaryId:family.id,month:'2026-08',commandId:randomUUID()};
  const first=await w.distribute(pa,command);const retry=await w.distribute(pa,command);
  assert.equal(first.id,retry.id);
  assert.equal((await w.distribute(pa,{...command,commandId:randomUUID()})).id,first.id);
  assert.equal((await w.beneficiaries(pa,{month:'2026-08',filter:'REMAINING'})).total,0);
  assert.equal((await w.beneficiaries(pa,{month:'2026-09',filter:'REMAINING'})).total,1);
  await w.distribute(pa,{...command,month:'2026-09',commandId:randomUUID()});
  await w.tenant(pa,c=>w.saveBeneficiary(c,pa,{...values,name:'Updated name'},family.id));
  const snapshot=await engine.query<{beneficiary_snapshot:any}>('SELECT beneficiary_snapshot FROM tenant.pds_transactions WHERE id=$1',[first.id]);
  assert.equal(snapshot.rows[0]!.beneficiary_snapshot.name,'Family A');
  assert.equal((await w.overview(pa,'2026-09')).distributed,1);
  const staff=[];
  for(let n=0;n<3;n++)staff.push(await w.saveStaff(pa,{name:'Staff '+n,mobile:'9999999999',workDetails:'Distribution',active:true}));
  await assert.rejects(()=>w.saveStaff(pa,{name:'Fourth',mobile:'9999999999',workDetails:'Distribution',active:true}),/maximum/);
  const mark={staffId:staff[0].id,date:'2026-09-01',status:'PRESENT'};
  await w.attendance(pa,mark);await w.attendance(pa,{...mark,status:'ABSENT'});
  assert.equal((await engine.query('SELECT * FROM tenant.attendance')).rows.length,1);
  await assert.rejects(()=>w.attendance(pb,mark),/not found/);
  await tx('pds_platform',async c=>{await assert.rejects(()=>c.query('SELECT * FROM tenant.staff'));});
  const plan=(await engine.query<{id:string}>("INSERT INTO control.subscription_plans(name,price_paise,billing_days) VALUES('Monthly',9900,30) RETURNING id")).rows[0]!;
  const payment=await platform.payment(a,{planId:plan.id,reference:'RECEIPT-1',reason:'Cash received at office'},approval);
  const repeat=await platform.payment(a,{planId:plan.id,reference:'RECEIPT-1',reason:'Cash received at office'},approval);
  assert.equal(payment.id,repeat.id);
  assert.equal((await engine.query('SELECT * FROM control.payments')).rows.length,1);
  assert.equal((await engine.query("SELECT * FROM control.access_grants WHERE source='PAYMENT'")).rows.length,1);
 }finally{await engine.close();}
});

