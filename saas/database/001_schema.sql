BEGIN;
CREATE SCHEMA identity;
CREATE SCHEMA control;
CREATE SCHEMA tenant;
CREATE ROLE pds_auth NOLOGIN NOSUPERUSER NOBYPASSRLS;
CREATE ROLE pds_tenant NOLOGIN NOSUPERUSER NOBYPASSRLS;
CREATE ROLE pds_platform NOLOGIN NOSUPERUSER NOBYPASSRLS;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

CREATE TABLE identity.users (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), email text UNIQUE CHECK(email = lower(email)), admin_id text UNIQUE,
 mobile text UNIQUE CHECK(mobile ~ '^\+[1-9][0-9]{6,14}$'), name text NOT NULL,
 password_hash text NOT NULL, email_verified_at timestamptz, mobile_verified_at timestamptz,
 status text NOT NULL DEFAULT 'PENDING_VERIFICATION' CHECK(status IN ('PENDING_VERIFICATION','ACTIVE','DISABLED')),
 created_at timestamptz NOT NULL DEFAULT now(), last_login_at timestamptz
);
CREATE TABLE identity.roles (id text PRIMARY KEY, scope text NOT NULL CHECK(scope IN ('PLATFORM','TENANT')));
CREATE TABLE identity.permissions (id text PRIMARY KEY);
CREATE TABLE identity.role_permissions (role_id text REFERENCES identity.roles(id), permission_id text REFERENCES identity.permissions(id), PRIMARY KEY(role_id, permission_id));
CREATE TABLE identity.user_roles (user_id uuid REFERENCES identity.users(id), role_id text REFERENCES identity.roles(id), PRIMARY KEY(user_id,role_id));
INSERT INTO identity.roles VALUES ('SUPER_ADMIN','PLATFORM'),('DISTRIBUTOR','TENANT');
INSERT INTO identity.permissions VALUES ('profile.read'),('profile.write'),('beneficiaries.read'),('beneficiaries.write'),('beneficiaries.import'),('pds.operate'),('inventory.manage'),('reports.read'),('staff.manage'),('billing.manage'),('platform.manage');
INSERT INTO identity.role_permissions SELECT 'DISTRIBUTOR',id FROM identity.permissions WHERE id NOT IN ('platform.manage','staff.manage');
INSERT INTO identity.role_permissions VALUES ('SUPER_ADMIN','platform.manage');

CREATE TABLE control.organization_types (id text PRIMARY KEY, name text NOT NULL, requires_pacs boolean NOT NULL DEFAULT false, active boolean NOT NULL DEFAULT true);
INSERT INTO control.organization_types VALUES ('PACS','PACS',true,true),('INDEPENDENT','Independent PDS Distributor',false,true),('OTHER','Other PDS Organization',false,true),('CUSTOM','Custom organization type',false,true);
CREATE SEQUENCE control.distributor_code_seq;
CREATE FUNCTION control.display_code(prefix text, value bigint) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT prefix || '-' || lpad(value::text,greatest(6,length(value::text)),'0') $$;
CREATE TABLE control.distributors (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), distributor_id text NOT NULL UNIQUE DEFAULT control.display_code('DIST',nextval('control.distributor_code_seq')),
 organization_name text NOT NULL, organization_type text NOT NULL REFERENCES control.organization_types(id), custom_type text,
 owner_name text NOT NULL, email text NOT NULL, mobile text NOT NULL, contact_person text,
 state text NOT NULL, district text NOT NULL, block text NOT NULL, panchayat text NOT NULL, village text NOT NULL, address text NOT NULL,
 pin_code text NOT NULL CHECK(pin_code ~ '^[0-9]{6}$'), pds_registration_number text, license_number text, gst_number text, pacs_code text,
 timezone text NOT NULL DEFAULT 'Asia/Kolkata', settings jsonb NOT NULL DEFAULT '{}',
 status text NOT NULL DEFAULT 'PENDING_APPROVAL' CHECK(status IN ('PENDING_APPROVAL','ACTIVE','SUSPENDED','CLOSED')),
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK(organization_type <> 'CUSTOM' OR coalesce(length(trim(custom_type)),0) > 0),
 CHECK(organization_type = 'PACS' OR pacs_code IS NULL)
);
CREATE TABLE control.distributor_users (
 distributor_id uuid NOT NULL REFERENCES control.distributors(id), user_id uuid NOT NULL REFERENCES identity.users(id),
 role_id text NOT NULL REFERENCES identity.roles(id) CHECK(role_id = 'DISTRIBUTOR'),
 permissions text[] NOT NULL DEFAULT '{}', status text NOT NULL DEFAULT 'ACTIVE' CHECK(status IN ('ACTIVE','DISABLED')),
 created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(distributor_id,user_id), UNIQUE(distributor_id), UNIQUE(user_id)
);
CREATE TABLE identity.pending_registrations (
 user_id uuid PRIMARY KEY REFERENCES identity.users(id), organization jsonb NOT NULL, terms_version text NOT NULL,
 terms_accepted_at timestamptz NOT NULL DEFAULT now(), provisioned_at timestamptz
);
CREATE TABLE identity.otp_challenges (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES identity.users(id),
 purpose text NOT NULL CHECK(purpose IN ('VERIFY_EMAIL','VERIFY_MOBILE','PASSWORD_RESET')),
 digest text NOT NULL, expires_at timestamptz NOT NULL, attempts integer NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 5),
 consumed_at timestamptz, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX otp_user_purpose ON identity.otp_challenges(user_id,purpose,created_at DESC);
