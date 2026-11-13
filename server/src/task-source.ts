import { z } from 'zod'

export const taskSourceKind = z.enum(['email', 'slack', 'github', 'linear', 'web'])

export interface TaskSource {
  url: string
  title: string
  kind: z.infer<typeof taskSourceKind>
}

export const taskSourceInput = z.object({
  url: z.string().max(4096).refine(isSafeSourceUrl, 'expected a safe http, https, or mailto URL'),
  title: z.string().trim().max(200).optional(),
  kind: taskSourceKind.optional(),
}).describe('Where this task came from. URL is required; title and kind are derived locally when omitted. Kind always follows the URL. Omit source on edits to keep it, or send null to clear it.')

export function isSafeSourceUrl(value: string): boolean {
  if (/[\s\u0000-\u001f\u007f-\u009f\\]/.test(value)) return false
  try {
    if (/[\u0000-\u001f\u007f-\u009f]/.test(decodeURIComponent(value))) return false
    const url = new URL(value)
    if (url.protocol === 'mailto:') return /^[^\s/?#@]+@[^\s/?#@]+$/.test(decodeURIComponent(url.pathname))
    const authority = /^https?:\/\/([^/?#]+)/i.exec(value)?.[1]
    return authority !== undefined && !authority.includes('@') && url.hostname.length > 0 && url.username === '' && url.password === ''
  } catch {
    return false
  }
}

export function normalizeTaskSource(source: z.infer<typeof taskSourceInput>): TaskSource {
  const url = new URL(source.url)
  const host = url.hostname.toLowerCase()
  const isHost = (domain: string) => host === domain || host.endsWith(`.${domain}`)
  const kind = url.protocol === 'mailto:' || host === 'mail.google.com' || host === 'outlook.live.com' || host === 'outlook.office.com' || host === 'outlook.office365.com'
    ? 'email'
    : isHost('slack.com') ? 'slack'
    : host === 'github.com' || host === 'www.github.com' ? 'github'
    : isHost('linear.app') ? 'linear'
    : 'web'
  const github = kind === 'github' ? /^\/([^/]+)\/([^/]+)\/(pull|issues)\/(\d+)(?:\/|$)/.exec(url.pathname) : null
  const linear = kind === 'linear' ? /\/issue\/([a-z][a-z0-9]*-\d+)(?:\/|$)/i.exec(url.pathname) : null
  const derivedTitle = github !== null
    ? `${github[3] === 'pull' ? 'PR' : 'Issue'} #${github[4]} in ${github[1]}/${github[2]}`
    : linear !== null ? `Linear ${linear[1]!.toUpperCase()}`
    : url.protocol === 'mailto:' ? decodeURIComponent(url.pathname)
    : `${host}${url.pathname === '/' ? '' : url.pathname}`
  const title = source.title?.trim() || (derivedTitle.length > 120 ? `${derivedTitle.slice(0, 119)}…` : derivedTitle)
  return { url: source.url, title, kind }
}
