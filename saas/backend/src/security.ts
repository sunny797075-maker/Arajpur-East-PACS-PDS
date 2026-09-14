import { createHmac, randomBytes, randomInt, scrypt as derive, timingSafeEqual } from 'node:crypto';
export const opaqueToken = () => randomBytes(32).toString('base64url');
export const otpCode = () => randomInt(0, 1000000).toString().padStart(6, '0');
export const digest = (value: string, key: string) => createHmac('sha256', key).update(value).digest('hex');
export function equalDigest(a: string, b: string): boolean {
    const left = Buffer.from(a, 'hex'), right = Buffer.from(b, 'hex');
    return left.length === 32 && right.length === 32 && timingSafeEqual(left, right);
}
function scrypt(password: string, salt: Buffer): Promise<Buffer> {
    return new Promise((resolve, reject) => derive(password, salt, 64, { N: 32768, r: 8, p: 1, maxmem: 64 * 1024 * 1024 }, (error, key) => error ? reject(error) : resolve(key)));
}
export async function hashPassword(password: string): Promise<string> {
    const salt = randomBytes(16), hash = await scrypt(password, salt);
    return `scrypt$32768$8$1$${salt.toString('hex')}$${hash.toString('hex')}`;
}
export async function verifyPassword(password: string, stored: string): Promise<boolean> {
    const [algorithm, n, r, p, salt, hash] = stored.split('$');
    if (algorithm !== 'scrypt' || n !== '32768' || r !== '8' || p !== '1' || !salt || !hash || !/^[a-f0-9]{32}$/.test(salt) || !/^[a-f0-9]{128}$/.test(hash))
        return false;
    const actual = await scrypt(password, Buffer.from(salt, 'hex'));
    return timingSafeEqual(actual, Buffer.from(hash, 'hex'));
}