CREATE TABLE identity.sessions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES identity.users(id), distributor_id uuid,
 client_type text NOT NULL CHECK(client_type IN ('WEB','NATIVE')), csrf_digest text, remember_me boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL, revoked_at timestamptz,
 FOREIGN KEY(distributor_id,user_id) REFERENCES control.distributor_users(distributor_id,user_id)
);
CREATE TABLE identity.refresh_tokens (
 digest text PRIMARY KEY, session_id uuid NOT NULL REFERENCES identity.sessions(id), expires_at timestamptz NOT NULL,
 consumed_at timestamptz, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX refresh_session ON identity.refresh_tokens(session_id);
CREATE TABLE identity.rate_limits (key text PRIMARY KEY, hits integer NOT NULL, expires_at timestamptz NOT NULL);

CREATE TABLE control.subscription_plans (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL, price_paise bigint NOT NULL CHECK(price_paise >= 0),
 currency text NOT NULL DEFAULT 'INR' CHECK(currency = 'INR'), billing_days integer NOT NULL CHECK(billing_days > 0),
 limits jsonb NOT NULL DEFAULT '{}', version integer NOT NULL DEFAULT 1, active boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE control.subscription_features (plan_id uuid REFERENCES control.subscription_plans(id), feature text NOT NULL, enabled boolean NOT NULL, PRIMARY KEY(plan_id,feature));
CREATE TABLE control.subscriptions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), distributor_id uuid NOT NULL REFERENCES control.distributors(id), plan_id uuid REFERENCES control.subscription_plans(id),
 status text NOT NULL CHECK(status IN ('TRIAL','ACTIVE','EXPIRED','SUSPENDED','CANCELLED','PENDING')),
 starts_at timestamptz NOT NULL, expires_at timestamptz NOT NULL CHECK(expires_at > starts_at), plan_snapshot jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(distributor_id,id)
);
CREATE TABLE control.payments (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), distributor_id uuid NOT NULL REFERENCES control.distributors(id), plan_id uuid NOT NULL REFERENCES control.subscription_plans(id),
 amount_paise bigint NOT NULL CHECK(amount_paise >= 0), currency text NOT NULL DEFAULT 'INR' CHECK(currency = 'INR'), gateway text NOT NULL,
 order_id text UNIQUE, gateway_payment_id text UNIQUE, status text NOT NULL DEFAULT 'PENDING' CHECK(status IN ('PENDING','SUCCESS','FAILED','REFUNDED')),
 plan_snapshot jsonb NOT NULL, paid_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(distributor_id,id)
);
CREATE TABLE control.payment_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), distributor_id uuid NOT NULL REFERENCES control.distributors(id), payment_id uuid NOT NULL,
 gateway text NOT NULL, event_id text NOT NULL, event_type text NOT NULL, body_digest text NOT NULL,
 received_at timestamptz NOT NULL DEFAULT now(), processed_at timestamptz,
 UNIQUE(gateway,event_id), FOREIGN KEY(distributor_id,payment_id) REFERENCES control.payments(distributor_id,id)
);
CREATE TABLE control.invoices (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), distributor_id uuid NOT NULL REFERENCES control.distributors(id), payment_id uuid NOT NULL UNIQUE,
 invoice_number text NOT NULL UNIQUE, amount_paise bigint NOT NULL, currency text NOT NULL, billing_snapshot jsonb NOT NULL,
 object_key text, created_at timestamptz NOT NULL DEFAULT now(), FOREIGN KEY(distributor_id,payment_id) REFERENCES control.payments(distributor_id,id)
);
CREATE TABLE control.system_settings (key text PRIMARY KEY, value jsonb NOT NULL, updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE control.platform_audit_logs (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid REFERENCES identity.users(id), distributor_id uuid REFERENCES control.distributors(id),
 action text NOT NULL, record_id text, reason text, metadata jsonb NOT NULL DEFAULT '{}', ip inet, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE control.usage_summaries (
 distributor_id uuid PRIMARY KEY REFERENCES control.distributors(id), users_count integer NOT NULL DEFAULT 0,
 beneficiaries_count integer NOT NULL DEFAULT 0, storage_bytes bigint NOT NULL DEFAULT 0, updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE SEQUENCE tenant.beneficiary_code_seq;
CREATE TABLE tenant.beneficiaries (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), distributor_id uuid NOT NULL REFERENCES control.distributors(id),
 beneficiary_id text NOT NULL UNIQUE DEFAULT control.display_code('BEN',nextval('tenant.beneficiary_code_seq')),
 name text NOT NULL, head_name text, mobile text, card_number text NOT NULL, family_members integer CHECK(family_members > 0),
 address text, village text, panchayat text, block text, district text, category text,
 status text NOT NULL DEFAULT 'ACTIVE' CHECK(status IN ('ACTIVE','INACTIVE')), import_source text, custom_fields jsonb NOT NULL DEFAULT '{}',
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(distributor_id,id), UNIQUE(distributor_id,card_number)
);
CREATE INDEX beneficiaries_tenant_name ON tenant.beneficiaries(distributor_id,name,id);
CREATE TABLE tenant.beneficiary_imports (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), distributor_id uuid NOT NULL REFERENCES control.distributors(id), uploaded_by uuid NOT NULL,
 file_name text NOT NULL, object_key text NOT NULL, file_digest text NOT NULL, column_mapping jsonb NOT NULL DEFAULT '{}',
 status text NOT NULL CHECK(status IN ('UPLOADED','VALIDATING','PREVIEW','IMPORTING','COMPLETED','FAILED')),
 total_rows integer NOT NULL DEFAULT 0, valid_rows integer NOT NULL DEFAULT 0, invalid_rows integer NOT NULL DEFAULT 0,
 duplicate_rows integer NOT NULL DEFAULT 0, imported_rows integer NOT NULL DEFAULT 0, failed_rows integer NOT NULL DEFAULT 0,
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(distributor_id,id), UNIQUE(distributor_id,file_digest),
 FOREIGN KEY(distributor_id,uploaded_by) REFERENCES control.distributor_users(distributor_id,user_id)
);
CREATE TABLE tenant.beneficiary_import_rows (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), distributor_id uuid NOT NULL REFERENCES control.distributors(id), import_id uuid NOT NULL,
 row_number integer NOT NULL CHECK(row_number > 0), normalized_data jsonb NOT NULL, errors jsonb NOT NULL DEFAULT '[]',
 status text NOT NULL CHECK(status IN ('VALID','INVALID','DUPLICATE','IMPORTED','FAILED')), beneficiary_id uuid,
 UNIQUE(distributor_id,import_id,row_number), FOREIGN KEY(distributor_id,import_id) REFERENCES tenant.beneficiary_imports(distributor_id,id),
 FOREIGN KEY(distributor_id,beneficiary_id) REFERENCES tenant.beneficiaries(distributor_id,id)
);
CREATE TABLE tenant.products (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), distributor_id uuid NOT NULL REFERENCES control.distributors(id), name text NOT NULL,
 category text, unit text NOT NULL, minimum_stock numeric(14,3) NOT NULL DEFAULT 0 CHECK(minimum_stock >= 0), active boolean NOT NULL DEFAULT true,
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(distributor_id,id), UNIQUE(distributor_id,name)
);
CREATE TABLE tenant.inventory (
 distributor_id uuid NOT NULL REFERENCES control.distributors(id), product_id uuid NOT NULL,
 opening_stock numeric(14,3) NOT NULL DEFAULT 0 CHECK(opening_stock >= 0), current_stock numeric(14,3) NOT NULL DEFAULT 0 CHECK(current_stock >= 0),
 version bigint NOT NULL DEFAULT 1, PRIMARY KEY(distributor_id,product_id), FOREIGN KEY(distributor_id,product_id) REFERENCES tenant.products(distributor_id,id)
);
CREATE TABLE tenant.allocations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), distributor_id uuid NOT NULL REFERENCES control.distributors(id), beneficiary_id uuid NOT NULL, product_id uuid NOT NULL,
 month date NOT NULL CHECK(extract(day FROM month)=1), quantity numeric(14,3) NOT NULL CHECK(quantity > 0),
 UNIQUE(distributor_id,id), UNIQUE(distributor_id,beneficiary_id,product_id,month),
 FOREIGN KEY(distributor_id,beneficiary_id) REFERENCES tenant.beneficiaries(distributor_id,id), FOREIGN KEY(distributor_id,product_id) REFERENCES tenant.products(distributor_id,id)
);
CREATE TABLE tenant.pds_transactions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), distributor_id uuid NOT NULL REFERENCES control.distributors(id), beneficiary_id uuid NOT NULL,
 month date NOT NULL CHECK(extract(day FROM month)=1), command_id uuid NOT NULL, receipt_number text NOT NULL, recorded_by uuid NOT NULL,
 recorded_at timestamptz NOT NULL DEFAULT now(), UNIQUE(distributor_id,id), UNIQUE(distributor_id,command_id), UNIQUE(distributor_id,receipt_number),
 FOREIGN KEY(distributor_id,beneficiary_id) REFERENCES tenant.beneficiaries(distributor_id,id),
 FOREIGN KEY(distributor_id,recorded_by) REFERENCES control.distributor_users(distributor_id,user_id)
);
CREATE TABLE tenant.pds_transaction_items (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), distributor_id uuid NOT NULL REFERENCES control.distributors(id), transaction_id uuid NOT NULL, product_id uuid NOT NULL,
 allocation_id uuid NOT NULL, quantity numeric(14,3) NOT NULL CHECK(quantity > 0), product_name_snapshot text NOT NULL, unit_snapshot text NOT NULL,
 UNIQUE(distributor_id,allocation_id), FOREIGN KEY(distributor_id,transaction_id) REFERENCES tenant.pds_transactions(distributor_id,id),
 FOREIGN KEY(distributor_id,product_id) REFERENCES tenant.products(distributor_id,id), FOREIGN KEY(distributor_id,allocation_id) REFERENCES tenant.allocations(distributor_id,id)
);
CREATE INDEX pds_tenant_month ON tenant.pds_transactions(distributor_id,month,recorded_at);
CREATE TABLE tenant.inventory_transactions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), distributor_id uuid NOT NULL REFERENCES control.distributors(id), product_id uuid NOT NULL,
 type text NOT NULL CHECK(type IN ('OPENING','IN','OUT','ADJUSTMENT')), delta numeric(14,3) NOT NULL CHECK(delta <> 0),
 balance_after numeric(14,3) NOT NULL CHECK(balance_after >= 0), reason text NOT NULL, recorded_by uuid NOT NULL,
 command_id uuid NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(distributor_id,command_id),
 FOREIGN KEY(distributor_id,product_id) REFERENCES tenant.products(distributor_id,id), FOREIGN KEY(distributor_id,recorded_by) REFERENCES control.distributor_users(distributor_id,user_id)
);
CREATE TABLE tenant.documents (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), distributor_id uuid NOT NULL REFERENCES control.distributors(id), uploaded_by uuid NOT NULL,
 beneficiary_id uuid, object_key text NOT NULL UNIQUE, file_name text NOT NULL, mime_type text NOT NULL, size_bytes bigint NOT NULL CHECK(size_bytes > 0),
 scan_status text NOT NULL DEFAULT 'QUARANTINED' CHECK(scan_status IN ('QUARANTINED','CLEAN','REJECTED')), created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY(distributor_id,beneficiary_id) REFERENCES tenant.beneficiaries(distributor_id,id), FOREIGN KEY(distributor_id,uploaded_by) REFERENCES control.distributor_users(distributor_id,user_id)
);
CREATE TABLE tenant.notifications (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), distributor_id uuid NOT NULL REFERENCES control.distributors(id), user_id uuid NOT NULL,
 title text NOT NULL, body text NOT NULL, read_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY(distributor_id,user_id) REFERENCES control.distributor_users(distributor_id,user_id)
);
CREATE TABLE tenant.audit_logs (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), distributor_id uuid NOT NULL REFERENCES control.distributors(id), user_id uuid NOT NULL,
 action text NOT NULL, module text NOT NULL, record_id text, metadata jsonb NOT NULL DEFAULT '{}', ip inet, created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY(distributor_id,user_id) REFERENCES control.distributor_users(distributor_id,user_id)
);
CREATE TABLE tenant.idempotency_keys (
 distributor_id uuid NOT NULL REFERENCES control.distributors(id), route text NOT NULL, key uuid NOT NULL, request_digest text NOT NULL,
 response jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(distributor_id,route,key)
);
CREATE TABLE tenant.outbox_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), distributor_id uuid NOT NULL REFERENCES control.distributors(id), type text NOT NULL,
 payload jsonb NOT NULL, attempts integer NOT NULL DEFAULT 0, available_at timestamptz NOT NULL DEFAULT now(), processed_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION tenant.current_distributor() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.distributor_id',true),'')::uuid $$;
