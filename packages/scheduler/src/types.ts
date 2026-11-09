export type Priority = 'asap' | 'high' | 'medium' | 'low'

export type DeadlineType = 'hard' | 'soft' | 'none'

/**
 * Where a task can be done. A routine block lists the contexts it allows, so an errand never
 * lands in office hours and office-only work never lands on a home day.
 */
export type TaskContext = 'computer' | 'errand' | 'home' | 'office'

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
   * Task contexts that may be placed in this block. Empty for blocks that only document time
   * nothing goes into (family time, the gym); time outside every allowing block is unavailable.
   */
  allows: TaskContext[]
}

/** The user's week: when tasks may go, and which kinds. Replaces per-category schedules. */
export interface Routine {
  /** IANA time zone, e.g. "America/Los_Angeles". */
  timeZone: string
  blocks: RoutineBlock[]
}

export interface Task {
  id: string
  context: TaskContext
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
}

export interface Placement {
  taskId: string
  start: string
  end: string
  pinned: boolean
}

export type UnscheduledReason =
  | 'no_fit_in_horizon'
  | 'no_fit_before_hard_deadline'
  /** No routine block allows the task's context, so there is nowhere it could ever go. */
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
}
