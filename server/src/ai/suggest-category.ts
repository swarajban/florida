import { z } from 'zod'
import { type ClaudeConfig, type FetchLike, type JsonSchema, requestJson } from './claude.js'
import { type CategoryContext, formatCategories } from './parse-task.js'

export interface CategorySuggestion {
  /** One of the offered category ids, or null when none fits. */
  categoryId: string | null
  /** One sentence on why, for the UI to show next to the suggestion. */
  rationale: string
}

export interface CategorySuggester {
  /** Picks one of `categories` (the caller leaves the inbox out) for a task. */
  suggest(task: { title: string; notes: string | null }, categories: CategoryContext[]): Promise<CategorySuggestion>
}

const suggestionSchema = z.object({ categoryId: z.string().nullable(), rationale: z.string() })

export const CATEGORY_SUGGESTION_JSON_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    categoryId: { type: ['string', 'null'], description: 'One of the given category ids, or null when none fits' },
    rationale: { type: 'string', description: 'One sentence explaining the choice' },
  },
  required: ['categoryId', 'rationale'],
  additionalProperties: false,
}

/** Builds the system and user turns. Pure, so tests can assert on the exact wording. */
export function buildSuggestPrompt(
  task: { title: string; notes: string | null },
  categories: CategoryContext[],
): { system: string; user: string } {
  const system = [
    'You file one task into a category of a personal auto-scheduling calendar.',
    'Each category lists tasks the user recently filed there; choose the category where the user would file this task.',
    'Answer with a categoryId from the list below, or null when none clearly fits.',
    'Categories:',
    formatCategories(categories),
  ].join('\n')
  const user = task.notes === null || task.notes.trim() === '' ? `Title: ${task.title}` : `Title: ${task.title}\nNotes: ${task.notes}`
  return { system, user }
}

/** Suggests a category with Claude using structured output; ids outside `categories` become null. */
export class ClaudeCategorySuggester implements CategorySuggester {
  constructor(
    private readonly config: ClaudeConfig,
    private readonly fetchImpl?: FetchLike,
  ) {}

  async suggest(task: { title: string; notes: string | null }, categories: CategoryContext[]): Promise<CategorySuggestion> {
    if (categories.length === 0) return { categoryId: null, rationale: 'There are no categories to choose from.' }
    const prompt = buildSuggestPrompt(task, categories)
    const raw = await requestJson(
      this.config,
      { ...prompt, schema: CATEGORY_SUGGESTION_JSON_SCHEMA, maxTokens: 256 },
      this.fetchImpl,
    )
    const suggestion = suggestionSchema.parse(raw)
    const known = suggestion.categoryId !== null && categories.some((p) => p.id === suggestion.categoryId)
    return { categoryId: known ? suggestion.categoryId : null, rationale: suggestion.rationale }
  }
}
