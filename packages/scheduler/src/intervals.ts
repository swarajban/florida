/** A half-open time range [start, end) in epoch milliseconds. */
export interface Span {
  start: number
  end: number
}

/** Sorts spans and merges overlapping or touching ones. Drops empty spans. */
export function mergeSpans(spans: readonly Span[]): Span[] {
  const sorted = spans.filter((s) => s.end > s.start).sort((a, b) => a.start - b.start)
  const merged: Span[] = []
  for (const span of sorted) {
    const last = merged[merged.length - 1]
    if (last !== undefined && span.start <= last.end) {
      last.end = Math.max(last.end, span.end)
    } else {
      merged.push({ start: span.start, end: span.end })
    }
  }
  return merged
}

/** Returns a new merged list with `span` added. */
export function addSpan(merged: readonly Span[], span: Span): Span[] {
  return mergeSpans([...merged, span])
}

/** Parts of `span` not covered by `busy`, which must be sorted and non-overlapping. */
export function subtractSpans(span: Span, busy: readonly Span[]): Span[] {
  const free: Span[] = []
  let cursor = span.start
  for (const b of busy) {
    if (b.end <= cursor) continue
    if (b.start >= span.end) break
    if (b.start > cursor) free.push({ start: cursor, end: b.start })
    cursor = Math.max(cursor, b.end)
    if (cursor >= span.end) break
  }
  if (cursor < span.end) free.push({ start: cursor, end: span.end })
  return free
}
