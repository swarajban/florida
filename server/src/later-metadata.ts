import { lookup } from 'node:dns'
import { request as httpRequest } from 'node:http'
import type { IncomingMessage } from 'node:http'
import { request as httpsRequest } from 'node:https'
import { isIP } from 'node:net'
import { loadBuffer } from 'cheerio'
import ipaddr from 'ipaddr.js'
import { defaultLaterMinutes } from './later.js'
import type { LaterItemRow } from './db/schema.js'

const MAX_BYTES = 1024 * 1024
const MAX_REDIRECTS = 3
type Metadata = Pick<LaterItemRow, 'title' | 'site' | 'kind' | 'estMinutes'>
type Capture = Pick<LaterItemRow, 'url' | keyof Metadata>

export function parseLaterMetadata(html: Buffer, item: Capture, hostname = new URL(item.url).hostname): Metadata {
  const $ = loadBuffer(html)
  const meta = (key: string) => $('meta').filter((_, node) =>
    $(node).attr('property') === key || $(node).attr('name') === key).first().attr('content')?.trim() || undefined
  const data: Record<string, unknown>[] = []
  const walk = (value: unknown, depth = 0): void => {
    if (depth >= 8 || value === null || typeof value !== 'object') return
    if (Array.isArray(value)) {
      for (const entry of value) walk(entry, depth + 1)
      return
    }
    const record = value as Record<string, unknown>
    if (record['@type'] !== undefined) data.push(record)
    walk(record.mainEntity, depth + 1)
    walk(record['@graph'], depth + 1)
  }
  $('script[type="application/ld+json"]').each((_, node) => {
    try { walk(JSON.parse($(node).text())) } catch {}
  })
  const types = (entry: Record<string, unknown>): unknown[] => [entry['@type']].flat()
  const article = data.find((entry) => types(entry).some((type) => ['Article', 'NewsArticle', 'BlogPosting'].includes(String(type))))
  const video = data.find((entry) => types(entry).includes('VideoObject'))
  const product = data.find((entry) => types(entry).includes('Product'))
  const og = meta('og:type')?.toLowerCase()
  const kind = og === 'product' ? 'other' : og === 'article' ? 'article' : og?.startsWith('video') ? 'video'
    : article ? 'article' : video ? 'video' : product ? 'other' : item.kind
  const primary = kind === 'article' ? article : kind === 'video' ? video : product
  const text = (value: unknown): string | undefined => typeof value === 'string' ? value.replace(/\s+/gu, ' ').trim() || undefined : undefined
  let minutes: number | undefined
  if (kind === 'video') {
    const duration = /^P(?:(\d+)D)?T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$/i.exec(text(video?.duration) ?? '')
    const seconds = duration === null ? Number(meta('video:duration'))
      : duration.slice(1).reduce((sum, value, i) => sum + Number(value ?? 0) * [86400, 3600, 60, 1][i]!, 0)
    if (seconds > 0) minutes = Math.ceil(seconds / 60)
  } else if (kind === 'article') {
    $('script,style,noscript,nav,header,footer,aside,template,[hidden]').remove()
    const articleNode = $('article').first()
    const main = $('main, [role="main"]').first()
    const body = articleNode.length ? articleNode : main.length ? main : $('body')
    body.find('p,li,blockquote,h1,h2,h3,br').after(' ')
    const words = (text(article?.articleBody) ?? body.text()).match(/[\p{L}\p{N}]+/gu)?.length ?? 0
    if (words > 0) minutes = Math.ceil(words / 230)
  }
  return {
    title: (meta('og:title') ?? text(primary?.headline) ?? text(primary?.name) ?? text($('title').text()) ?? item.title).slice(0, 200),
    site: (meta('og:site_name') ?? hostname).slice(0, 200),
    kind,
    estMinutes: item.estMinutes ?? Math.min(1440, minutes ?? defaultLaterMinutes(kind)),
  }
}

export function isPublicLaterAddress(address: string): boolean {
  if (!ipaddr.isValid(address)) return false
  const ip = ipaddr.parse(address)
  if (ip.range() !== 'unicast') return false
  return ip instanceof ipaddr.IPv4 || (ip.parts[0]! & 0xe000) === 0x2000
}

function getHtml(url: URL, signal: AbortSignal): Promise<IncomingMessage> {
  const request = url.protocol === 'https:' ? httpsRequest : httpRequest
  return new Promise((resolve, reject) => {
    request(url, {
      agent: false, signal, headers: { accept: 'text/html, application/xhtml+xml' },
      lookup(hostname, options, done) {
        lookup(hostname, { all: true, family: options.family }, (err, addresses) => {
          const publicAddresses = addresses?.filter(({ address }) => isPublicLaterAddress(address)) ?? []
          const publicAddress = publicAddresses[0]
          if (publicAddress === undefined) done(err ?? new Error('No public address'), '', 0)
          else if (options.all) done(null, publicAddresses)
          else done(null, publicAddress.address, publicAddress.family)
        })
      },
    }, resolve).on('error', reject).end()
  })
}

export async function fetchLaterMetadata(item: Capture): Promise<Metadata> {
  const fallback = { title: item.title, site: item.site, kind: item.kind, estMinutes: item.estMinutes ?? defaultLaterMinutes(item.kind) }
  try {
    let url = new URL(item.url)
    const signal = AbortSignal.timeout(5_000)
    for (let redirect = 0; redirect <= MAX_REDIRECTS; redirect++) {
      const hostname = url.hostname.replace(/^\[|\]$/g, '')
      if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password || url.port
        || (isIP(hostname) !== 0 ? !isPublicLaterAddress(hostname) : !hostname.includes('.'))) break
      const response = await getHtml(url, signal)
      const status = response.statusCode ?? 0
      const headers = response.headers
      if ([301, 302, 303, 307, 308].includes(status) && headers.location) {
        response.destroy()
        url = new URL(headers.location, url)
        continue
      }
      if (status < 200 || status >= 300 || !/^(text\/html|application\/xhtml\+xml)(?:;|$)/i.test(headers['content-type'] ?? '')
        || Number(headers['content-length']) > MAX_BYTES) {
        response.destroy()
        break
      }
      let size = 0
      const chunks: Buffer[] = []
      for await (const chunk of response as AsyncIterable<Buffer>) {
        size += chunk.length
        if (size > MAX_BYTES) return fallback
        chunks.push(chunk)
      }
      return parseLaterMetadata(Buffer.concat(chunks), item, hostname)
    }
  } catch {}
  return fallback
}
