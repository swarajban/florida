import { z } from 'zod'
import { type ClaudeConfig, type FetchLike, type JsonSchema, requestJson } from './claude.js'

/** What Claude wrote about a day or a week: one line to show everywhere, and a few lines behind it. */
export interface BriefText {
  headline: string
  body: string
}

/**
 * Turns facts the server computed into prose. The model never decides what is planned: every
 * time, title and number it may mention is in `facts`, which the scheduler and the store produced.
 */
export interface BriefWriter {
  write(kind: 'daily' | 'weekly', facts: unknown): Promise<BriefText>
}

export interface PlacementExplainer {
  /** One to three sentences on why a task is planned where it is (or is not planned). */
  explain(facts: unknown): Promise<string>
}

const briefSchema = z.object({ headline: z.string().trim().min(1), body: z.string().trim().min(1) })
const explanationSchema = z.object({ explanation: z.string().trim().min(1) })

export const BRIEF_JSON_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    headline: { type: 'string', description: 'One line, at most 70 characters, no trailing period' },
    body: { type: 'string', description: 'Three to six short lines of plain text separated by newlines; no Markdown' },
  },
  required: ['headline', 'body'],
  additionalProperties: false,
}

export const EXPLANATION_JSON_SCHEMA: JsonSchema = {
  type: 'object',
  properties: { explanation: { type: 'string', description: 'One to three plain sentences; no Markdown' } },
  required: ['explanation'],
  additionalProperties: false,
}

const SHARED_RULES = [
  'Use only the facts in the JSON the user sends. Never invent a task, a time, a number or a reason.',
  'Times in the facts are local wall-clock times; write them like 9:30 or 3pm. Durations are minutes; write them as hours when that reads better.',
  'Address the user as "you". Plain text only: no Markdown, no bullets, no emoji. Each line of the body is one complete short sentence.',
].join('\n')

/** System prompts, exported so tests can assert the rules that matter are in them. */
export const DAILY_SYSTEM = [
  'You write the morning brief for one person from their planner’s data: what kind of day it is and what matters in it.',
  SHARED_RULES,
  'The headline says what kind of day it is and the one thing that matters most.',
  'In the body, in this order and skipping what does not apply:',
  '- Where they are (home, office, off) and the gym: when it is today, or, when `gym.missedThisWeek` is true, that there is no office-morning gym this week because both mornings were taken.',
  '- Meetings: how many and the first one.',
  '- The plan: the first task, and anything due today or overdue.',
  '- Parallel work: entries of `plan` and `projectTime` that share a time range and have a `lane` run side by side. Name the projects and the time, as in "From 10 to 12 you can run Atlas, Billing and Florida side by side."',
  '- What could not be scheduled, and how much free time is left today.',
  '- When `evening` is not empty, one line on what to pick up if they work tonight.',
].join('\n')

export const WEEKLY_SYSTEM = [
  'You write a weekly review for one person from their planner’s data: how the week went against their projects’ budgets, and what the coming week looks like.',
  SHARED_RULES,
  'The headline sums up the week in one line.',
  'In the body, in this order and skipping what does not apply:',
  '- For each active project with a budget: time spent against the budget, and its next step when it has one. Call out a project well under budget.',
  '- What was finished, as a count and one or two notable titles.',
  '- Projects on hold or still being thought about, in one line, only when there are any.',
  '- What is late or could not be scheduled.',
  '- The coming week: hard deadlines, days that differ from the routine, the gym sessions in `ahead.gym` (and a week listed in `ahead.weeksWithoutOfficeMorningGym`, which has no office-morning session), and the day with the least room.',
].join('\n')

export const EXPLAIN_SYSTEM = [
  'You explain to one person why their planner scheduled a task where it did, from the planner’s own data.',
  SHARED_RULES,
  'The planner places tasks by priority and deadline into the hours of the weekly routine that allow the task’s context (computer, errand, home, office), around calendar events and commitments such as the gym.',
  'Tasks of a project that is not active are not scheduled. Shared-attention work can run beside other projects’ shared work, in up to three lanes.',
  'Say when it is planned, and the one or two facts that most explain that time: its context and which routine hours allow it, what is ahead of it, its deadline, its project’s status, or that it runs in parallel. If it is not planned, say why.',
].join('\n')

/** Writes briefs and explanations with Claude using structured output. */
export class ClaudeBriefWriter implements BriefWriter, PlacementExplainer {
  constructor(
    private readonly config: ClaudeConfig,
    private readonly fetchImpl?: FetchLike,
  ) {}

  async write(kind: 'daily' | 'weekly', facts: unknown): Promise<BriefText> {
    const raw = await requestJson(
      this.config,
      { system: kind === 'daily' ? DAILY_SYSTEM : WEEKLY_SYSTEM, user: JSON.stringify(facts), schema: BRIEF_JSON_SCHEMA },
      this.fetchImpl,
    )
    return briefSchema.parse(raw)
  }

  async explain(facts: unknown): Promise<string> {
    const raw = await requestJson(
      this.config,
      { system: EXPLAIN_SYSTEM, user: JSON.stringify(facts), schema: EXPLANATION_JSON_SCHEMA, maxTokens: 400 },
      this.fetchImpl,
    )
    return explanationSchema.parse(raw).explanation
  }
}
