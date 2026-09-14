#!/usr/bin/env python3
"""Run as root once on the existing Lightsail server. Never prints secrets."""
import os
import pathlib
import secrets
import subprocess

def sql(statement, database='postgres'):
    return subprocess.run(['runuser', '-u', 'postgres', '--', 'psql', '-v', 'ON_ERROR_STOP=1', '-q', '-d', database], input=statement, text=True, check=True, capture_output=True)

config = pathlib.Path('/etc/postgresql/15/main/conf.d/pds.conf')
config.write_text("listen_addresses = ''\nmax_connections = 24\nshared_buffers = '32MB'\nwork_mem = '2MB'\nmaintenance_work_mem = '16MB'\n")
hba = pathlib.Path('/etc/postgresql/15/main/pg_hba.conf')
rule = 'local pds_saas pds_auth_runtime,pds_tenant_runtime,pds_platform_runtime scram-sha-256\n'
if rule not in hba.read_text():
    hba.write_text(rule + hba.read_text())
subprocess.run(['systemctl', 'restart', 'postgresql'], check=True)
env_file = pathlib.Path('/etc/pds/api.env')
if env_file.exists():
    print('Existing database configuration preserved.')
    raise SystemExit(0)
exists = subprocess.run(['runuser','-u','postgres','--','psql','-Atqc', "SELECT 1 FROM pg_database WHERE datname='pds_saas'"], check=True, text=True, capture_output=True).stdout.strip()
if exists:
    raise RuntimeError('Database exists without its configuration; refusing to overwrite.')
sql('CREATE DATABASE pds_saas;')
sql(pathlib.Path('/opt/pds/001_schema.sql').read_text(), 'pds_saas')
environment = {'NODE_ENV':'production','PORT':'3000','DB_SSL':'false','MAIL_MODE':'disabled',
    'MAIL_FROM':'unconfigured@example.invalid','CORS_ORIGINS':'https://15.252.37.89',
    'AWS_REGION':'ap-south-1','TERMS_VERSION':'foundation-2026-09',
    'JWT_ISSUER':'pds-saas','JWT_AUDIENCE':'pds-clients'}
for kind in ['auth','tenant','platform']:
    password = secrets.token_hex(32)
    sql(f"CREATE ROLE pds_{kind}_runtime LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD '{password}' IN ROLE pds_{kind};")
    environment[kind.upper()+'_DATABASE_URL'] = f'postgresql://pds_{kind}_runtime:{password}@localhost/pds_saas?host=/var/run/postgresql'
for key in ['JWT_SECRET','TOKEN_PEPPER','OTP_PEPPER']:
    environment[key] = secrets.token_hex(64)
env_file.write_text('\n'.join(k+'='+v for k,v in environment.items())+'\n')
os.chmod(env_file, 0o600)
print('PostgreSQL schema and three restricted runtime roles created. Credentials stored privately.')
