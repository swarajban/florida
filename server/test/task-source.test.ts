import { describe, expect, it } from 'vitest'
import { normalizeTaskSource, taskSourceInput } from '../src/task-source.js'

describe('task source normalization', () => {
  it.each([
    ['https://github.com/owner/repo/pull/123/files', 'PR #123 in owner/repo', 'github'],
    ['https://github.com/owner/repo/issues/42?x=1', 'Issue #42 in owner/repo', 'github'],
    ['https://linear.app/team/issue/abc-12/a-title', 'Linear ABC-12', 'linear'],
    ['https://acme.slack.com/archives/C1/p123', 'acme.slack.com/archives/C1/p123', 'slack'],
    ['mailto:person@example.com?subject=Hello', 'person@example.com', 'email'],
    ['https://mail.google.com/mail/u/0/#inbox/abc', 'mail.google.com/mail/u/0/', 'email'],
    ['http://www.example.com/path?token=not-a-title#fragment', 'www.example.com/path', 'web'],
    ['mailto:person%40example.com', 'person@example.com', 'email'],
    ['https://outlook.office365.com/mail/inbox/id', 'outlook.office365.com/mail/inbox/id', 'email'],
    ['https://example.com/', 'example.com', 'web'],
    ['https://github.com.evil.example/owner/repo/pull/1', 'github.com.evil.example/owner/repo/pull/1', 'web'],
  ])('derives a local title and kind for %s', (url, title, kind) => {
    expect(normalizeTaskSource(taskSourceInput.parse({ url }))).toEqual({ url, title, kind })
  })

  it('retains a trimmed supplied title but never trusts the supplied kind', () => {
    const url = 'https://example.com/path'
    expect(normalizeTaskSource(taskSourceInput.parse({ url, title: '  The original document  ', kind: 'github' })))
      .toEqual({ url, title: 'The original document', kind: 'web' })
    const title = normalizeTaskSource({ url: `https://example.com/${'a'.repeat(300)}` }).title
    expect(title).toHaveLength(120)
    expect(title.endsWith('…')).toBe(true)
    expect(normalizeTaskSource(taskSourceInput.parse({ url, title: '   ' })).title).toBe('example.com/path')
  })

  it('bounds input URLs and supplied titles', () => {
    expect(taskSourceInput.safeParse({ url: `https://example.com/${'a'.repeat(4096)}` }).success).toBe(false)
    expect(taskSourceInput.safeParse({ url: 'https://example.com', title: 'a'.repeat(201) }).success).toBe(false)
  })

  it.each([
    'javascript:alert(1)', 'data:text/html,hi', 'file:///etc/passwd', 'slack://channel',
    '//example.com/path', '/relative', 'https:example.com', 'https://',
    'https://user:password@example.com', 'https://@example.com', 'https://:@example.com',
    'https:///example.com', 'https://example.com/a\nb', ' https://example.com',
    'https://example.com/a\\b', 'https://example.com/%zz', 'https://example.com/%1f', 'https://example.com/%7f',
    'https://example.com/%C2%85',
    'mailto:', 'mailto://example.com', 'mailto:not-an-address', 'mailto:person@example.com?subject=hello%0aBcc:other@example.com',
  ])('rejects unsafe or malformed URLs: %s', (url) => {
    expect(taskSourceInput.safeParse({ url }).success).toBe(false)
  })
})
