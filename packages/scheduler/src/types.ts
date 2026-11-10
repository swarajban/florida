export type Priority = 'asap' | 'high' | 'medium' | 'low'

export type DeadlineType = 'hard' | 'soft' | 'none'

/**
 * Where a task can be done. A routine block lists the contexts it allows, so an errand never
 * lands in office hours and office-only work never lands on a home day.
 */
export type TaskContext = 'computer' | 'errand' | 'home' | 'office'

/** The side of life a task's category belongs to. Only orders suggestions for optional blocks. */
export type TaskArea = 'work' | 'personal'

/**
 * How much of the user a task takes. `shared` work mostly runs itself (an agent working on a
 * project) and can sit beside other shared work; `full` work is done alone.
 */
export type Attention = 'full' | 'shared'

/** One weekly slot: a weekday (0 = Sunday … 6 = Saturday) and "HH:MM" bounds on that day. */
export interface RoutineSlot {
  day: number
  start: string
  end: string
}

/** A weekly block of the routine, expressed as wall-clock time in the routine's time zone. */
export interface RoutineBlock {
  id: string
  /** Days of week the block applies to: 0 = Sunday … 6 = Saturday. */
  days: number[]
  /** Start of the block, "HH:MM" in 24-hour time. */
  start: string
  /** End of the block, "HH:MM" in 24-hour time. Must be after `start` and on the same day. */
  end: string
  /**
   * Task contexts that may be placed in this block; time outside every allowing block is
   * unavailable. A block that allows nothing is a commitment, such as the gym: its occurrences
   * are time nothing is planned into, even inside another block, and come back in
   * `SchedulerResult.routine`.
   */
  allows: TaskContext[]
  /**
   * Commitments only: besides its `days`, the block happens once more each week (Sunday to
   * Saturday), in the first of these slots that no busy interval overlaps. A week whose slots
   * are all taken goes without, and is listed in `SchedulerResult.missed`.
   */
  alternates?: RoutineSlot[]
  /**
   * Time the user might work but does not count on, such as a weekday evening. The plan never
   * uses an optional block; the scheduler only suggests what to do there, in
   * `SchedulerResult.optional`.
   */
  optional?: boolean
}

/** The user's week: when tasks may go, and which kinds. Replaces per-category schedules. */
export interface Routine {
  /** IANA time zone, e.g. "America/Los_Angeles". */
  timeZone: string
  blocks: RoutineBlock[]
}

/** What a day is, when it differs from its weekday's routine. */
export type DayKind = 'home' | 'office' | 'off'

/**
 * One date that departs from the routine. An `off` day has no blocks and no commitments. A
 * `home` or `office` day follows the routine of the first weekday (Monday first) that normally
 * is one: its blocks, and its commitments. A weekday is an office day when one of its planned
 * blocks allows `office`, and a home day when it has any other planned block.
 */
export interface DayOverride {
  /** Local date in the routine's time zone, "YYYY-MM-DD". */
  date: string
  kind: DayKind
}

export interface Task {
  id: string
  context: TaskContext
  /** Default `full`. A pinned task always takes its time alone. */
  attention?: Attention
  /**
   * Shared tasks of one project never run side by side: parallel lanes are for different
   * projects. A shared task without a project only excludes itself.
   */
  projectId?: string
  /** Omit for unfiled tasks, which rank with work. */
  area?: TaskArea
  durationMinutes: number
  /**
   * Smallest piece the task may be split into. Omit to require one contiguous block.
   * The final piece may be shorter than this when less than a chunk remains.
   */
  minChunkMinutes?: number
  priority: Priority
  deadlineType: DeadlineType
  /** ISO 8601 instant. Ignored when `deadlineType` is "none". */
  dueAt?: string
  /** ISO 8601 instant before which the task must not be placed. */
  startAt?: string
  /** Minutes already worked, subtracted from `durationMinutes`. */
  completedMinutes?: number
  /** When set, the task is placed exactly here as one block and never moved. ISO 8601. */
  pinnedStart?: string
  /** ISO 8601 instant; used as the final ordering tiebreaker. */
  createdAt: string
}

/** A half-open time range [start, end) in ISO 8601. */
export interface Interval {
  start: string
  end: string
}

