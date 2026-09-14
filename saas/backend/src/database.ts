import { Pool, PoolClient } from 'pg';
import { Config } from './config';
export class Database {
    readonly auth: Pool;
    readonly tenant: Pool;
    readonly platform: Pool;
    constructor(config: Config) {
        const pool = (connectionString: string) => new Pool({ connectionString, max: 3, connectionTimeoutMillis: 5000, idleTimeoutMillis: 30000, statement_timeout: 10000, ssl: config.DB_SSL === 'true' ? { rejectUnauthorized: true } : false });
        this.auth = pool(config.AUTH_DATABASE_URL);
        this.tenant = pool(config.TENANT_DATABASE_URL);
        this.platform = pool(config.PLATFORM_DATABASE_URL);
    }
    async verifyRoles() {
        for (const [pool, role] of [[this.auth, 'pds_auth'], [this.tenant, 'pds_tenant'], [this.platform, 'pds_platform']] as const) {
            const result = await pool.query('SELECT r.rolsuper,r.rolbypassrls,pg_has_role(current_user,$1,\'member\') AS member FROM pg_roles r WHERE r.rolname=current_user', [role]);
            const user = result.rows[0];
            if (!user || user.rolsuper || user.rolbypassrls || !user.member)
                throw new Error(`Unsafe or missing database role: ${role}`);
        }
        const owner = await this.tenant.query("SELECT 1 FROM pg_tables WHERE schemaname='tenant' AND tableowner=current_user LIMIT 1");
        if (owner.rowCount)
            throw new Error('Tenant connection cannot own operational tables.');
    }
    async transaction<T>(pool: Pool, work: (client: PoolClient) => Promise<T>): Promise<T> {
        const client = await pool.connect();
        try {
            await client.query('BEGIN');
            const result = await work(client);
            await client.query('COMMIT');
            return result;
        }
        catch (error) {
            await client.query('ROLLBACK');
            throw error;
        }
        finally {
            client.release();
        }
    }
    async withinTenant<T>(distributorId: string, userId: string, work: (client: PoolClient) => Promise<T>): Promise<T> {
        return this.transaction(this.tenant, async (client) => {
            await client.query("SELECT set_config('app.distributor_id',$1,true),set_config('app.user_id',$2,true)", [distributorId, userId]);
            return work(client);
        });
    }
    async close() { await Promise.all([this.auth.end(), this.tenant.end(), this.platform.end()]); }
}

