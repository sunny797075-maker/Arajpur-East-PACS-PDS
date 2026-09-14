BEGIN;
CREATE TABLE control.schema_migrations(version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());
INSERT INTO control.schema_migrations(version) VALUES ('002_workflows');
ALTER TABLE tenant.beneficiaries ADD COLUMN deleted_at timestamptz;
ALTER TABLE tenant.pds_transactions ADD COLUMN beneficiary_snapshot jsonb NOT NULL DEFAULT '{}';
ALTER TABLE tenant.pds_transactions ADD CONSTRAINT one_distribution_per_cycle UNIQUE(distributor_id,beneficiary_id,month);
CREATE INDEX beneficiary_search_scope ON tenant.beneficiaries(distributor_id,deleted_at);
CREATE INDEX distribution_cycle_scope ON tenant.pds_transactions(distributor_id,month,recorded_at);
CREATE TABLE tenant.staff (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), distributor_id uuid NOT NULL REFERENCES control.distributors(id),
 name text NOT NULL, mobile text NOT NULL, work_details text NOT NULL, active boolean NOT NULL DEFAULT true,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(distributor_id,id)
);
CREATE TABLE tenant.attendance (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), distributor_id uuid NOT NULL, staff_id uuid NOT NULL,
 attendance_date date NOT NULL, status text NOT NULL CHECK(status IN ('PRESENT','ABSENT')), recorded_by uuid NOT NULL,
 updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(distributor_id,staff_id,attendance_date),
 FOREIGN KEY(distributor_id,staff_id) REFERENCES tenant.staff(distributor_id,id),
 FOREIGN KEY(distributor_id,recorded_by) REFERENCES control.distributor_users(distributor_id,user_id)
);
ALTER TABLE tenant.staff ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant.staff FORCE ROW LEVEL SECURITY;
ALTER TABLE tenant.attendance ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant.attendance FORCE ROW LEVEL SECURITY;
CREATE POLICY scope ON tenant.staff TO pds_tenant USING(distributor_id=tenant.current_distributor()) WITH CHECK(distributor_id=tenant.current_distributor());
CREATE POLICY scope ON tenant.attendance TO pds_tenant USING(distributor_id=tenant.current_distributor()) WITH CHECK(distributor_id=tenant.current_distributor());
GRANT SELECT,INSERT,UPDATE ON tenant.staff,tenant.attendance TO pds_tenant;
INSERT INTO identity.role_permissions VALUES('DISTRIBUTOR','staff.manage') ON CONFLICT DO NOTHING;
DELETE FROM identity.role_permissions WHERE role_id='DISTRIBUTOR' AND permission_id='inventory.manage';
CREATE TABLE control.access_grants (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), distributor_id uuid NOT NULL REFERENCES control.distributors(id),
 source text NOT NULL CHECK(source IN ('MANUAL','PAYMENT')), expires_at timestamptz NOT NULL,
 reason text NOT NULL, created_by uuid REFERENCES identity.users(id), payment_id uuid,
 created_at timestamptz NOT NULL DEFAULT now(), FOREIGN KEY(distributor_id,payment_id) REFERENCES control.payments(distributor_id,id)
);
ALTER TABLE control.access_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE control.access_grants FORCE ROW LEVEL SECURITY;
CREATE POLICY platform_scope ON control.access_grants TO pds_platform USING(true) WITH CHECK(true);
CREATE POLICY member_scope ON control.access_grants TO pds_tenant USING(distributor_id=tenant.current_distributor());
GRANT SELECT,INSERT ON control.access_grants TO pds_platform;
GRANT SELECT ON control.access_grants TO pds_tenant;
-- Keep existing active accounts usable during this rollout; subsequent extensions are explicit and audited.
INSERT INTO control.access_grants(distributor_id,source,expires_at,reason)
 SELECT id,'MANUAL',now()+interval '30 days','Existing account: 30-day migration access' FROM control.distributors WHERE status='ACTIVE';
GRANT INSERT,UPDATE ON control.payments TO pds_platform;
COMMIT;
