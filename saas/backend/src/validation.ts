import { z } from 'zod';
const text = (max: number) => z.string().trim().min(1).max(max);
const phone = z.string().regex(/^\+[1-9]\d{6,14}$/, 'Use international format, for example +918757114064');
const password = z.string().min(12).max(128);
export const organization = z.object({
    organizationName: text(150), organizationType: text(40), customType: text(80).optional(), ownerName: text(100),
    state: text(80), district: text(80), block: text(80), panchayat: text(80), village: text(100), address: text(500),
    pinCode: z.string().regex(/^\d{6}$/), pdsRegistrationNumber: text(80).optional(), licenseNumber: text(80).optional(),
    gstNumber: text(20).optional(), pacsCode: text(80).optional(),
}).strict().superRefine((value, context) => {
    if (value.organizationType === 'CUSTOM' && !value.customType)
        context.addIssue({ code: 'custom', path: ['customType'], message: 'Custom organization type is required' });
    if (value.organizationType !== 'PACS' && value.pacsCode)
        context.addIssue({ code: 'custom', path: ['pacsCode'], message: 'PACS code is only valid for PACS organizations' });
});
export const registration = z.object({
    email: z.string().trim().email().max(254).transform(value => value.toLowerCase()), mobile: phone, password, confirmPassword: password,
    organization, termsVersion: text(80), acceptTerms: z.literal(true),
}).strict().refine(value => value.password === value.confirmPassword, { path: ['confirmPassword'], message: 'Passwords must match' });
export const selfRegistration = z.object({
    email: z.string().trim().email().max(254).transform(value => value.toLowerCase()),
    mobile: phone, password, confirmPassword: password, organization,
}).strict().refine(value => value.password === value.confirmPassword, { path: ['confirmPassword'], message: 'Passwords must match' });
export const login = z.object({ identifier: text(254), password: z.string().min(1).max(128), clientType: z.enum(['WEB', 'NATIVE']), rememberMe: z.boolean().default(false), organizationCode: z.string().regex(/^DIST-\d+$/).optional() }).strict();
export const challenge = z.object({ challengeId: z.string().uuid(), code: z.string().regex(/^\d{6}$/) }).strict();
export const forgot = z.object({ identifier: text(254) }).strict();
export const resend = z.object({ identifier: text(254), channel: z.enum(['EMAIL', 'MOBILE']) }).strict();
export const reset = challenge.extend({ password, confirmPassword: password }).refine(value => value.password === value.confirmPassword, { path: ['confirmPassword'], message: 'Passwords must match' });
export const profileUpdate = z.object({ organizationName: text(150), contactPerson: text(100).nullable(), state: text(80), district: text(80), block: text(80), panchayat: text(80), village: text(100), address: text(500), pinCode: z.string().regex(/^\d{6}$/) }).strict();
export const statusUpdate = z.object({ status: z.enum(['ACTIVE', 'SUSPENDED', 'CLOSED']), reason: text(500) }).strict();
export const refresh = z.object({ refreshToken: z.string().min(40).max(100).optional() }).strict();
