import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';
import { AuthService } from '../src/auth.service';
import { Database } from '../src/database';
import { Config } from '../src/config';
import { Delivery } from '../src/delivery';
const values = { email: 'owner@example.org', mobile: '+919876543210', password: 'correct horse battery staple', confirmPassword: 'correct horse battery staple', termsVersion: 'test-terms', acceptTerms: true,
    organization: { organizationName: 'Independent Shop', organizationType: 'INDEPENDENT', ownerName: 'Owner', state: 'Bihar', district: 'Madhepura', block: 'Chausa', panchayat: 'Arajpur', village: 'Arajpur', address: 'Market Road', pinCode: '853204' } };
test('authentication: verify once, require approval, revoke replayed refresh families and reset all sessions', async () => {
    const engine = new PGlite();
    try {
        await engine.exec(await readFile('../database/001_schema.sql', 'utf8'));
        await engine.exec('SET ROLE pds_auth');
        const query = async (sql: string, args: unknown[] = []) => {
            const result = await engine.query(sql, args);
            return { rows: result.rows, rowCount: /^\s*(SELECT|WITH)/i.test(sql) ? result.rows.length : result.affectedRows };
        };
        const facade = { query };
        const database = { auth: facade, transaction: async (_pool: unknown, work: (client: typeof facade) => Promise<unknown>) => {
                await engine.exec('BEGIN');
                try {
                    const result = await work(facade);
                    await engine.exec('COMMIT');
                    return result;
                }
                catch (error) {
                    await engine.exec('ROLLBACK');
                    throw error;
                }
            } } as unknown as Database;
        const delivered: {
            target: string;
            code: string;
        }[] = [];
        const delivery = { send: async (target: string, _channel: string, code: string) => { delivered.push({ target, code }); } } as unknown as Delivery;
        const config = { NODE_ENV: 'test', JWT_SECRET: 'a'.repeat(64), TOKEN_PEPPER: 'b'.repeat(64), OTP_PEPPER: 'c'.repeat(64), JWT_ISSUER: 'pds-test', JWT_AUDIENCE: 'pds-test-client', TERMS_VERSION: 'test-terms' } as Config;
        const auth = new AuthService(database, config, delivery);
        await auth.initialize();
        const registered = await auth.register(values, '127.0.0.1');
        assert.equal(delivered.length, 1);
        const code = delivered[0]!.code;
        await assert.rejects(() => auth.verify({ challengeId: registered.challengeId, code: code === '000000' ? '111111' : '000000' }, '127.0.0.1'));
        assert.equal((await engine.query<{
            attempts: number;
        }>('SELECT attempts FROM identity.otp_challenges WHERE id=$1', [registered.challengeId])).rows[0]!.attempts, 1, 'failed OTP attempts must commit');
        const verified = await auth.verify({ challengeId: registered.challengeId, code }, '127.0.0.1');
        assert.match(verified.distributorCode!, /^DIST-\d{6,}$/);
        await assert.rejects(() => auth.verify({ challengeId: registered.challengeId, code }, '127.0.0.1'));
        assert.equal((await engine.query('SELECT * FROM control.distributors')).rows.length, 1, 'OTP replay must not create another organization');
        const credentials = { identifier: values.email, password: values.password, clientType: 'NATIVE' };
        await assert.rejects(() => auth.login(credentials, '127.0.0.1'), /PENDING_APPROVAL/);
        await engine.query("UPDATE control.distributors SET status='ACTIVE'");
        const distributorSession = await auth.login({identifier: values.email.toUpperCase(), password: values.password, clientType:'NATIVE', rememberMe:true}, '127.0.0.1', 'DISTRIBUTOR');
        for (const identifier of [values.mobile, values.mobile.slice(3), values.mobile.slice(1)]) {
            const mobileSession = await auth.login({identifier,password:values.password,clientType:'NATIVE'},'127.0.0.1','DISTRIBUTOR');
            assert.equal((await auth.principal(mobileSession.accessToken)).distributorId,(await auth.principal(distributorSession.accessToken)).distributorId);
        }
        await assert.rejects(()=>auth.login({identifier:verified.distributorCode,password:values.password,clientType:'NATIVE'},'127.0.0.1','DISTRIBUTOR'),/Invalid credentials/);
        const view = await auth.presentation(distributorSession);
        assert.equal(view.role, 'DISTRIBUTOR');
        assert.equal(view.distributorId, verified.distributorCode);
        assert.equal(view.profile?.distributorId, verified.distributorCode);
        assert.equal(view.profile?.organizationName, values.organization.organizationName);
        assert.equal(view.profile?.phone, values.mobile);
        assert.equal(view.rememberMe, true);
        await assert.rejects(() => auth.login(credentials, '127.0.0.1', 'SUPER_ADMIN'), /Invalid credentials/);
        const session = await auth.login(credentials, '127.0.0.1');
        const principal = await auth.principal(session.accessToken);
        assert.ok(principal.distributorId);
        assert.equal(principal.platformAdmin, false);
        assert.ok(principal.permissions.includes('profile.write'));
        await engine.query("UPDATE control.distributors SET status='SUSPENDED'");
        await assert.rejects(() => auth.principal(session.accessToken), /disabled/);
        await engine.query("UPDATE control.distributors SET status='ACTIVE'");
        const rotated = await auth.refresh(session.refreshToken, undefined, false);
        assert.notEqual(rotated.refreshToken, session.refreshToken);
        await assert.rejects(() => auth.refresh(session.refreshToken, undefined, false), /reused/);
        await assert.rejects(() => auth.principal(rotated.accessToken), /ended/);
        const second = await auth.login(credentials, '127.0.0.1');
        const reset = await auth.requestChallenge({ identifier: values.email }, 'RESET', '127.0.0.1');
        const newPassword = 'an entirely different long password';
        await auth.reset({ challengeId: reset.challengeId, code: delivered.at(-1)!.code, password: newPassword, confirmPassword: newPassword }, '127.0.0.1');
        await assert.rejects(() => auth.principal(second.accessToken), /ended/);
        await assert.rejects(() => auth.login(credentials, '127.0.0.1'), /Invalid credentials/);
        const final = await auth.login({ ...credentials, password: newPassword }, '127.0.0.1');
        await auth.logout(await auth.principal(final.accessToken), true, '127.0.0.1');
        await assert.rejects(() => auth.principal(final.accessToken));
        const web = await auth.login({ ...credentials, password: newPassword, clientType: 'WEB' }, '127.0.0.1');
        await assert.rejects(() => auth.refresh(web.refreshToken, 'incorrect-csrf', true), /CSRF/);
        const webRotated = await auth.refresh(web.refreshToken, web.csrfToken, true);
        await assert.rejects(() => auth.refresh(web.refreshToken, web.csrfToken, true), /reused/);
        await assert.rejects(() => auth.principal(webRotated.accessToken), /ended/);
        const signup = {email:'new-owner@example.org',mobile:'+919876543211',password:values.password,confirmPassword:values.password,
            organization:{...values.organization,organizationName:'New Distributor'}};
        await assert.rejects(() => auth.registerDistributor({...signup,role:'SUPER_ADMIN'},'127.0.0.2'));
        const created=await auth.registerDistributor(signup,'127.0.0.2');
        assert.match(created.distributorId,/^DIST-\d+$/);
        const repeated=await auth.registerDistributor(signup,'127.0.0.2');
        assert.equal(repeated.distributorId,created.distributorId,'registration retries must not create a second account');
        const newlySignedIn=await auth.login({identifier:signup.email,password:signup.password,clientType:'NATIVE'},'127.0.0.2','DISTRIBUTOR');
        assert.equal((await auth.presentation(newlySignedIn)).profile?.organizationName,'New Distributor');
        const contact=await engine.query<{email_verified_at:unknown,mobile_verified_at:unknown}>('SELECT email_verified_at,mobile_verified_at FROM identity.users WHERE email=$1',[signup.email]);
        assert.equal(contact.rows[0]!.email_verified_at,null);
        assert.equal(contact.rows[0]!.mobile_verified_at,null);
        await assert.rejects(() => auth.registerDistributor({...signup,password:'different secure password',confirmPassword:'different secure password'},'127.0.0.2'),/already uses/);
        const other=await auth.registerDistributor({...signup,email:'other-owner@example.org',mobile:'+919876543212'},'127.0.0.3');
        assert.notEqual(other.distributorId,created.distributorId);
    }
    finally {
        await engine.close();
    }
});