REVOKE ALL ON FUNCTION tenant.current_distributor() FROM PUBLIC;
GRANT USAGE ON SCHEMA tenant TO pds_tenant;
GRANT EXECUTE ON FUNCTION tenant.current_distributor() TO pds_tenant;
DO $$ DECLARE entry record; BEGIN
 FOR entry IN SELECT tablename FROM pg_tables WHERE schemaname='tenant' LOOP
   EXECUTE format('ALTER TABLE tenant.%I ENABLE ROW LEVEL SECURITY',entry.tablename);
   EXECUTE format('ALTER TABLE tenant.%I FORCE ROW LEVEL SECURITY',entry.tablename);
   EXECUTE format('CREATE POLICY tenant_boundary ON tenant.%I TO pds_tenant USING (distributor_id = tenant.current_distributor()) WITH CHECK (distributor_id = tenant.current_distributor())',entry.tablename);
 END LOOP;
END $$;
GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA tenant TO pds_tenant;
GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA tenant TO pds_tenant;
REVOKE UPDATE,DELETE ON tenant.audit_logs,tenant.pds_transactions,tenant.pds_transaction_items,tenant.inventory_transactions FROM pds_tenant;
REVOKE ALL ON SCHEMA tenant FROM pds_auth,pds_platform;

GRANT USAGE ON SCHEMA identity,control TO pds_auth;
GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA identity TO pds_auth;
GRANT SELECT ON control.organization_types TO pds_auth;
GRANT SELECT,INSERT,UPDATE ON control.distributors,control.distributor_users,control.usage_summaries TO pds_auth;
GRANT INSERT ON control.platform_audit_logs TO pds_auth;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA control TO pds_auth;
GRANT USAGE ON SCHEMA control TO pds_platform;
GRANT SELECT,INSERT,UPDATE ON ALL TABLES IN SCHEMA control TO pds_platform;
REVOKE UPDATE ON control.platform_audit_logs,control.payment_events,control.invoices FROM pds_platform;
REVOKE INSERT,UPDATE ON control.payments,control.payment_events,control.invoices FROM pds_platform;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA control TO pds_platform;
GRANT USAGE ON SCHEMA control TO pds_tenant;
GRANT SELECT ON control.distributors,control.distributor_users,control.subscriptions,control.payments,control.invoices,control.subscription_plans,control.subscription_features,control.organization_types TO pds_tenant;
GRANT UPDATE(organization_name,contact_person,address,village,panchayat,block,district,state,pin_code,updated_at) ON control.distributors TO pds_tenant;
DO $$ DECLARE name text; BEGIN
 FOREACH name IN ARRAY ARRAY['distributors','distributor_users','subscriptions','payments','payment_events','invoices','usage_summaries'] LOOP
   EXECUTE format('ALTER TABLE control.%I ENABLE ROW LEVEL SECURITY',name);
   EXECUTE format('ALTER TABLE control.%I FORCE ROW LEVEL SECURITY',name);
   EXECUTE format('CREATE POLICY platform_scope ON control.%I TO pds_platform USING (true) WITH CHECK (true)',name);
   IF name IN ('distributors','distributor_users','usage_summaries') THEN
     EXECUTE format('CREATE POLICY auth_scope ON control.%I TO pds_auth USING (true) WITH CHECK (true)',name);
   END IF;
   EXECUTE format('CREATE POLICY member_scope ON control.%I TO pds_tenant USING (%I = tenant.current_distributor()) WITH CHECK (%I = tenant.current_distributor())',name,CASE WHEN name='distributors' THEN 'id' ELSE 'distributor_id' END,CASE WHEN name='distributors' THEN 'id' ELSE 'distributor_id' END);
 END LOOP;
END $$;
COMMIT;
