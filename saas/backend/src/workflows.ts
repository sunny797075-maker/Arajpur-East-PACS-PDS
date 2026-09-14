import { Body, Controller, Delete, Get, HttpException, Inject, Param, Patch, Post, Query, Req, SetMetadata } from '@nestjs/common';
import { Request } from 'express';
import { PoolClient } from 'pg';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { Database } from './database';
import { Principal } from './auth.service';

const Access = (permission: string) => SetMetadata('permission', permission);
type SignedRequest = Request & { principal: Principal };
const text = (max: number) => z.string().trim().min(1).max(max);
export const beneficiaryInput = z.object({cardNumber:text(80),name:text(150),mobile:z.string().regex(/^\+?[1-9]\d{9,14}$/),units:z.number().int().min(1).max(100),category:z.enum(['PHH','AAY']),address:z.string().trim().max(500).default(''),village:z.string().trim().max(100).default('')}).strict();
const staffInput = z.object({name:text(100),mobile:z.string().regex(/^\+?[1-9]\d{9,14}$/),workDetails:text(250),active:z.boolean()}).strict();
export const monthInput = z.string().regex(/^20\d{2}-(0[1-9]|1[0-2])$/);
const today = () => new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Kolkata',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
const dateInput = z.string().regex(/^20\d{2}-\d{2}-\d{2}$/).refine(v=>!Number.isNaN(Date.parse(v)) && new Date(v).toISOString().slice(0,10)===v && v<=today(),'Choose a valid date, no later than today.');
export class Workflows {
 constructor(readonly db:Database) {}
 tenant<T>(p:Principal,work:(c:PoolClient)=>Promise<T>,requireAccess=true) {
  return this.db.withinTenant(p.distributorId!,p.userId,async c=>{
   if(requireAccess && !(await c.query('SELECT 1 FROM control.access_grants WHERE distributor_id=$1 AND expires_at>now() LIMIT 1',[p.distributorId])).rowCount) throw new HttpException('Subscription expired or awaiting approval. Contact the platform administrator.',403);
   return work(c);
  });
 }
 async audit(c:PoolClient,p:Principal,action:string,module:string,id:string) {
  await c.query('INSERT INTO tenant.audit_logs(distributor_id,user_id,action,module,record_id) VALUES($1,$2,$3,$4,$5)',[p.distributorId,p.userId,action,module,id]);
 }
 async overview(p:Principal,month:string) {
  monthInput.parse(month);
  return this.tenant(p,async c=>{
   const metrics=(await c.query(`SELECT
    (SELECT count(*)::int FROM tenant.beneficiaries WHERE deleted_at IS NULL) AS total,
    (SELECT count(*)::int FROM tenant.beneficiaries b WHERE deleted_at IS NULL AND EXISTS(SELECT 1 FROM tenant.pds_transactions t WHERE t.beneficiary_id=b.id AND t.month=$1::date)) AS distributed,
    (SELECT count(*)::int FROM tenant.pds_transactions WHERE (recorded_at AT TIME ZONE 'Asia/Kolkata')::date=$2::date) AS today,
    (SELECT count(*)::int FROM tenant.staff WHERE active) AS staff,
    (SELECT count(*)::int FROM tenant.attendance WHERE attendance_date=$2::date AND status='PRESENT') AS present`,[month+'-01',today()])).rows[0];
   const access=(await c.query("SELECT source,expires_at FROM control.access_grants WHERE distributor_id=$1 ORDER BY expires_at DESC LIMIT 1",[p.distributorId])).rows[0]??null;
   return {...metrics,remaining:metrics.total-metrics.distributed,access,serverDate:today()};
  },false);
 }
 async beneficiaries(p:Principal,query:unknown) {
  const q=z.object({month:monthInput,search:z.string().max(100).default(''),filter:z.enum(['ALL','DISTRIBUTED','REMAINING']).default('ALL'),page:z.coerce.number().int().min(1).max(100000).default(1)}).strict().parse(query);
  return this.tenant(p,async c=>{
   const where=`b.deleted_at IS NULL AND (b.name ILIKE $2 OR b.card_number ILIKE $2 OR b.mobile ILIKE $2) AND ($3='ALL' OR ($3='DISTRIBUTED' AND t.id IS NOT NULL) OR ($3='REMAINING' AND t.id IS NULL))`;
   const args=[q.month+'-01',`%${q.search.replace(/[\\%_]/g,'\\$&')}%`,q.filter];
   const join='FROM tenant.beneficiaries b LEFT JOIN tenant.pds_transactions t ON t.distributor_id=b.distributor_id AND t.beneficiary_id=b.id AND t.month=$1::date';
   const rows=(await c.query(`SELECT b.*,t.recorded_at AS distributed_at,t.receipt_number ${join} WHERE ${where} ORDER BY b.name,b.id LIMIT 50 OFFSET $4`,[...args,(q.page-1)*50])).rows;
   const count=(await c.query(`SELECT count(*)::int AS total ${join} WHERE ${where}`,args)).rows[0].total;
   return {rows,total:count,page:q.page};
  });
 }
 async saveBeneficiary(c:PoolClient,p:Principal,raw:unknown,id?:string) {
  const v=beneficiaryInput.parse(raw);
  // Serialize writes per distributor, including import/delete, without accepting a tenant ID from the client.
  await c.query('SELECT pg_advisory_xact_lock(hashtext($1))',[p.distributorId]);
  if((await c.query('SELECT 1 FROM tenant.beneficiaries WHERE card_number=$1 AND ($2::uuid IS NULL OR id<>$2)',[v.cardNumber,id??null])).rowCount) throw new HttpException(`Ration card ${v.cardNumber} already exists (including archived cards).`,409);
  const args=[v.name,v.mobile,v.cardNumber,v.units,v.category,v.address,v.village,p.distributorId];
  const result=id ? await c.query(`UPDATE tenant.beneficiaries SET name=$1,head_name=$1,mobile=$2,card_number=$3,family_members=$4,category=$5,address=$6,village=$7,updated_at=now() WHERE distributor_id=$8 AND id=$9 AND deleted_at IS NULL RETURNING *`,[...args,id]) : await c.query(`INSERT INTO tenant.beneficiaries(name,head_name,mobile,card_number,family_members,category,address,village,distributor_id) VALUES($1,$1,$2,$3,$4,$5,$6,$7,$8) RETURNING *`,args);
  if(!result.rowCount) throw new HttpException('Beneficiary not found.',404);
  await this.audit(c,p,id?'BENEFICIARY_UPDATED':'BENEFICIARY_ADDED','beneficiaries',result.rows[0].id);
  return result.rows[0];
 }
 async distribute(p:Principal,body:unknown) {
  const v=z.object({beneficiaryId:z.string().uuid(),month:monthInput,commandId:z.string().uuid()}).strict().parse(body);
  if(v.month>today().slice(0,7)) throw new HttpException('Future cycles cannot be distributed.',400);
  return this.tenant(p,async c=>{
   const beneficiary=(await c.query('SELECT * FROM tenant.beneficiaries WHERE id=$1 AND deleted_at IS NULL FOR UPDATE',[v.beneficiaryId])).rows[0];
   if(!beneficiary) throw new HttpException('Beneficiary not found.',404);
   const prior=(await c.query('SELECT * FROM tenant.pds_transactions WHERE command_id=$1',[v.commandId])).rows[0];
   if(prior && (prior.beneficiary_id!==v.beneficiaryId || String(prior.month).slice(0,7)!==v.month)) {
    // pg may return DATE as Date; use an explicit SQL comparison below instead.
    if(!(await c.query('SELECT 1 FROM tenant.pds_transactions WHERE command_id=$1 AND beneficiary_id=$2 AND month=$3::date',[v.commandId,v.beneficiaryId,v.month+'-01'])).rowCount) throw new HttpException('Transaction key already used for another distribution.',409);
   }
   const existing=(await c.query('SELECT * FROM tenant.pds_transactions WHERE beneficiary_id=$1 AND month=$2::date',[v.beneficiaryId,v.month+'-01'])).rows[0];
   if(existing) return existing;
   const result=(await c.query(`INSERT INTO tenant.pds_transactions(distributor_id,beneficiary_id,month,command_id,receipt_number,recorded_by,beneficiary_snapshot) VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING *`,[p.distributorId,v.beneficiaryId,v.month+'-01',v.commandId,'PDS-'+randomUUID(),p.userId,JSON.stringify(beneficiary)])).rows[0];
   await this.audit(c,p,'DISTRIBUTED','distribution',result.id); return result;
  });
 }
 async saveStaff(p:Principal,body:unknown,id?:string) {
  const v=staffInput.parse(body);
  return this.tenant(p,async c=>{
   await c.query('SELECT pg_advisory_xact_lock(hashtext($1))',[p.distributorId]);
   if(v.active && (await c.query('SELECT count(*)::int AS n FROM tenant.staff WHERE active AND ($1::uuid IS NULL OR id<>$1)',[id??null])).rows[0].n>=3) throw new HttpException('A maximum of three active staff members is allowed. Deactivate a member first.',409);
   const args=[v.name,v.mobile,v.workDetails,v.active,p.distributorId];
   const result=id?await c.query('UPDATE tenant.staff SET name=$1,mobile=$2,work_details=$3,active=$4,updated_at=now() WHERE distributor_id=$5 AND id=$6 RETURNING *',[...args,id]):await c.query('INSERT INTO tenant.staff(name,mobile,work_details,active,distributor_id) VALUES($1,$2,$3,$4,$5) RETURNING *',args);
   if(!result.rowCount) throw new HttpException('Staff member not found.',404);
   await this.audit(c,p,'STAFF_SAVED','staff',result.rows[0].id); return result.rows[0];
  });
 }
 async attendance(p:Principal,body:unknown) {
  const v=z.object({staffId:z.string().uuid(),date:dateInput,status:z.enum(['PRESENT','ABSENT'])}).strict().parse(body);
  return this.tenant(p,async c=>{
   if(!(await c.query('SELECT 1 FROM tenant.staff WHERE id=$1 AND active FOR UPDATE',[v.staffId])).rowCount) throw new HttpException('Active staff member not found.',404);
   const r=(await c.query(`INSERT INTO tenant.attendance(distributor_id,staff_id,attendance_date,status,recorded_by) VALUES($1,$2,$3,$4,$5) ON CONFLICT(distributor_id,staff_id,attendance_date) DO UPDATE SET status=excluded.status,recorded_by=excluded.recorded_by,updated_at=now() RETURNING *`,[p.distributorId,v.staffId,v.date,v.status,p.userId])).rows[0];
   await this.audit(c,p,'ATTENDANCE_'+v.status,'attendance',r.id);return r;
  });
 }
}

