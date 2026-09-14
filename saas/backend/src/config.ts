import { z } from 'zod';
const schema = z.object({
    NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
    PORT: z.coerce.number().int().min(1).max(65535).default(3000),
    AUTH_DATABASE_URL: z.string().url(), TENANT_DATABASE_URL: z.string().url(), PLATFORM_DATABASE_URL: z.string().url(),
    JWT_SECRET: z.string().min(64), TOKEN_PEPPER: z.string().min(64), OTP_PEPPER: z.string().min(64),
    JWT_ISSUER: z.string().default('pds-saas'), JWT_AUDIENCE: z.string().default('pds-clients'),
    CORS_ORIGINS: z.string().default('http://localhost:5173'),
    DB_SSL: z.enum(['true', 'false']).default('false'),
    MAIL_MODE: z.enum(['smtp', 'ses', 'disabled']).default('smtp'), MAIL_FROM: z.string().email(),
    SMTP_HOST: z.string().default('localhost'), SMTP_PORT: z.coerce.number().int().default(1025),
    AWS_REGION: z.string().default('ap-south-1'), TERMS_VERSION: z.string().min(1),
});
export type Config = z.infer<typeof schema>;
export function configuration(): Config {
    const result = schema.safeParse(process.env);
    if (!result.success)
        throw new Error(`Invalid environment fields: ${result.error.issues.map(i => i.path.join('.')).join(', ')}`);
    const value = result.data;
    const privateSocket = [value.AUTH_DATABASE_URL, value.TENANT_DATABASE_URL, value.PLATFORM_DATABASE_URL].every(url => new URL(url).searchParams.get('host') === '/var/run/postgresql');
    if (value.NODE_ENV === 'production' && ((value.DB_SSL !== 'true' && !privateSocket) || value.MAIL_MODE === 'smtp' || value.CORS_ORIGINS.split(',').some(url => !url.trim().startsWith('https://'))))
        throw new Error('Production requires database TLS or a local Unix socket, HTTPS origins and SES (or explicitly disabled recovery delivery).');
    return value;
}
