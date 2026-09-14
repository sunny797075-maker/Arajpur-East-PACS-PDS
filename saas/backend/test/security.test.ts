import test from 'node:test';
import assert from 'node:assert/strict';
import { digest, equalDigest, hashPassword, opaqueToken, otpCode, verifyPassword } from '../src/security';
import { registration, profileUpdate } from '../src/validation';
test('password hashes are salted and verify only the original password', async () => {
    const password = 'a sufficiently long passphrase';
    const a = await hashPassword(password), b = await hashPassword(password);
    assert.notEqual(a, b);
    assert.equal(await verifyPassword(password, a), true);
    assert.equal(await verifyPassword('wrong password', a), false);
    assert.equal(await verifyPassword(password, 'invalid'), false);
});
test('OTP generation retains leading zeros and digest comparison rejects malformed values', () => {
    for (let i = 0; i < 100; i++)
        assert.match(otpCode(), /^\d{6}$/);
    const hash = digest('challenge:123456', 'test-pepper');
    assert.equal(equalDigest(hash, hash), true);
    assert.equal(equalDigest(hash, digest('other:123456', 'test-pepper')), false);
    assert.equal(equalDigest('00', '00'), false);
    assert.notEqual(opaqueToken(), opaqueToken());
});
const valid = { email: 'owner@example.org', mobile: '+919876543210', password: 'correct horse battery staple', confirmPassword: 'correct horse battery staple', termsVersion: '2026-09', acceptTerms: true,
    organization: { organizationName: 'Independent Shop', organizationType: 'INDEPENDENT', ownerName: 'Owner', state: 'Bihar', district: 'Madhepura', block: 'Chausa', panchayat: 'Arajpur', village: 'Arajpur', address: 'Market Road', pinCode: '853204' } };
test('independent registration does not require PACS fields; client-owned role and tenant assignment are rejected', () => {
    assert.equal(registration.safeParse(valid).success, true);
    assert.equal(registration.safeParse({ ...valid, role: 'SUPER_ADMIN' }).success, false);
    assert.equal(registration.safeParse({ ...valid, distributor_id: 'another' }).success, false);
    assert.equal(registration.safeParse({ ...valid, organization: { ...valid.organization, pacsCode: 'PACS123' } }).success, false);
    assert.equal(registration.safeParse({ ...valid, organization: { ...valid.organization, organizationType: 'CUSTOM' } }).success, false);
    assert.equal(profileUpdate.safeParse({ distributor_id: 'another', status: 'ACTIVE' }).success, false);
});

