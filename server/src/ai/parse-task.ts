import { localParts, weekdayOf } from '@florida/scheduler'
import { z } from 'zod'
import { type ClaudeConfig, type FetchLike, type JsonSchema, requestJson } from './claude.js'

/** What the parser knows about the user's world when interpreting a line of text. */
export interface ParseTaskContext {
  now: Date
  /** IANA zone the text should be interpreted in. */
  timeZone: string
  /** Live categories; the parser picks `categoryId` from these or returns null. */
  categories: CategoryContext[]
  /** Active projects; the parser picks `projectId` from these or returns null. */
  projects?: ProjectContext[]
}

/** A project as the model sees it. */
export interface ProjectContext {
  id: string
  name: string
  /** True when the project's work mostly runs itself, so its tasks are shared-attention by default. */
  parallel: boolean
}

/** A category as the model sees it: what the user calls it and what they have filed under it. */
export interface CategoryContext {
  id: string
  name: string
  /** Recent task titles in this category, open tasks first; the model mimics the user's filing. */
  examples: string[]
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
  /** Where the task can be done. */
  context: 'computer' | 'errand' | 'home' | 'office'
  projectId: string | null
  /** Null follows the project; set only when the text itself says how much attention the task takes. */
  attention: 'full' | 'shared' | null
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
  context: z.enum(['computer', 'errand', 'home', 'office']),
  projectId: z.string().nullable(),
  attention: z.enum(['full', 'shared']).nullable(),
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
    context: { type: 'string', enum: ['computer', 'errand', 'home', 'office'], description: 'Where the task can be done' },
    projectId: { type: ['string', 'null'], description: 'One of the given project ids, or null when the task belongs to none' },
    attention: {
      type: ['string', 'null'],
      enum: ['full', 'shared', null],
      description: 'shared or full only when the text says so; otherwise null',
    },
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
    'context',
    'projectId',
    'attention',
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
    '- Choose categoryId only from the list below, filing the task where the user filed similar recent tasks; null when nothing fits.',
    '- context is where the task can be done: errand when it means going somewhere (a store, the post office, a return, a pickup); home when it needs being at home (laundry, a repair, waiting for a delivery); office when it needs being at the office in person; otherwise computer, which covers calls, email and anything done on a laptop.',
    '- Choose projectId only from the projects below, and only when the text names the project or is plainly part of it; otherwise null.',
    '- attention is shared when the text says an agent does the work or that it can run in the background or in parallel, full when it says the task needs the user’s whole focus, and null otherwise.',
    'Categories:',
    formatCategories(ctx.categories),
    'Projects:',
    formatProjects(ctx.projects ?? []),
  ].join('\n')

  return { system, user: text }
}

/** One line per category with its id, then its recent task titles; shared by the AI prompts. */
export function formatCategories(categories: CategoryContext[]): string {
  if (categories.length === 0) return '(none)'
  return categories
    .map((p) => {
      const line = `- id "${p.id}": ${p.name}`
      return p.examples.length === 0 ? line : `${line}\n  recent tasks: ${p.examples.map((t) => JSON.stringify(t)).join(', ')}`
    })
    .join('\n')
}

function formatProjects(projects: ProjectContext[]): string {
  if (projects.length === 0) return '(none)'
  return projects.map((p) => `- id "${p.id}": ${p.name}${p.parallel ? ' (parallel: an agent does most of the work)' : ''}`).join('\n')
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
    const knownProject = draft.projectId !== null && (ctx.projects ?? []).some((p) => p.id === draft.projectId)
    return {
      ...draft,
      categoryId: knownCategory ? draft.categoryId : null,
      projectId: knownProject ? draft.projectId : null,
      // A deadline type without a date (or vice versa) is contradictory; the date wins.
      deadlineType: draft.dueAt === null ? 'none' : draft.deadlineType === 'none' ? 'soft' : draft.deadlineType,
    }
  }
}

function pad(n: number): string {
  return n.toString().padStart(2, '0')
}
