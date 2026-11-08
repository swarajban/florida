/**
 * In-process fan-out of "something changed, pull again" notifications. Every scheduler run and
 * every calendar sync publishes; `/api/events` streams the notifications to connected clients so
 * they can pull `/api/sync` immediately instead of polling.
 */
export interface ChangeNotice {
  /** Server time of the change, ISO 8601. Clients pass their stored cursor to `/api/sync`, not this. */
  at: string
}

export type ChangeListener = (notice: ChangeNotice) => void

export class ChangeBus {
  private readonly listeners = new Set<ChangeListener>()

  subscribe(listener: ChangeListener): () => void {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }

  publish(at: Date = new Date()): void {
    const notice: ChangeNotice = { at: at.toISOString() }
    for (const listener of this.listeners) listener(notice)
  }

  get size(): number {
    return this.listeners.size
  }
}
