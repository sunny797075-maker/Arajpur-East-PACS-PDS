import { randomBytes } from 'node:crypto';
import { writeFile, access } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
const root=new URL('../',import.meta.url),env=new URL('.env.local',root);
try{await access(env);console.error('Existing .env.local is preserved. Do not regenerate passwords for an existing database volume.');process.exit(1);}catch(error){if(error.code!=='ENOENT')throw error;}
const secret=()=>randomBytes(48).toString('hex');
const postgres=secret(),auth=secret(),tenant=secret(),platform=secret();
const values={NODE_ENV:'development',PORT:'3000',POSTGRES_PASSWORD:postgres,PDS_AUTH_PASSWORD:auth,PDS_TENANT_PASSWORD:tenant,PDS_PLATFORM_PASSWORD:platform,
 AUTH_DATABASE_URL:`postgresql://pds_api_auth:${auth}@localhost:5432/pds`,TENANT_DATABASE_URL:`postgresql://pds_api_tenant:${tenant}@localhost:5432/pds`,PLATFORM_DATABASE_URL:`postgresql://pds_api_platform:${platform}@localhost:5432/pds`,
 JWT_SECRET:secret(),TOKEN_PEPPER:secret(),OTP_PEPPER:secret(),JWT_ISSUER:'pds-saas',JWT_AUDIENCE:'pds-clients',CORS_ORIGINS:'http://localhost:5173',DB_SSL:'false',MAIL_MODE:'smtp',MAIL_FROM:'no-reply@pds.local',SMTP_HOST:'localhost',SMTP_PORT:'1025',AWS_REGION:'ap-south-1',TERMS_VERSION:'development-2026-09'};
await writeFile(env,Object.entries(values).map(([key,value])=>`${key}=${value}`).join('\n')+'\n',{mode:0o600,flag:'wx'});
console.log(`Local-only configuration created at ${fileURLToPath(env)}. Secrets were not printed.`);
