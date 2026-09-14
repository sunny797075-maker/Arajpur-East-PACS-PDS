import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';
test('PostgreSQL schema enforces tenant isolation, composite ownership and admin exclusion', async () => {
    const db = new PGlite();
    try {
        await db.exec(await readFile('../database/001_schema.sql', 'utf8'));
        const sequenceFormat = await db.query<{
            code: string;
        }>("SELECT control.display_code('BEN',1000000) AS code");
        assert.equal(sequenceFormat.rows[0]!.code, 'BEN-1000000', 'human identifiers must not truncate after one million');
        const a = '00000000-0000-4000-8000-000000000001', b = '00000000-0000-4000-8000-000000000002';
        for (const id of [a, b])
            await db.query(`INSERT INTO control.distributors(id,organization_name,organization_type,owner_name,email,mobile,state,district,block,panchayat,village,address,pin_code,status)
      VALUES($1,'Independent shop','INDEPENDENT','Owner','owner@example.org','+919876543210','Bihar','Madhepura','Chausa','Arajpur','Arajpur','Market','853204','ACTIVE')`, [id]);
        await db.query("INSERT INTO tenant.beneficiaries(distributor_id,name,card_number) VALUES($1,'Family A','SAME-RC'),($2,'Family B','SAME-RC')", [a, b]);
        await db.exec('SET ROLE pds_tenant');
        assert.equal((await db.query('SELECT * FROM tenant.beneficiaries')).rows.length, 0);
        await db.exec('BEGIN');
        await db.query("SELECT set_config('app.distributor_id',$1,true)", [a]);
        const rows = await db.query<{
            name: string;
        }>('SELECT name FROM tenant.beneficiaries');
        assert.deepEqual(rows.rows, [{ name: 'Family A' }]);
        assert.equal((await db.query('SELECT * FROM tenant.beneficiaries WHERE distributor_id=$1', [b])).rows.length, 0);
        await assert.rejects(() => db.query("INSERT INTO tenant.beneficiaries(distributor_id,name,card_number) VALUES($1,'Intruder','X')", [b]));
        await db.exec('ROLLBACK');
        assert.equal((await db.query('SELECT * FROM tenant.beneficiaries')).rows.length, 0, 'transaction context must clear on rollback');
        await db.exec('SET ROLE pds_platform');
        assert.equal((await db.query('SELECT * FROM control.distributors')).rows.length, 2);
        await assert.rejects(() => db.query('SELECT * FROM tenant.beneficiaries'));
        await db.exec('RESET ROLE');
        const beneficiary = await db.query<{
            id: string;
        }>('SELECT id FROM tenant.beneficiaries WHERE distributor_id=$1', [a]);
        const product = await db.query<{
            id: string;
        }>("INSERT INTO tenant.products(distributor_id,name,unit) VALUES($1,'Millet','kg') RETURNING id", [b]);
        await assert.rejects(() => db.query("INSERT INTO tenant.allocations(distributor_id,beneficiary_id,product_id,month,quantity) VALUES($1,$2,$3,'2026-09-01',5)", [b, beneficiary.rows[0]!.id, product.rows[0]!.id]));
        await db.exec('SET ROLE pds_tenant');
        await assert.rejects(() => db.query('DELETE FROM tenant.audit_logs'));
    }
    finally {
        await db.close();
    }
});

