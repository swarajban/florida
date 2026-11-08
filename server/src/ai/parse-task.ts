import { localParts, weekdayOf } from '@florida/scheduler'
import { z } from 'zod'
import { type ClaudeConfig, type FetchLike, type JsonSchema, requestJson } from './claude.js'

/** What the parser knows about the user's world when interpreting a line of text. */
export interface ParseTaskContext {
  now: Date
  /** IANA zone the text should be interpreted in. */
  timeZone: string
  /** Live categories; the parser picks `categoryId` from these or returns null. */
  categories: { id: string; name: string }[]
}

/** A task as Claude understood it; the client turns it into a `PUT /api/tasks/:id` body. */
export interface TaskDraft {
  title: string
  notes: string | null
  durationMinutes: number
  minChunkMinutes: number | null
  priority: 'asap' | 'high' | 'medium' | 'low'
  deadlineType: 'hard' | 'soft' | 'none'
  dueAt: string | null
  startAt: string | null
  pinnedStart: string | null
  categoryId: string | null
  /** One sentence on how the text was read, for the UI to show next to the draft. */
  rationale: string
}

export interface TaskParser {
  parse(text: string, ctx: ParseTaskContext): Promise<TaskDraft>
}

const instant = z.iso.datetime({ offset: true })

const draftSchema = z.object({
  title: z.string().trim().min(1),
  notes: z.string().nullable(),
  durationMinutes: z.number().int().min(5).max(24 * 60),
  minChunkMinutes: z.number().int().min(5).nullable(),
  priority: z.enum(['asap', 'high', 'medium', 'low']),
  deadlineType: z.enum(['hard', 'soft', 'none']),
  dueAt: instant.nullable(),
  startAt: instant.nullable(),
  pinnedStart: instant.nullable(),
  categoryId: z.string().nullable(),
  rationale: z.string(),
})

/** JSON schema handed to the API; every property is required, optional values are null. */
export const TASK_DRAFT_JSON_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    title: { type: 'string', description: 'Short imperative title without the parsed metadata' },
    notes: { type: ['string', 'null'], description: 'Extra detail from the text that is not part of the title' },
    durationMinutes: { type: 'integer', description: 'Estimated minutes of work; estimate realistically when not stated' },
    minChunkMinutes: { type: ['integer', 'null'], description: 'Smallest piece the task may be split into, if the text implies it' },
    priority: { type: 'string', enum: ['asap', 'high', 'medium', 'low'] },
    deadlineType: { type: 'string', enum: ['hard', 'soft', 'none'] },
    dueAt: { type: ['string', 'null'], description: 'ISO 8601 instant with offset, or null' },
    startAt: { type: ['string', 'null'], description: 'ISO 8601 instant before which the task must not start, or null' },
    pinnedStart: { type: ['string', 'null'], description: 'ISO 8601 instant when the task must happen exactly, or null' },
    categoryId: { type: ['string', 'null'], description: 'One of the given category ids, or null when none fits' },
    rationale: { type: 'string', description: 'One sentence explaining the interpretation' },
  },
  required: [
    'title',
    'notes',
    'durationMinutes',
    'minChunkMinutes',
    'priority',
    'deadlineType',
    'dueAt',
    'startAt',
    'pinnedStart',
    'categoryId',
    'rationale',
  ],
  additionalProperties: false,
}

const WEEKDAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']

/** Builds the system and user turns. Pure, so tests can assert on the exact wording. */
export function buildPrompt(text: string, ctx: ParseTaskContext): { system: string; user: string } {
  const parts = localParts(ctx.now.getTime(), ctx.timeZone)
  const weekday = WEEKDAYS[weekdayOf(parts)] ?? 'unknown weekday'
  const local = `${parts.year}-${pad(parts.month)}-${pad(parts.day)} ${pad(parts.hour)}:${pad(parts.minute)}`
  const categoryList =
    ctx.categories.length === 0 ? '(none)' : ctx.categories.map((p) => `- id "${p.id}": ${p.name}`).join('\n')

  const system = [
    'You turn one line a user typed into a structured task for a personal auto-scheduling calendar.',
    `Current local time: ${local} (${weekday}), time zone ${ctx.timeZone}; current instant ${ctx.now.toISOString()}.`,
    'Resolve every date and time in that time zone and return ISO 8601 instants with a UTC offset.',
    'Rules:',
    '- "by <date>" or a bare date means a soft deadline; "due <date>" or "deadline <date>" means a hard deadline.',
    '- A deadline without a clock time is 17:00 local on that day.',
    '- A weekday name means the next such day strictly after today; "next <weekday>" skips to the following week.',
    '- "after", "from" or "starting <date>" sets startAt (00:00 local unless a time is given) and is not a deadline.',
    '- An explicit clock time with no deadline word ("at 3pm", "tue 10am") is a pinnedStart: do it exactly then.',
    '- Words like asap or urgent mean priority asap; otherwise default to medium unless the text says high or low.',
    '- Keep the title short and strip the parsed metadata from it; put leftover detail in notes.',
    '- Estimate durationMinutes when none is given (typical quick task 30, meeting prep 45, writing 90).',
    '- Choose categoryId only from the list below; null when nothing fits.',
    'Categories:',
    categoryList,
  ].join('\n')

  return { system, user: text }
}

/** Parses a line of text with Claude using structured output and validates the result. */
export class ClaudeTaskParser implements TaskParser {
  constructor(
    private readonly config: ClaudeConfig,
    private readonly fetchImpl?: FetchLike,
  ) {}

  async parse(text: string, ctx: ParseTaskContext): Promise<TaskDraft> {
    const prompt = buildPrompt(text, ctx)
    const raw = await requestJson(this.config, { ...prompt, schema: TASK_DRAFT_JSON_SCHEMA }, this.fetchImpl)
    const draft = draftSchema.parse(raw)
    const knownCategory = draft.categoryId !== null && ctx.categories.some((p) => p.id === draft.categoryId)
    return {
      ...draft,
      categoryId: knownCategory ? draft.categoryId : null,
      // A deadline type without a date (or vice versa) is contradictory; the date wins.
      deadlineType: draft.dueAt === null ? 'none' : draft.deadlineType === 'none' ? 'soft' : draft.deadlineType,
    }
  }
}

function pad(n: number): string {
  return n.toString().padStart(2, '0')
}
