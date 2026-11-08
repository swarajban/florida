import { z } from 'zod'

const envSchema = z.object({
  DATABASE_URL: z.string().min(1),
  API_TOKEN: z.string().min(16),
  TOKEN_ENCRYPTION_KEY: z
    .string()
    .regex(/^[0-9a-fA-F]{64}$/, 'must be 64 hex characters (32 bytes)'),
  GOOGLE_CLIENT_ID: z.string().min(1),
  GOOGLE_CLIENT_SECRET: z.string().min(1),
  PUBLIC_URL: z
    .string()
    .regex(/^https?:\/\/[^/\s]+$/, 'must be an origin like https://florida-swaraj.fly.dev with no trailing slash'),
  PORT: z.coerce.number().int().positive().default(8080),
  HORIZON_DAYS: z.coerce.number().int().positive().default(28),
  /**
   * Optional: the `content` value of Search Console's HTML-tag verification, served on `/` so
   * Google accepts `PUBLIC_URL` as a push-notification (webhook) domain.
   */
  GOOGLE_SITE_VERIFICATION: z.string().min(1).optional(),
  /** Optional: enables POST /api/ai/parse-task. */
  ANTHROPIC_API_KEY: z.string().min(1).optional(),
  ANTHROPIC_MODEL: z.string().min(1).default('claude-haiku-5-5'),
})

export type Config = z.infer<typeof envSchema>

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const result = envSchema.safeParse(env)
  if (result.success) return result.data
  const lines = result.error.issues.map((issue) => {
    const name = issue.path.join('.')
    const problem = issue.code === 'invalid_type' && issue.message.includes('undefined') ? 'missing' : issue.message
    return `  ${name}: ${problem}`
  })
  throw new Error(`Invalid environment:\n${lines.join('\n')}`)
}
