import 'reflect-metadata';
import { Body, CanActivate, Catch, Controller, ExceptionFilter, ExecutionContext, Get, HttpException, Inject, Injectable, Module, Param, Patch, Post, Req, Res, SetMetadata, ArgumentsHost, ForbiddenException, UnauthorizedException } from '@nestjs/common';
import { APP_GUARD, NestFactory, Reflector } from '@nestjs/core';
import express, { Request, Response } from 'express';
import cookieParser from 'cookie-parser';
import helmet from 'helmet';
import { randomUUID } from 'node:crypto';
import { z, ZodError } from 'zod';
import { configuration } from './config';
import { Database } from './database';
import { Delivery } from './delivery';
import { AuthService, Principal } from './auth.service';
import * as input from './validation';
import { WorkController } from './workflows';
import { PlatformController } from './platform';
type SessionRequest = Request & {
    principal: Principal;
};
const Public = () => SetMetadata('public', true);
const Access = (permission: string) => SetMetadata('permission', permission);
const ip = (req: Request) => req.ip ?? req.socket.remoteAddress ?? '127.0.0.1';
@Injectable()
class SessionGuard implements CanActivate {
    constructor(
    @Inject('AUTH')
    private readonly auth: AuthService, private readonly reflector: Reflector) { }
    async canActivate(context: ExecutionContext) {
        const req = context.switchToHttp().getRequest<SessionRequest>();
        await this.auth.throttle(`ip:${ip(req)}`, 120, 60);
        if (this.reflector.getAllAndOverride<boolean>('public', [context.getHandler(), context.getClass()]))
            return true;
        const match = /^Bearer ([^ ]+)$/.exec(req.headers.authorization ?? '');
        if (!match?.[1])
            throw new UnauthorizedException();
        req.principal = await this.auth.principal(match[1]);
        const required = this.reflector.getAllAndOverride<string>('permission', [context.getHandler(), context.getClass()]);
        if (required === 'platform.manage') {
            if (!req.principal.platformAdmin)
                throw new ForbiddenException();
        }
        else if (required && (!req.principal.distributorId || !req.principal.permissions.includes(required))) {
            throw new ForbiddenException();
        }
        return true;
    }
}
@Catch()
class Errors implements ExceptionFilter {
    catch(error: unknown, host: ArgumentsHost) {
        const response = host.switchToHttp().getResponse<Response>();
        const status = error instanceof ZodError ? 400 : error instanceof HttpException ? error.getStatus() : 500;
        const message = error instanceof ZodError ? 'Invalid request fields.' : error instanceof HttpException ? error.message : 'The request could not be completed.';
        response.status(status).json({ error: message, requestId: response.getHeader('X-Request-ID'), ...(error instanceof ZodError ? { fields: error.issues.map(i => ({ path: i.path.join('.'), message: i.message })) } : {}) });
    }
}
@Controller('auth')
class AuthController {
    constructor(
    @Inject('AUTH')
    private readonly auth: AuthService) { }
    private origin(req: Request) {
        if (!this.auth.config.CORS_ORIGINS.split(',').map(s => s.trim()).includes(req.get('origin') ?? ''))
            throw new ForbiddenException('Untrusted web origin.');
    }
    private async tokens(tokens: Awaited<ReturnType<AuthService['login']>>, res: Response) {
        const { rememberMe, maxAge, ...view } = await this.auth.presentation(tokens);
        if (tokens.clientType === 'WEB') {
            const options = { secure: this.auth.config.NODE_ENV === 'production', sameSite: 'strict' as const, path: '/api/v1/auth', ...(rememberMe ? {maxAge} : {}) };
            res.cookie('pds_refresh', tokens.refreshToken, { ...options, httpOnly: true });
            res.cookie('pds_csrf', tokens.csrfToken, { ...options, path: '/', httpOnly: false });
            const { refreshToken: _, ...safe } = view;
            return safe;
        }
        return view;
    }
    @Post('register')
    @Public()
    register(
    @Body()
    body: unknown, 
    @Req()
    req: Request) { if (this.auth.config.MAIL_MODE === 'disabled') throw new HttpException('Registration is not enabled yet.', 503); return this.auth.register(body, ip(req)); }
    @Post('resend-otp')
    @Public()
    resend(
    @Body()
    body: unknown, 
    @Req()
    req: Request) { if (this.auth.config.MAIL_MODE === 'disabled') throw new HttpException('Verification delivery is not configured.', 503); return this.auth.requestChallenge(body, 'VERIFY', ip(req)); }
    @Post('verify-otp')
    @Public()
    async verify(
    @Body()
    body: unknown, 
    @Req()
    req: Request) { await this.auth.throttle(`verify:${ip(req)}`, 20, 900); return this.auth.verify(body, ip(req)); }
    @Post('forgot-password')
    @Public()
    forgot(
    @Body()
    body: unknown, 
    @Req()
    req: Request) { if (this.auth.config.MAIL_MODE === 'disabled') throw new HttpException('Recovery delivery is not configured.', 503); return this.auth.requestChallenge(body, 'RESET', ip(req)); }
    @Post('reset-password')
    @Public()
    async reset(
    @Body()
    body: unknown, 
    @Req()
    req: Request) { await this.auth.throttle(`reset:${ip(req)}`, 10, 900); return this.auth.reset(body, ip(req)); }
    @Post(':accountType/login')
    @Public()
    async login(
    @Param('accountType')
    accountType: string,
    @Body()
    body: unknown, 
    @Req()
    req: Request, 
    @Res({ passthrough: true })
    res: Response) {
        const type = z.enum(['super-admin','distributor']).parse(accountType);
        const value = input.login.omit({ organizationCode: true }).parse(body);
        if (value.clientType === 'WEB')
            this.origin(req);
        else if (req.get('origin') || req.get('sec-fetch-site'))
            throw new ForbiddenException('Browser clients must use web sessions.');
        return this.tokens(await this.auth.login(value, ip(req), type === 'super-admin' ? 'SUPER_ADMIN' : 'DISTRIBUTOR'), res);
    }
    @Post('distributor/register')
    @Public()
    async distributorRegistration(@Body() body: unknown, @Req() req: Request) {
        if (req.get('origin')) this.origin(req);
        return this.auth.registerDistributor(body, ip(req));
    }
    @Post(':accountType/forgot-password')
    @Public()
    async accountRecovery(@Param('accountType') accountType: string, @Body() body: unknown, @Req() req: Request) {
        z.enum(['super-admin','distributor']).parse(accountType);
        input.forgot.parse(body);
        await this.auth.throttle(`recovery:${ip(req)}`, 5, 900);
        throw new HttpException('Recovery delivery is not configured. Contact the platform owner.', 503);
    }
    @Post('refresh')
    @Public()
    async refresh(
    @Body()
    body: unknown, 
    @Req()
    req: Request, 
    @Res({ passthrough: true })
    res: Response) {
        const value = input.refresh.parse(body), cookie = req.cookies?.pds_refresh as string | undefined;
        if (cookie)
            this.origin(req);
        else if (req.get('origin') || req.get('sec-fetch-site'))
            throw new ForbiddenException('Web sessions require a refresh cookie.');
        const token = cookie ?? value.refreshToken;
        if (!token || token.length > 100)
            throw new UnauthorizedException();
        return this.tokens(await this.auth.refresh(token, req.get('x-csrf-token'), !!cookie), res);
    }
    @Get('me')
    me(
    @Req()
    req: SessionRequest) { return req.principal; }
    @Post('logout')
    async logout(
    @Req()
    req: SessionRequest, 
    @Res({ passthrough: true })
    res: Response) {
        if (req.principal.clientType === 'WEB') this.origin(req);
        const result = await this.auth.logout(req.principal, false, ip(req));
        res.clearCookie('pds_refresh', { path: '/api/v1/auth' });
        res.clearCookie('pds_csrf', { path: '/' });
        return result;
    }
    @Post('logout-all')
    async logoutAll(
    @Req()
    req: SessionRequest, 
    @Res({ passthrough: true })
    res: Response) {
        const result = await this.auth.logout(req.principal, true, ip(req));
        res.clearCookie('pds_refresh', { path: '/api/v1/auth' });
        res.clearCookie('pds_csrf', { path: '/' });
        return result;
    }
}
@Controller()
class FoundationController {
    constructor(
    @Inject('DATABASE')
    private readonly db: Database) { }
    @Get('health')
    @Public()
    async health() { await this.db.auth.query('SELECT 1'); return { status: 'ok', database: 'connected', service: 'pds-saas', phase: 'authentication-and-tenancy' }; }
    @Get('organization-types')
    @Public()
    async types() { return (await this.db.auth.query('SELECT id,name,requires_pacs FROM control.organization_types WHERE active=true ORDER BY name')).rows; }
    @Get('distributor/me')
    @Access('profile.read')
    profile(
    @Req()
    req: SessionRequest) { return this.db.withinTenant(req.principal.distributorId!, req.principal.userId, async (client) => (await client.query('SELECT * FROM control.distributors WHERE id=$1', [req.principal.distributorId])).rows[0]); }
    @Patch('distributor/me')
    @Access('profile.write')
    update(
    @Body()
    body: unknown, 
    @Req()
    req: SessionRequest) {
        const value = input.profileUpdate.parse(body);
        return this.db.withinTenant(req.principal.distributorId!, req.principal.userId, async (client) => {
            const result = await client.query(`UPDATE control.distributors SET organization_name=$1,contact_person=$2,state=$3,district=$4,block=$5,panchayat=$6,village=$7,address=$8,pin_code=$9,updated_at=now() WHERE id=$10 RETURNING *`, [value.organizationName, value.contactPerson, value.state, value.district, value.block, value.panchayat, value.village, value.address, value.pinCode, req.principal.distributorId]);
            await client.query("INSERT INTO tenant.audit_logs(distributor_id,user_id,action,module,record_id,ip) VALUES($1,$2,'PROFILE_UPDATED','profile',$1,$3)", [req.principal.distributorId, req.principal.userId, ip(req)]);
            return result.rows[0];
        });
    }
    @Get('admin/distributors')
    @Access('platform.manage')
    async distributors(
    @Req()
    req: Request) {
        const query = z.object({ page: z.coerce.number().int().min(1).max(10000).default(1), search: z.string().max(100).default('') }).strict().parse(req.query);
        return (await this.db.platform.query(`SELECT id,distributor_id,organization_name,organization_type,owner_name,mobile,email,district,state,status,created_at
      FROM control.distributors WHERE organization_name ILIKE $1 OR distributor_id ILIKE $1 ORDER BY created_at DESC,id LIMIT 50 OFFSET $2`, [`%${query.search}%`, (query.page - 1) * 50])).rows;
    }
    @Patch('admin/distributors/:id/status')
    @Access('platform.manage')
    account(
    @Param('id')
    id: string, 
    @Body()
    body: unknown, 
    @Req()
    req: SessionRequest) {
        z.string().uuid().parse(id);
        const value = input.statusUpdate.parse(body);
        return this.db.transaction(this.db.platform, async (client) => {
            const changed = await client.query('UPDATE control.distributors SET status=$1,updated_at=now() WHERE id=$2 RETURNING id,distributor_id,status', [value.status, id]);
            if (!changed.rowCount)
                throw new HttpException('Distributor not found.', 404);
            await client.query("INSERT INTO control.platform_audit_logs(user_id,distributor_id,action,reason,ip) VALUES($1,$2,'ACCOUNT_STATUS_CHANGED',$3,$4)", [req.principal.userId, id, value.reason, ip(req)]);
            return changed.rows[0];
        });
    }
}
async function bootstrap() {
    const config = configuration(), db = new Database(config);
    await db.verifyRoles();
    const auth = new AuthService(db, config, new Delivery(config));
    await auth.initialize();
    @Module({ controllers: [AuthController, FoundationController, WorkController, PlatformController], providers: [{ provide: 'AUTH', useValue: auth }, { provide: 'DATABASE', useValue: db }, { provide: APP_GUARD, useClass: SessionGuard }] })
    class AppModule {
    }
    const app = await NestFactory.create(AppModule, { bodyParser: false, logger: ['error', 'warn'] });
    app.setGlobalPrefix('api/v1');
    app.use(helmet());
    app.use(express.json({ limit: '1mb' }));
    app.use(cookieParser());
    app.use((_req: Request, res: Response, next: () => void) => { res.setHeader('X-Request-ID', randomUUID()); res.setHeader('Cache-Control', 'no-store'); next(); });
    app.enableCors({ origin: config.CORS_ORIGINS.split(',').map(s => s.trim()), credentials: true, allowedHeaders: ['Content-Type', 'Authorization', 'X-CSRF-Token', 'Idempotency-Key'] });
    app.useGlobalFilters(new Errors());
    app.enableShutdownHooks();
    process.once('SIGTERM', () => { void db.close(); });
    process.once('SIGINT', () => { void db.close(); });
    app.getHttpAdapter().getInstance().set('trust proxy', 'loopback');
    await app.listen(config.PORT, '127.0.0.1');
    console.log(`PDS foundation API listening on port ${config.PORT}`);
}
bootstrap().catch(() => { console.error('API startup failed. Verify configuration, database migrations and runtime role permissions.'); process.exitCode = 1; });

