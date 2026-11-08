export type Priority = 'asap' | 'high' | 'medium' | 'low'

export type DeadlineType = 'hard' | 'soft' | 'none'

/** A weekly availability window, expressed as wall-clock time in the schedule's time zone. */
export interface ScheduleWindow {
  /** Days of week the window applies to: 0 = Sunday … 6 = Saturday. */
  days: number[]
  /** Start of the window, "HH:MM" in 24-hour time. */
  start: string
  /** End of the window, "HH:MM" in 24-hour time. Must be after `start` and on the same day. */
  end: string
}

export interface Schedule {
  id: string
  /** IANA time zone, e.g. "America/Los_Angeles". */
  timeZone: string
  windows: ScheduleWindow[]
}

export interface Task {
  id: string
  scheduleId: string
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
  /** ISO 8601 instant. Nothing is placed before it. */
  now: string
  schedules: Schedule[]
  /** Open tasks only; completed tasks must not be passed. */
  tasks: Task[]
  /** Time that is unavailable: calendar events and anything else that blocks. */
  busy: Interval[]
  /** How far ahead of `now` to place tasks. Default 28. */
  horizonDays?: number
  /** Placement grid in minutes; starts snap up to it. Default 15. */
  granularityMinutes?: number
  /**
   * Daily wall-clock window, in each schedule's time zone, used for hard-deadline tasks that
   * cannot fit inside their schedule before the deadline. Default 07:00–23:00.
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
  | 'unknown_schedule'

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
  /** Tasks whose ETA passes their due time (soft deadlines; hard deadlines never do). */
  late: Late[]
}