export interface SchedulerInput {
  /** ISO 8601 instant. New flexible blocks never start before it; in-progress blocks may. */
  now: string
  routine: Routine
  /** Open tasks only; completed tasks must not be passed. */
  tasks: Task[]
  /** Time that is unavailable: calendar events and anything else that blocks. */
  busy: Interval[]
  /**
   * Prior run's placements. Pinned tasks ignore these. A block in progress (start ≤ now < end)
   * keeps its start. Time already spent in it counts as worked unless `completedMinutes` already
   * covers it, so logging progress mid-block never counts the same minutes twice; the block then
   * runs on only while work remains, and never ends before `now`. Busy intervals starting after
   * `now`, and pinned work that is running or upcoming, cut an active block short; the rest of
   * its work is rescheduled. Routine and start-date changes do not move active work. Finished
   * tasks and past blocks are ignored: time in a block that ended unlogged is still owed.
   * Future blocks are reused whole, in task ordering, if they still fit remaining work,
   * the horizon, a routine block allowing the task's context, start date, hard deadline, and
   * time not already occupied. Only work not retained is placed into the earliest free slots.
   * Omit for a fresh plan.
   */
  previous?: Placement[]
  /** How far ahead of `now` to place tasks. Default 28. */
  horizonDays?: number
  /** Placement grid in minutes; starts snap up to it. Default 15. */
  granularityMinutes?: number
  /**
   * Daily wall-clock window, in the routine's time zone, used for hard-deadline tasks that cannot
   * fit inside the routine before the deadline. Default 07:00–23:00.
   */
  overflowWindow?: { start: string; end: string }
  /** How many local days, starting today, get suggestions for their optional blocks. Default 7. */
  optionalDays?: number
  /** Dates that depart from the weekly routine. */
  dayOverrides?: DayOverride[]
  /** How many shared tasks may run side by side. Default 3. */
  maxParallel?: number
}

export interface Placement {
  taskId: string
  start: string
  end: string
  pinned: boolean
  /**
   * Shared-attention work only: which of the `maxParallel` side-by-side lanes the block is in,
   * from 0. Blocks that overlap in time are in different lanes and belong to different projects.
   * In `previous`, a shared block keeps its lane when that lane is still free.
   */
  lane?: number
}

/** One occurrence of a commitment (a routine block that allows nothing). No task is behind it. */
export interface RoutineOccurrence {
  blockId: string
  start: string
  end: string
}

/** A week in which none of a commitment's `alternates` was free. */
export interface MissedCommitment {
  blockId: string
  /** Local date of the Sunday that starts the week, "YYYY-MM-DD". */
  weekOf: string
}

/** Time still open on one local day after the plan, per task context. */
export interface DayCapacity {
  /** Local date in the routine's time zone, "YYYY-MM-DD". */
  date: string
  /** Minutes from `now` on in planned blocks allowing the context, with nothing in them. */
  freeMinutes: Record<TaskContext, number>
}

/**
 * A suggestion for an optional block: what to do there if the user chooses to work. It is not
 * part of the plan. The task keeps its planned blocks, and the same task may be suggested for
 * several blocks.
 */
export interface OptionalPlacement {
  taskId: string
  /** The optional routine block the suggestion sits in. */
  blockId: string
  start: string
  end: string
}

export type UnscheduledReason =
  | 'no_fit_in_horizon'
  | 'no_fit_before_hard_deadline'
  /** No planned (non-optional) routine block allows the task's context, so the plan has nowhere for it. */
  | 'no_allowed_block'

export interface Unscheduled {
  taskId: string
  reason: UnscheduledReason
  /** Minutes of the task that could not be placed. Partial placements, if any, are kept. */
  unplacedMinutes: number
}

export interface Late {
  taskId: string
  dueAt: string
  /** When the last placed piece ends. */
  eta: string
}

export interface SchedulerResult {
  /** Sorted by start, then task id. */
  placements: Placement[]
  unscheduled: Unscheduled[]
  /** Tasks whose ETA passes their due time. Only retained active work can pass a hard deadline. */
  late: Late[]
  /** Suggestions for optional blocks, sorted by start, then task id. Never counted above. */
  optional: OptionalPlacement[]
  /**
   * Commitment occurrences from the Sunday of the current week to the horizon, sorted by start.
   * Tasks are never placed over them.
   */
  routine: RoutineOccurrence[]
  missed: MissedCommitment[]
  /** The next 7 local days, today first. */
  capacity: DayCapacity[]
}
