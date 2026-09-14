// Run as postgres OS user; connects through the local Unix socket.
const {Pool} = require('/opt/pds/api/node_modules/pg');
const {randomBytes} = require('node:crypto');
const {writeFileSync,existsSync} = require('node:fs');
const {hashPassword} = require('/opt/pds/api/dist/security');
(async()=>{
 const pool=new Pool({host:'/var/run/postgresql',database:'pds_saas',user:'postgres'});
 try {
  const found=await pool.query("SELECT 1 FROM identity.user_roles WHERE role_id='SUPER_ADMIN'");
  if(found.rowCount){console.log('Existing owner preserved.');return;}
  const password=randomBytes(24).toString('base64url');
  const hash=await hashPassword(password);
  const client=await pool.connect();
  try {
   await client.query('BEGIN');
   const user=await client.query("INSERT INTO identity.users(admin_id,name,password_hash,status) VALUES('ADMIN-001','Platform owner',$1,'ACTIVE') RETURNING id",[hash]);
   await client.query("INSERT INTO identity.user_roles(user_id,role_id) VALUES($1,'SUPER_ADMIN')",[user.rows[0].id]);
   writeFileSync('/var/lib/postgresql/pds-owner-login.txt',`PDS Connect owner login\nURL: https://15.252.37.89/#/super-admin/login\nAdmin ID: ADMIN-001\nPassword: ${password}\n\nKeep this file private. This is a real account, not a demo.\n`,{mode:0o600,flag:'wx'});
   await client.query('COMMIT');
   console.log('Owner enrolled. Credentials written to a protected file.');
  }catch(e){await client.query('ROLLBACK');throw e;}finally{client.release();}
 }finally{await pool.end();}
})().catch(()=>{console.error('Owner enrollment failed. Existing accounts were not overwritten.');process.exitCode=1;});
