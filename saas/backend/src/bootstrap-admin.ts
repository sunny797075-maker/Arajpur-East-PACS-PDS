import { Pool } from 'pg';
import { z } from 'zod';
import { hashPassword } from './security';
// One-time development bootstrap; production admin MFA is deliberately not bypassed.
async function main() {
    if (process.env.NODE_ENV === 'production')
        throw new Error('Use an approved production administrator enrollment and MFA workflow.');
    const config = z.object({ MIGRATION_DATABASE_URL: z.string().url(), BOOTSTRAP_ADMIN_EMAIL: z.string().email(), BOOTSTRAP_ADMIN_MOBILE: z.string().regex(/^\+[1-9]\d{6,14}$/), BOOTSTRAP_ADMIN_PASSWORD: z.string().min(16).max(128), BOOTSTRAP_ADMIN_NAME: z.string().min(1) }).parse(process.env);
    const pool = new Pool({ connectionString: config.MIGRATION_DATABASE_URL });
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        const password = await hashPassword(config.BOOTSTRAP_ADMIN_PASSWORD);
        const inserted = await client.query("INSERT INTO identity.users(email,mobile,name,password_hash,email_verified_at,mobile_verified_at,status) VALUES($1,$2,$3,$4,now(),now(),'ACTIVE') RETURNING id", [config.BOOTSTRAP_ADMIN_EMAIL.toLowerCase(), config.BOOTSTRAP_ADMIN_MOBILE, config.BOOTSTRAP_ADMIN_NAME, password]);
        await client.query("INSERT INTO identity.user_roles(user_id,role_id) VALUES($1,'SUPER_ADMIN')", [inserted.rows[0].id]);
        await client.query("INSERT INTO control.platform_audit_logs(user_id,action,reason) VALUES($1,'DEVELOPMENT_ADMIN_CREATED','Explicit development bootstrap')", [inserted.rows[0].id]);
        await client.query('COMMIT');
        console.log('Development platform administrator created. Existing accounts were not overwritten.');
    }
    catch (error) {
        await client.query('ROLLBACK');
        throw error;
    }
    finally {
        client.release();
        await pool.end();
    }
}
main().catch(() => { console.error('Administrator bootstrap failed. Check development environment values and unique contact details.'); process.exitCode = 1; });