@Controller('work')
export class WorkController {
 private readonly work:Workflows;
 constructor(@Inject('DATABASE') db:Database){this.work=new Workflows(db);}
 @Get('overview') @Access('profile.read') overview(@Req() r:SignedRequest,@Query('month') month:string){return this.work.overview(r.principal,month);}
 @Get('beneficiaries') @Access('beneficiaries.read') list(@Req() r:SignedRequest,@Query() q:unknown){return this.work.beneficiaries(r.principal,q);}
 @Post('beneficiaries') @Access('beneficiaries.write') add(@Req() r:SignedRequest,@Body() b:unknown){return this.work.tenant(r.principal,c=>this.work.saveBeneficiary(c,r.principal,b));}
 @Patch('beneficiaries/:id') @Access('beneficiaries.write') edit(@Req() r:SignedRequest,@Param('id') id:string,@Body() b:unknown){z.string().uuid().parse(id);return this.work.tenant(r.principal,c=>this.work.saveBeneficiary(c,r.principal,b,id));}
 @Delete('beneficiaries/:id') @Access('beneficiaries.write') remove(@Req() r:SignedRequest,@Param('id') id:string){z.string().uuid().parse(id);return this.work.tenant(r.principal,async c=>{
  const result=await c.query("UPDATE tenant.beneficiaries SET deleted_at=now(),status='INACTIVE',updated_at=now() WHERE id=$1 AND deleted_at IS NULL RETURNING id",[id]);
  if(!result.rowCount) throw new HttpException('Beneficiary not found.',404);
  await this.work.audit(c,r.principal,'BENEFICIARY_ARCHIVED','beneficiaries',id); return {ok:true};
 });}
 @Post('import') @Access('beneficiaries.import') import(@Req() r:SignedRequest,@Body() b:unknown){
  const v=z.object({rows:z.array(beneficiaryInput).min(1).max(500),fileName:text(200),preview:z.boolean()}).strict().parse(b);
  return this.work.tenant(r.principal,async c=>{
   await c.query('SELECT pg_advisory_xact_lock(hashtext($1))',[r.principal.distributorId]);
   const seen=new Set<string>();const errors:string[]=[];
   const existing=new Set((await c.query('SELECT card_number FROM tenant.beneficiaries WHERE card_number=ANY($1::text[])',[v.rows.map(row=>row.cardNumber)])).rows.map(row=>row.card_number));
   v.rows.forEach((row,i)=>{if(seen.has(row.cardNumber)||existing.has(row.cardNumber)) errors.push(`Row ${i+2}: duplicate card ${row.cardNumber}`);seen.add(row.cardNumber);});
   if(v.preview || errors.length) return {valid:!errors.length,errors,imported:0,total:v.rows.length};
   for(const row of v.rows) await this.work.saveBeneficiary(c,r.principal,row);
   return {valid:true,errors:[],imported:v.rows.length,total:v.rows.length};
  });
 }
 @Post('distribute') @Access('pds.operate') distribute(@Req() r:SignedRequest,@Body() b:unknown){return this.work.distribute(r.principal,b);}
 @Get('staff') @Access('staff.manage') staff(@Req() r:SignedRequest){return this.work.tenant(r.principal,async c=>(await c.query('SELECT * FROM tenant.staff ORDER BY active DESC,name,id')).rows);}
 @Post('staff') @Access('staff.manage') addStaff(@Req() r:SignedRequest,@Body() b:unknown){return this.work.saveStaff(r.principal,b);}
 @Patch('staff/:id') @Access('staff.manage') editStaff(@Req() r:SignedRequest,@Body() b:unknown,@Param('id') id:string){z.string().uuid().parse(id);return this.work.saveStaff(r.principal,b,id);}
 @Get('attendance') @Access('staff.manage') history(@Req() r:SignedRequest,@Query('month') month:string){monthInput.parse(month);return this.work.tenant(r.principal,async c=>(await c.query(`SELECT a.*,s.name FROM tenant.attendance a JOIN tenant.staff s ON s.distributor_id=a.distributor_id AND s.id=a.staff_id WHERE attendance_date >= $1::date AND attendance_date < $1::date+interval '1 month' ORDER BY attendance_date DESC,s.name`,[month+'-01'])).rows);}
 @Post('attendance') @Access('staff.manage') mark(@Req() r:SignedRequest,@Body() b:unknown){return this.work.attendance(r.principal,b);}
}
