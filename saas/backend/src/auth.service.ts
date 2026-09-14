import { ForbiddenException, HttpException, UnauthorizedException } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import jwt from 'jsonwebtoken';
import { PoolClient } from 'pg';
import { z } from 'zod';
import { Config } from './config';
import { Database } from './database';
import { Delivery } from './delivery';
import { digest, equalDigest, hashPassword, opaqueToken, otpCode, verifyPassword } from './security';
import * as input from './validation';
export interface Principal {
    userId: string;
    sessionId: string;
    distributorId: string | null;
    platformAdmin: boolean;
    permissions: string[];
    clientType: 'WEB' | 'NATIVE';
}
type Challenge = {
    challengeId: string;
    code: string;
    target: string;
    channel: 'EMAIL' | 'MOBILE';
};
type Tokens = {
    accessToken: string;
    refreshToken: string;
    csrfToken: string;
    expiresIn: number;
    clientType: 'WEB' | 'NATIVE';
};
export class AuthService {
    private dummyHash = '';
    constructor(readonly db: Database, readonly config: Config, private readonly delivery: Delivery) { }
    async initialize() { this.dummyHash = await hashPassword(opaqueToken()); }
    async throttle(key: string, limit: number, seconds: number) {
        const result = await this.db.auth.query(`INSERT INTO identity.rate_limits(key,hits,expires_at) VALUES($1,1,now()+$2*interval '1 second')
      ON CONFLICT(key) DO UPDATE SET hits=CASE WHEN identity.rate_limits.expires_at<=now() THEN 1 ELSE identity.rate_limits.hits+1 END,
      expires_at=CASE WHEN identity.rate_limits.expires_at<=now() THEN excluded.expires_at ELSE identity.rate_limits.expires_at END RETURNING hits`, [digest(key, this.config.TOKEN_PEPPER), seconds]);
        if (result.rows[0].hits > limit)
            throw new HttpException('Too many requests. Try again later.', 429);
    }
    private async audit(client: PoolClient, action: string, userId: string | null, tenant: string | null, ip: string) {
        await client.query('INSERT INTO control.platform_audit_logs(user_id,distributor_id,action,ip) VALUES($1,$2,$3,$4)', [userId, tenant, action, ip]);
    }
    private async issueChallenge(client: PoolClient, user: {
        id: string;
        email: string;
        mobile: string;
    }, purpose: string): Promise<Challenge> {
        const id = randomUUID(), code = otpCode();
        await client.query('UPDATE identity.otp_challenges SET consumed_at=now() WHERE user_id=$1 AND purpose=$2 AND consumed_at IS NULL', [user.id, purpose]);
        await client.query("INSERT INTO identity.otp_challenges(id,user_id,purpose,digest,expires_at) VALUES($1,$2,$3,$4,now()+interval '10 minutes')", [id, user.id, purpose, digest(`${id}:${code}`, this.config.OTP_PEPPER)]);
        return { challengeId: id, code, target: purpose === 'VERIFY_MOBILE' ? user.mobile : user.email, channel: purpose === 'VERIFY_MOBILE' ? 'MOBILE' : 'EMAIL' };
    }
    private async deliver(challenge: Challenge | null) {
        if (challenge) {
            try {
                await this.delivery.send(challenge.target, challenge.channel, challenge.code);
            }
            catch {
                throw new HttpException('Verification delivery is temporarily unavailable. Use resend to request a new code.', 503);
            }
        }
        return { challengeId: challenge?.challengeId ?? randomUUID(), message: 'If the account is eligible, a verification code has been sent.' };
    }
    async register(body: unknown, ip: string) {
        const value = input.registration.parse(body);
        if (value.termsVersion !== this.config.TERMS_VERSION)
            throw new HttpException('Please accept the current terms version.', 400);
        await this.throttle(`register:${value.email}`, 3, 3600);
        const passwordHash = await hashPassword(value.password);
        let challenge: Challenge | null = null;
        try {
            challenge = await this.db.transaction(this.db.auth, async (client) => {
                const type = await client.query('SELECT * FROM control.organization_types WHERE id=$1 AND active=true', [value.organization.organizationType]);
                if (!type.rowCount)
                    throw new HttpException('Choose an active organization type.', 400);
                const user = await client.query('INSERT INTO identity.users(email,mobile,name,password_hash) VALUES($1,$2,$3,$4) RETURNING id,email,mobile', [value.email, value.mobile, value.organization.ownerName, passwordHash]);
                await client.query('INSERT INTO identity.pending_registrations(user_id,organization,terms_version) VALUES($1,$2,$3)', [user.rows[0].id, value.organization, value.termsVersion]);
                await this.audit(client, 'REGISTRATION', user.rows[0].id, null, ip);
                return this.issueChallenge(client, user.rows[0], 'VERIFY_EMAIL');
            });
        }
        catch (error) {
            if ((error as {
                code?: string;
            }).code !== '23505')
                throw error;
        }
        return this.deliver(challenge);
    }
    async requestChallenge(body: unknown, purpose: 'RESET' | 'VERIFY', ip: string) {
        const value = purpose === 'RESET' ? input.forgot.parse(body) : input.resend.parse(body);
        const identifier = value.identifier.toLowerCase();
        await this.throttle(`${purpose}:${identifier}`, 3, 3600);
        const challenge = await this.db.transaction(this.db.auth, async (client) => {
            const found = await client.query('SELECT * FROM identity.users WHERE email=$1 OR mobile=$1', [identifier]);
            const user = found.rows[0];
            if (!user || user.status === 'DISABLED')
                return null;
            const channel = 'channel' in value ? value.channel : 'EMAIL';
            if (purpose === 'RESET' && !user.email_verified_at)
                return null;
            if (purpose === 'VERIFY' && (channel === 'EMAIL' ? user.email_verified_at : user.mobile_verified_at))
                return null;
            await this.audit(client, purpose === 'RESET' ? 'PASSWORD_RESET_REQUEST' : 'OTP_RESEND', user.id, null, ip);
            return this.issueChallenge(client, user, purpose === 'RESET' ? 'PASSWORD_RESET' : channel === 'MOBILE' ? 'VERIFY_MOBILE' : 'VERIFY_EMAIL');
        });
        return this.deliver(challenge);
    }
    private async consume(client: PoolClient, id: string, code: string, purposes: string[]) {
        const result = await client.query('SELECT *,expires_at>now() AS valid_time FROM identity.otp_challenges WHERE id=$1 FOR UPDATE', [id]);
        const challenge = result.rows[0];
        if (!challenge || challenge.consumed_at || !challenge.valid_time || challenge.attempts >= 5 || !purposes.includes(challenge.purpose))
            return null;
        await client.query('UPDATE identity.otp_challenges SET attempts=attempts+1 WHERE id=$1', [id]);
        if (!equalDigest(challenge.digest, digest(`${id}:${code}`, this.config.OTP_PEPPER)))
            return null;
        await client.query('UPDATE identity.otp_challenges SET consumed_at=now() WHERE id=$1', [id]);
        return challenge;
    }
    async registerDistributor(body: unknown, ip: string) {
        const value = input.selfRegistration.parse(body);
        await this.throttle(`signup-ip:${ip}`, 10, 3600);
        await this.throttle(`signup-email:${value.email}`, 5, 3600);
        // A retried request with the same credentials returns the assigned ID,
        // without changing the existing password or profile.
        const recover = async () => {
            const found = await this.db.auth.query(`SELECT u.password_hash,d.distributor_id
              FROM identity.users u JOIN control.distributor_users m ON m.user_id=u.id
              JOIN control.distributors d ON d.id=m.distributor_id
              WHERE u.email=$1 AND u.mobile=$2 AND m.role_id='DISTRIBUTOR'`, [value.email,value.mobile]);
            if (found.rows[0] && await verifyPassword(value.password, found.rows[0].password_hash))
                return {distributorId: found.rows[0].distributor_id, message:'Your Distributor ID is ready. Sign in with your password.'};
            return null;
        };
        const existing = await recover();
        if (existing) return existing;
        const passwordHash = await hashPassword(value.password);
        try {
            return await this.db.transaction(this.db.auth, async client => {
                const org=value.organization;
                const type=await client.query('SELECT id FROM control.organization_types WHERE id=$1 AND active=true',[org.organizationType]);
                if (!type.rowCount) throw new HttpException('Choose an available organization type.',400);
                const user=await client.query("INSERT INTO identity.users(email,mobile,name,password_hash,status) VALUES($1,$2,$3,$4,'ACTIVE') RETURNING id",[value.email,value.mobile,org.ownerName,passwordHash]);
                const tenant=await client.query(`INSERT INTO control.distributors(organization_name,organization_type,custom_type,owner_name,email,mobile,state,district,block,panchayat,village,address,pin_code,pds_registration_number,license_number,gst_number,pacs_code,status)
                  VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,'ACTIVE') RETURNING id,distributor_id`,
                  [org.organizationName,org.organizationType,org.customType??null,org.ownerName,value.email,value.mobile,org.state,org.district,org.block,org.panchayat,org.village,org.address,org.pinCode,org.pdsRegistrationNumber??null,org.licenseNumber??null,org.gstNumber??null,org.pacsCode??null]);
                await client.query("INSERT INTO control.distributor_users(distributor_id,user_id,role_id) VALUES($1,$2,'DISTRIBUTOR')",[tenant.rows[0].id,user.rows[0].id]);
                await client.query('INSERT INTO control.usage_summaries(distributor_id,users_count) VALUES($1,1)',[tenant.rows[0].id]);
                await this.audit(client,'DISTRIBUTOR_SELF_REGISTERED',user.rows[0].id,tenant.rows[0].id,ip);
                // Contact verification timestamps remain NULL. No email or OTP
                // delivery, verification claim or subscription is fabricated.
                return {distributorId:tenant.rows[0].distributor_id,message:'Account created. Save your Distributor ID and sign in.'};
            });
        } catch(error) {
            if ((error as {code?:string}).code === '23505') {
                const retry=await recover();
                if(retry) return retry;
                throw new HttpException('An account already uses this email or mobile. Use your existing credentials or contact the platform owner.',409);
            }
            throw error;
        }
    }
    async verify(body: unknown, ip: string) {
        const value = input.challenge.parse(body);
        const result = await this.db.transaction(this.db.auth, async (client) => {
            const challenge = await this.consume(client, value.challengeId, value.code, ['VERIFY_EMAIL', 'VERIFY_MOBILE']);
            if (!challenge)
                return null;
            const column = challenge.purpose === 'VERIFY_EMAIL' ? 'email_verified_at' : 'mobile_verified_at';
            const user = await client.query(`UPDATE identity.users SET ${column}=now(),status='ACTIVE' WHERE id=$1 AND status<>'DISABLED' RETURNING *`, [challenge.user_id]);
            if (!user.rowCount)
                return null;
            const pending = await client.query('SELECT * FROM identity.pending_registrations WHERE user_id=$1 FOR UPDATE', [challenge.user_id]);
            let distributorCode: string | undefined;
            if (pending.rows[0] && !pending.rows[0].provisioned_at) {
                const org = input.organization.parse(pending.rows[0].organization);
                const tenant = await client.query(`INSERT INTO control.distributors(organization_name,organization_type,custom_type,owner_name,email,mobile,state,district,block,panchayat,village,address,pin_code,pds_registration_number,license_number,gst_number,pacs_code)
          VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17) RETURNING id,distributor_id`, [org.organizationName, org.organizationType, org.customType ?? null, org.ownerName, user.rows[0].email, user.rows[0].mobile, org.state, org.district, org.block, org.panchayat, org.village, org.address, org.pinCode, org.pdsRegistrationNumber ?? null, org.licenseNumber ?? null, org.gstNumber ?? null, org.pacsCode ?? null]);
                await client.query("INSERT INTO control.distributor_users(distributor_id,user_id,role_id) VALUES($1,$2,'DISTRIBUTOR')", [tenant.rows[0].id, challenge.user_id]);
                await client.query('INSERT INTO control.usage_summaries(distributor_id,users_count) VALUES($1,1)', [tenant.rows[0].id]);
                await client.query('UPDATE identity.pending_registrations SET provisioned_at=now() WHERE user_id=$1', [challenge.user_id]);
                distributorCode = tenant.rows[0].distributor_id;
                await this.audit(client, 'DISTRIBUTOR_CREATED', challenge.user_id, tenant.rows[0].id, ip);
            }
            await this.audit(client, 'CONTACT_VERIFIED', challenge.user_id, null, ip);
            return { verified: true, distributorCode, message: distributorCode ? 'Contact verified. Your distributor account is awaiting approval.' : 'Contact verified.' };
        });
        // Throw after COMMIT so failed-attempt increments cannot roll back.
        if (!result)
            throw new HttpException('Invalid or expired verification code.', 400);
        return result;
    }
    private access(userId: string, sessionId: string) { return jwt.sign({ sid: sessionId }, this.config.JWT_SECRET, { algorithm: 'HS256', subject: userId, issuer: this.config.JWT_ISSUER, audience: this.config.JWT_AUDIENCE, expiresIn: '10m' }); }
    async login(body: unknown, ip: string, expectedRole?: 'SUPER_ADMIN' | 'DISTRIBUTOR'): Promise<Tokens> {
        const value = input.login.parse(body);
        let identifier = value.identifier.toLowerCase();
        if (expectedRole === 'DISTRIBUTOR') {
            if (identifier.includes('@')) {
                if (!z.string().email().safeParse(identifier).success) throw new UnauthorizedException('Invalid credentials.');
            } else {
                identifier = identifier.replace(/[\s()-]/g, '');
                if (/^[6-9]\d{9}$/.test(identifier)) identifier = '+91' + identifier;
                else if (/^91[6-9]\d{9}$/.test(identifier)) identifier = '+' + identifier;
                if (!/^\+[1-9]\d{6,14}$/.test(identifier)) throw new UnauthorizedException('Invalid credentials.');
            }
        }
        await this.throttle(`login:${identifier}`, 10, 900);
        const found = expectedRole === 'DISTRIBUTOR'
            ? await this.db.auth.query(`SELECT u.* FROM identity.users u JOIN control.distributor_users m ON m.user_id=u.id WHERE (u.email=$1 OR u.mobile=$1) AND m.role_id='DISTRIBUTOR'`, [identifier])
            : await this.db.auth.query('SELECT * FROM identity.users WHERE email=$1 OR mobile=$1 OR lower(admin_id)=$1', [identifier]);
        const candidate = found.rows[0];
        const valid = await verifyPassword(value.password, candidate?.password_hash ?? this.dummyHash);
        if (!candidate || !valid)
            throw new UnauthorizedException('Invalid credentials.');
        return this.db.transaction(this.db.auth, async (client) => {
            const locked = await client.query('SELECT * FROM identity.users WHERE id=$1 FOR UPDATE', [candidate.id]);
            const user = locked.rows[0];
            if (user.password_hash !== candidate.password_hash)
                throw new UnauthorizedException('Credentials changed. Please retry.');
            if (user.status !== 'ACTIVE' || (!expectedRole && !(identifier.includes('@') ? user.email_verified_at : user.mobile_verified_at)))
                throw new ForbiddenException('Verify your contact or check account status before logging in.');
            const superRole = await client.query("SELECT 1 FROM identity.user_roles WHERE user_id=$1 AND role_id='SUPER_ADMIN'", [user.id]);
            if ((expectedRole === 'SUPER_ADMIN' && !superRole.rowCount) || (expectedRole === 'DISTRIBUTOR' && superRole.rowCount))
                throw new UnauthorizedException('Invalid credentials.');
            let tenantId: string | null = null;
            if (!superRole.rowCount) {
                const memberships = await client.query(`SELECT m.distributor_id,d.status FROM control.distributor_users m JOIN control.distributors d ON d.id=m.distributor_id
          WHERE m.user_id=$1 AND m.status='ACTIVE' AND m.role_id='DISTRIBUTOR' AND ($2::text IS NULL OR d.distributor_id=$2)`, [user.id, expectedRole === 'DISTRIBUTOR' ? null : value.organizationCode ?? null]);
                if (memberships.rows.length !== 1)
                    throw new ForbiddenException('Choose an organization assigned to your account.');
                if (memberships.rows[0].status !== 'ACTIVE')
                    throw new ForbiddenException(`Distributor account is ${memberships.rows[0].status}.`);
                tenantId = memberships.rows[0].distributor_id;
            }
            const id = randomUUID(), refreshToken = opaqueToken(), csrfToken = opaqueToken();
            const expires = new Date(Date.now() + (value.rememberMe ? 30 * 86400000 : 8 * 3600000));
            await client.query('INSERT INTO identity.sessions(id,user_id,distributor_id,client_type,csrf_digest,expires_at,remember_me) VALUES($1,$2,$3,$4,$5,$6,$7)', [id, user.id, tenantId, value.clientType, digest(csrfToken, this.config.TOKEN_PEPPER), expires, value.rememberMe]);
            await client.query('INSERT INTO identity.refresh_tokens(digest,session_id,expires_at) VALUES($1,$2,$3)', [digest(refreshToken, this.config.TOKEN_PEPPER), id, expires]);
            await client.query('UPDATE identity.users SET last_login_at=now() WHERE id=$1', [user.id]);
            await this.audit(client, 'LOGIN', user.id, tenantId, ip);
            return { accessToken: this.access(user.id, id), refreshToken, csrfToken, expiresIn: 600, clientType: value.clientType };
        });
    }
    async principal(accessToken: string): Promise<Principal> {
        let claims: jwt.JwtPayload;
        try {
            claims = jwt.verify(accessToken, this.config.JWT_SECRET, { algorithms: ['HS256'], issuer: this.config.JWT_ISSUER, audience: this.config.JWT_AUDIENCE }) as jwt.JwtPayload;
        }
        catch {
            throw new UnauthorizedException('Invalid or expired session.');
        }
        if (typeof claims.sub !== 'string' || typeof claims.sid !== 'string' || !z.string().uuid().safeParse(claims.sid).success || !z.string().uuid().safeParse(claims.sub).success)
            throw new UnauthorizedException();
        return this.loadPrincipal(claims.sub, claims.sid);
    }
    private async loadPrincipal(userId: string, sessionId: string, client?: PoolClient): Promise<Principal> {
        const connection = client ?? this.db.auth;
        const result = await connection.query(`SELECT s.*,u.status AS user_status,m.role_id,m.permissions,m.status AS member_status,d.status AS account_status,
      EXISTS(SELECT 1 FROM identity.user_roles r WHERE r.user_id=u.id AND r.role_id='SUPER_ADMIN') AS platform_admin
      FROM identity.sessions s JOIN identity.users u ON u.id=s.user_id
      LEFT JOIN control.distributor_users m ON m.distributor_id=s.distributor_id AND m.user_id=s.user_id
      LEFT JOIN control.distributors d ON d.id=s.distributor_id
      WHERE s.id=$1 AND s.user_id=$2 AND s.revoked_at IS NULL AND s.expires_at>now()`, [sessionId, userId]);
        const row = result.rows[0];
        if (!row || row.user_status !== 'ACTIVE')
            throw new UnauthorizedException('Session has ended.');
        if (row.distributor_id && (row.member_status !== 'ACTIVE' || row.account_status !== 'ACTIVE'))
            throw new ForbiddenException('Distributor access is disabled.');
        if (!row.distributor_id && !row.platform_admin)
            throw new ForbiddenException();
        const permissions = row.role_id === 'DISTRIBUTOR' ? (await connection.query('SELECT permission_id FROM identity.role_permissions WHERE role_id=$1', [row.role_id])).rows.map(p => p.permission_id) : row.permissions ?? [];
        return { userId, sessionId, distributorId: row.distributor_id, platformAdmin: row.platform_admin && !row.distributor_id, permissions, clientType: row.client_type };
    }
    async presentation(tokens: Tokens) {
        const principal = await this.principal(tokens.accessToken);
        const result = await this.db.auth.query(`SELECT coalesce(d.organization_name,u.name) AS name,d.distributor_id,d.organization_name,d.address,d.block,d.district,d.state,d.pin_code,d.mobile,s.remember_me,s.expires_at FROM identity.sessions s JOIN identity.users u ON u.id=s.user_id LEFT JOIN control.distributors d ON d.id=s.distributor_id WHERE s.id=$1`, [principal.sessionId]);
        const row = result.rows[0];
        return { userId: principal.userId, name: row.name, role: principal.platformAdmin ? 'SUPER_ADMIN' : 'DISTRIBUTOR', distributorId: row.distributor_id ?? null,
            profile: principal.platformAdmin ? null : { distributorId: row.distributor_id, organizationName: row.organization_name,
                address: [...new Set([row.address,row.block,row.district,row.state,row.pin_code].filter(Boolean))].join(', '), phone: row.mobile },
            accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, expiresAt: new Date(Date.now() + tokens.expiresIn * 1000).toISOString(),
            rememberMe: row.remember_me, maxAge: Math.max(0, new Date(row.expires_at).getTime() - Date.now()) };
    }
    async refresh(refreshToken: string, csrfToken: string | undefined, viaCookie: boolean): Promise<Tokens> {
        const result = await this.db.transaction(this.db.auth, async (client) => {
            const found = await client.query(`SELECT t.*,s.user_id,s.client_type,s.csrf_digest,s.revoked_at,s.expires_at>now() AS session_valid
        FROM identity.refresh_tokens t JOIN identity.sessions s ON s.id=t.session_id WHERE t.digest=$1 FOR UPDATE OF t,s`, [digest(refreshToken, this.config.TOKEN_PEPPER)]);
            const token = found.rows[0];
            if (!token || token.revoked_at || !token.session_valid || new Date(token.expires_at) <= new Date())
                return null;
            if ((token.client_type === 'WEB') !== viaCookie)
                throw new UnauthorizedException();
            if (token.consumed_at) {
                await client.query('UPDATE identity.sessions SET revoked_at=now() WHERE id=$1', [token.session_id]);
                return null;
            }
            if (viaCookie && (!csrfToken || !equalDigest(token.csrf_digest, digest(csrfToken, this.config.TOKEN_PEPPER))))
                throw new ForbiddenException('Invalid CSRF token.');
            await this.loadPrincipal(token.user_id, token.session_id, client);
            const replacement = opaqueToken(), csrf = opaqueToken();
            await client.query('UPDATE identity.refresh_tokens SET consumed_at=now() WHERE digest=$1', [token.digest]);
            await client.query('INSERT INTO identity.refresh_tokens(digest,session_id,expires_at) VALUES($1,$2,$3)', [digest(replacement, this.config.TOKEN_PEPPER), token.session_id, token.expires_at]);
            await client.query('UPDATE identity.sessions SET csrf_digest=$1 WHERE id=$2', [digest(csrf, this.config.TOKEN_PEPPER), token.session_id]);
            return { accessToken: this.access(token.user_id, token.session_id), refreshToken: replacement, csrfToken: csrf, expiresIn: 600, clientType: token.client_type };
        });
        if (!result)
            throw new UnauthorizedException('Refresh token expired or reused. Sign in again.');
        return result;
    }
    async reset(body: unknown, ip: string) {
        const value = input.reset.parse(body), hash = await hashPassword(value.password);
        const success = await this.db.transaction(this.db.auth, async (client) => {
            const challenge = await this.consume(client, value.challengeId, value.code, ['PASSWORD_RESET']);
            if (!challenge)
                return false;
            await client.query('UPDATE identity.users SET password_hash=$1 WHERE id=$2', [hash, challenge.user_id]);
            await client.query('UPDATE identity.sessions SET revoked_at=now() WHERE user_id=$1 AND revoked_at IS NULL', [challenge.user_id]);
            await this.audit(client, 'PASSWORD_RESET', challenge.user_id, null, ip);
            return true;
        });
        if (!success)
            throw new HttpException('Invalid or expired verification code.', 400);
        return { message: 'Password updated. Sign in again.' };
    }
    async logout(principal: Principal, all: boolean, ip: string) {
        await this.db.transaction(this.db.auth, async (client) => {
            await client.query(`UPDATE identity.sessions SET revoked_at=now() WHERE ${all ? 'user_id' : 'id'}=$1`, [all ? principal.userId : principal.sessionId]);
            await this.audit(client, all ? 'LOGOUT_ALL' : 'LOGOUT', principal.userId, principal.distributorId, ip);
        });
        return { message: 'Signed out.' };
    }
}
