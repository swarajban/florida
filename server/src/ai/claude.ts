import type { z } from 'zod'

/**
 * Minimal Anthropic Messages API client for structured (JSON schema) output. Plain `fetch`, like
 * the Google client; no SDK. Docs: https://platform.claude.com/docs/en/build-with-claude/structured-outputs
 */
export interface ClaudeConfig {
  apiKey: string
  model: string
  /** Override for tests or proxies. Default https://api.anthropic.com */
  baseUrl?: string
  /** How long to wait for a reply. Default 30 seconds. */
  timeoutMs?: number
}

const TIMEOUT_MS = 30_000

export type JsonSchema = Record<string, unknown>

export interface JsonRequest {
  system: string
  user: string
  schema: JsonSchema
  maxTokens?: number
}

export class ClaudeError extends Error {
  constructor(
    message: string,
    readonly status?: number,
  ) {
    super(message)
    this.name = 'ClaudeError'
  }
}

export type FetchLike = (input: string, init: RequestInit) => Promise<Response>

const ANTHROPIC_VERSION = '2023-06-01'

interface MessagesResponse {
  content?: { type: string; text?: string }[]
  stop_reason?: string
}

/** Sends one user turn and returns the JSON object Claude produced for `schema`. */
export async function requestJson(
  config: ClaudeConfig,
  request: JsonRequest,
  fetchImpl: FetchLike = (input, init) => fetch(input, init),
): Promise<unknown> {
  const url = `${config.baseUrl ?? 'https://api.anthropic.com'}/v1/messages`
  let res: Response
  try {
    res = await fetchImpl(url, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-api-key': config.apiKey,
        'anthropic-version': ANTHROPIC_VERSION,
      },
      body: JSON.stringify({
        model: config.model,
        max_tokens: request.maxTokens ?? 1024,
        system: request.system,
        messages: [{ role: 'user', content: request.user }],
        output_config: { format: { type: 'json_schema', schema: request.schema } },
      }),
      signal: AbortSignal.timeout(config.timeoutMs ?? TIMEOUT_MS),
    })
  } catch (err) {
    throw new ClaudeError(`request failed: ${err instanceof Error ? err.message : String(err)}`)
  }
  const text = await res.text()
  if (!res.ok) throw new ClaudeError(`Anthropic API ${res.status}: ${text.slice(0, 500)}`, res.status)

  let body: MessagesResponse
  try {
    body = JSON.parse(text) as MessagesResponse
  } catch {
    throw new ClaudeError('Anthropic API returned non-JSON body')
  }
  const block = body.content?.find((b) => b.type === 'text' && typeof b.text === 'string')
  if (block?.text === undefined) throw new ClaudeError(`no text block in response (stop_reason ${body.stop_reason ?? 'unknown'})`)
  try {
    return JSON.parse(block.text) as unknown
  } catch {
    throw new ClaudeError('model output was not valid JSON')
  }
}

/**
 * Checks the JSON the model returned against `schema`. A reply that does not fit is the model's
 * failure, so it is a `ClaudeError` (502), not a validation error of the caller's request (400).
 */
export function modelOutput<S extends z.ZodType>(schema: S, raw: unknown): z.output<S> {
  const parsed = schema.safeParse(raw)
  if (!parsed.success) throw new ClaudeError(`model output did not fit the schema: ${parsed.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`).join('; ')}`)
  return parsed.data
}
