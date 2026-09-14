import { Body, Controller, Get, HttpException, Inject, Param, Patch, Post, Query, Req, SetMetadata } from '@nestjs/common';
import { z } from 'zod';
import { Database } from './database';
import { Principal } from './auth.service';
const note=z.string().trim().min(5).max(500);
@Controller('platform') @SetMetadata('permission','platform.manage')
export class PlatformController {
 constructor(@Inject('DATABASE') private readonly db:Database){}
 @Get('distributors') async distributors(@Query() raw:unknown){
  const q=z.object({page:z.coerce.number().int().min(1).default(1),search:z.string().max(100).default('')}).strict().parse(raw);
  const args=[`%${q.search}%`];
  const rows=(await this.db.platform.query(`SELECT d.*,g.source,g.expires_at,
   CASE WHEN EXISTS(SELECT 1 FROM control.payments p WHERE p.distributor_id=d.id AND p.status='SUCCESS' AND p.paid_at>=date_trunc('month',now())) THEN 'PAID' ELSE 'UNPAID' END AS payment_status,
   CASE WHEN d.status IN ('SUSPENDED','CLOSED') THEN d.status WHEN g.expires_at>now() THEN 'ACTIVE' ELSE 'AWAITING_APPROVAL' END AS access_status
   FROM control.distributors d LEFT JOIN LATERAL(SELECT source,expires_at FROM control.access_grants WHERE distributor_id=d.id ORDER BY expires_at DESC LIMIT 1) g ON true
   WHERE d.organization_name ILIKE $1 OR d.distributor_id ILIKE $1 ORDER BY d.created_at DESC,d.id LIMIT 50 OFFSET $2`,[...args,(q.page-1)*50])).rows;
  const total=(await this.db.platform.query('SELECT count(*)::int AS n FROM control.distributors WHERE organization_name ILIKE $1 OR distributor_id ILIKE $1',args)).rows[0].n;
  return {rows,total};
 }
 @Get('plans') async plans(){return (await this.db.platform.query('SELECT * FROM control.subscription_plans ORDER BY created_at DESC')).rows;}
 @Patch('plans/:id') async planStatus(@Param('id') id:string,@Body() raw:unknown){
  z.string().uuid().parse(id);const v=z.object({active:z.boolean()}).strict().parse(raw);
  const result=await this.db.platform.query('UPDATE control.subscription_plans SET active=$1 WHERE id=$2 RETURNING *',[v.active,id]);
  if(!result.rowCount)throw new HttpException('Plan not found.',404);return result.rows[0];
 }
 @Post('plans') async plan(@Body() raw:unknown){
  const v=z.object({name:z.string().trim().min(1).max(100),amountPaise:z.number().int().min(0).max(100000000),days:z.number().int().min(1).max(3660)}).strict().parse(raw);
  return (await this.db.platform.query('INSERT INTO control.subscription_plans(name,price_paise,billing_days) VALUES($1,$2,$3) RETURNING *',[v.name,v.amountPaise,v.days])).rows[0];
 }
 @Get('distributors/:id/history') async history(@Param('id') id:string){
  z.string().uuid().parse(id);
  return {payments:(await this.db.platform.query('SELECT id,amount_paise,currency,gateway,order_id,status,paid_at,created_at FROM control.payments WHERE distributor_id=$1 ORDER BY created_at DESC LIMIT 200',[id])).rows,
   approvals:(await this.db.platform.query('SELECT source,expires_at,reason,created_at FROM control.access_grants WHERE distributor_id=$1 ORDER BY created_at DESC LIMIT 200',[id])).rows};
 }
 @Post('distributors/:id/approve') async approve(@Param('id') id:string,@Body() raw:unknown,@Req() req:{principal:Principal}){
  z.string().uuid().parse(id);const v=z.object({days:z.number().int().min(1).max(3660),reason:note}).strict().parse(raw);
  return this.db.transaction(this.db.platform,async c=>{
   if(!(await c.query('SELECT id FROM control.distributors WHERE id=$1 FOR UPDATE',[id])).rowCount) throw new HttpException('Distributor not found.',404);
   const result=(await c.query(`INSERT INTO control.access_grants(distributor_id,source,expires_at,reason,created_by) VALUES($1,'MANUAL',greatest(now(),coalesce((SELECT max(expires_at) FROM control.access_grants WHERE distributor_id=$1),now()))+$2*interval '1 day',$3,$4) RETURNING *`,[id,v.days,v.reason,req.principal.userId])).rows[0];
   await c.query("UPDATE control.distributors SET status='ACTIVE',updated_at=now() WHERE id=$1",[id]);
   await c.query("INSERT INTO control.platform_audit_logs(user_id,distributor_id,action,reason) VALUES($1,$2,'MANUAL_ACCESS_APPROVED',$3)",[req.principal.userId,id,v.reason]);return result;
  });
 }
 // Explicit acknowledgement of money received, never an unauthenticated payment callback.
 @Post('distributors/:id/payment') async payment(@Param('id') id:string,@Body() raw:unknown,@Req() req:{principal:Principal}){
  z.string().uuid().parse(id);const v=z.object({planId:z.string().uuid(),reference:z.string().trim().min(3).max(100),reason:note}).strict().parse(raw);
  return this.db.transaction(this.db.platform,async c=>{
   if(!(await c.query('SELECT id FROM control.distributors WHERE id=$1 FOR UPDATE',[id])).rowCount) throw new HttpException('Distributor not found.',404);
   const plan=(await c.query('SELECT * FROM control.subscription_plans WHERE id=$1 AND active',[v.planId])).rows[0];
   if(!plan) throw new HttpException('Active plan not found.',404);
   const reference='MANUAL:'+v.reference;
   const prior=(await c.query('SELECT * FROM control.payments WHERE order_id=$1',[reference])).rows[0];
   if(prior){if(prior.distributor_id!==id || prior.plan_id!==v.planId) throw new HttpException('Receipt reference already used.',409);return prior;}
   const payment=(await c.query(`INSERT INTO control.payments(distributor_id,plan_id,amount_paise,currency,gateway,order_id,status,plan_snapshot,paid_at) VALUES($1,$2,$3,$4,'MANUAL_RECEIPT',$5,'SUCCESS',$6,now()) RETURNING *`,[id,plan.id,plan.price_paise,plan.currency,reference,JSON.stringify(plan)])).rows[0];
   await c.query(`INSERT INTO control.access_grants(distributor_id,source,expires_at,reason,created_by,payment_id) VALUES($1,'PAYMENT',greatest(now(),coalesce((SELECT max(expires_at) FROM control.access_grants WHERE distributor_id=$1),now()))+$2*interval '1 day',$3,$4,$5)`,[id,plan.billing_days,v.reason,req.principal.userId,payment.id]);
   await c.query("UPDATE control.distributors SET status='ACTIVE',updated_at=now() WHERE id=$1",[id]);
   await c.query("INSERT INTO control.platform_audit_logs(user_id,distributor_id,action,reason,record_id) VALUES($1,$2,'PAYMENT_RECEIPT_RECORDED',$3,$4)",[req.principal.userId,id,v.reason,payment.id]);return payment;
  });
 }
}
