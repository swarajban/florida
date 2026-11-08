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
  syncAllCalls = 0
  async connectAccount(): Promise<GoogleAccountRow> {
    throw new Error('not used in tests')
  }
  async syncCalendar(calendar: CalendarRow): Promise<void> {
    this.syncCalendarCalls.push(calendar)
  }
  async syncAll(): Promise<void> {
    this.syncAllCalls += 1
  }
  async ensureAllWatches(): Promise<void> {}
}
