import type { Config } from '../src/config.js'
import type { CalendarRow, GoogleAccountRow } from '../src/db/schema.js'
import type { CalendarSyncService } from '../src/google/sync.js'

export const testConfig: Config = {
  DATABASE_URL: 'postgres://unused',
  API_TOKEN: 'test-token-0123456789abcdef',
  TOKEN_ENCRYPTION_KEY: '00'.repeat(32),
  GOOGLE_CLIENT_ID: 'client-id',
  GOOGLE_CLIENT_SECRET: 'client-secret',
  PUBLIC_URL: 'https://florida.test',
  PORT: 8080,
  HORIZON_DAYS: 28,
  ANTHROPIC_MODEL: 'claude-test-1',
}

/** Records sync calls instead of talking to Google. */
export class FakeSync implements CalendarSyncService {
  syncCalendarCalls: CalendarRow[] = []
  syncAccountCalls: GoogleAccountRow[] = []
  /** When set, `syncAccount` waits on it, so a test can observe what happens while a first sync is still running. */
  syncAccountGate: Promise<void> | undefined
  syncAllCalls = 0
  async connectAccount(label: string): Promise<GoogleAccountRow> {
    const now = new Date()
    return {
      id: `account-${label}`,
      email: `${label}@example.com`,
      label,
      refreshTokenEnc: 'enc',
      accessToken: null,
      accessTokenExpiresAt: null,
      createdAt: now,
      updatedAt: now,
    }
  }
  async syncAccount(account: GoogleAccountRow): Promise<void> {
    this.syncAccountCalls.push(account)
    await this.syncAccountGate
  }
  async syncCalendar(calendar: CalendarRow): Promise<void> {
    this.syncCalendarCalls.push(calendar)
  }
  async syncAll(): Promise<void> {
    this.syncAllCalls += 1
  }
  async ensureAllWatches(): Promise<void> {}
}
