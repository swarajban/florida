import { describe, expect, it } from 'vitest'
import { decrypt, encrypt } from '../src/crypto.js'

const KEY = 'a'.repeat(64)
const OTHER_KEY = 'b'.repeat(64)

describe('crypto', () => {
  it('round-trips text', () => {
    const payload = encrypt('1//0refresh-token-ünïcödé', KEY)
    expect(payload).not.toContain('refresh')
    expect(decrypt(payload, KEY)).toBe('1//0refresh-token-ünïcödé')
  })

  it('uses a fresh IV each time', () => {
    expect(encrypt('same', KEY)).not.toBe(encrypt('same', KEY))
  })

  it('rejects tampered ciphertext', () => {
    const buf = Buffer.from(encrypt('secret', KEY), 'base64')
    buf[buf.length - 1] = buf[buf.length - 1]! ^ 0x01
    expect(() => decrypt(buf.toString('base64'), KEY)).toThrow()
  })

  it('rejects the wrong key and malformed input', () => {
    const payload = encrypt('secret', KEY)
    expect(() => decrypt(payload, OTHER_KEY)).toThrow()
    expect(() => decrypt('AAAA', KEY)).toThrow(/too short/)
    expect(() => encrypt('x', 'not-hex')).toThrow(/64 hex/)
  })
})
