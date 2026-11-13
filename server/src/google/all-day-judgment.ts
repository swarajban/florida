export interface AllDayJudgmentEvent {
  allDay: boolean
  eventType: string | null
  summary: string | null
  description: string | null
  startAt: Date | null
  endAt: Date | null
}

export interface AllDayJudgmentCalendar {
  accountId: string
  googleId: string
  summary: string
}

export interface AllDayAccountProfile {
  id: string
  email: string
  displayName: string | null
}

export interface AllDayJudgment {
  blocks: boolean
  reason: string
}

export function judgeAllDayEvent(
  event: AllDayJudgmentEvent,
  calendar: AllDayJudgmentCalendar,
  accountProfiles: readonly AllDayAccountProfile[],
): AllDayJudgment {
  if (!event.allDay) return { blocks: false, reason: 'Not an all-day event' }
  if (event.eventType === 'birthday') return { blocks: false, reason: 'Birthday or anniversary' }
  if (event.eventType === 'focusTime') return { blocks: false, reason: 'Focus time' }
  if (event.eventType === 'workingLocation') return { blocks: false, reason: 'Working location' }

  const title = (event.summary ?? '').normalize('NFKC').trim().replace(/\s+/gu, ' ')
  const description = (event.description ?? '').replace(/<br\s*\/?>|<\/p>|<\/div>/giu, '\n')
    .replace(/<[^>]*>/gu, '').replace(/&nbsp;|&#160;/giu, ' ').trim()
  const descriptionLabel = description.split(/\r?\n/u)[0]?.trim() ?? ''
  const gusto = /^gusto\b/iu.test(calendar.summary.trim())
  const owner = accountProfiles.find((profile) => profile.id === calendar.accountId)
  const ownPrimary = owner !== undefined && owner.email.trim() !== ''
    && owner.email.trim().toLowerCase() === calendar.googleId.trim().toLowerCase()

  if (/(?:^|[#.])contacts@group\.v\.calendar\.google\.com$/iu.test(calendar.googleId)
    || /\bbirthdays?\b|\banniversar(?:y|ies)\b/iu.test(title)) {
    return { blocks: false, reason: 'Birthday or anniversary' }
  }
  if (/\bstart date\b/iu.test(title)) return { blocks: false, reason: 'Work anniversary' }
  if (/\bschool\b/iu.test(`${calendar.summary} ${title}`)) return { blocks: false, reason: 'School notice' }
  if (/\bobservances?\b/iu.test(title) || /^observance[.!]?$/iu.test(descriptionLabel)) {
    return { blocks: false, reason: 'Observance' }
  }

  const span = event.startAt !== null && event.endAt !== null
    ? event.endAt.getTime() - event.startAt.getTime() : NaN
  if (!Number.isFinite(span) || span <= 0) return { blocks: false, reason: 'Unclassified' }

  if (event.eventType === 'outOfOffice' && ownPrimary) return { blocks: true, reason: 'Your time off' }

  const timeOff = /\b(?:ooo|out[ -]of[ -]office|time[ -]off|pto|vacation|annual leave|sick leave)\b/iu.exec(title)
  if (timeOff !== null) {
    const before = nameKey(title.slice(0, timeOff.index).replace(/^pending\s+/iu, '').replace(/\b(?:is|on|will be)\s*$/iu, ''))
    const after = nameKey(title.slice(timeOff.index + timeOff[0].length))
    const subject = before !== '' && after !== '' ? null : before || after
    const ownName = subject !== null && subject !== '' && accountProfiles.some((profile) => {
      if (profile.displayName === null) return false
      const name = nameKey(profile.displayName)
      const words = name.split(' ')
      return name !== '' && (name === subject || (words.length >= 2 && `${words[0]} ${words.at(-1)?.slice(0, 1)}` === subject))
    })
    if (ownName && (gusto || ownPrimary)) return { blocks: true, reason: 'Your time off' }
    if ((subject === '' || subject === 'my') && ownPrimary) return { blocks: true, reason: 'Your time off' }
    if (gusto) {
      const unidentified = owner === undefined || subject === null || subject === '' || subject === 'my'
        || !accountProfiles.some((profile) => profile.displayName !== null && nameKey(profile.displayName) !== '')
      return { blocks: false, reason: unidentified ? 'Unclassified' : 'Someone else’s time off' }
    }
  }

  if (event.eventType === 'outOfOffice') {
    return { blocks: false, reason: owner === undefined ? 'Unclassified' : 'Someone else’s time off' }
  }

  if (/^public holiday[.!]?$/iu.test(descriptionLabel)) return { blocks: true, reason: 'Public holiday' }
  if (/^today is a paid company holiday\. enjoy your time off!$/iu.test(description.replace(/\s+/gu, ' '))
    || /^(?:company|office)[ -](?:wide[ -])?(?:holiday|closed|closure)(?:$|\s*[:–—-]\s*\S)/iu.test(title)) {
    return { blocks: true, reason: 'Company holiday' }
  }
  if (gusto) return { blocks: false, reason: 'Gusto reminder' }

  if (ownPrimary && /^(?:my\s+)?(?:(?:business|family)\s+)?(?:trip|vacation|travel)(?:$|\s+(?:to|in|at|from)\b)/iu.test(title)) {
    return { blocks: true, reason: 'Your trip' }
  }
  if (ownPrimary && event.eventType === 'fromGmail' && /^stay at\s+\S/iu.test(title) && span > 86_400_000) {
    return { blocks: true, reason: 'Your trip' }
  }
  if (timeOff !== null && nameKey(title) !== nameKey(timeOff[0])) {
    return { blocks: false, reason: owner === undefined ? 'Unclassified' : 'Someone else’s time off' }
  }
  if (/^[\p{L}][\p{L}\p{M}.'’ -]*\s+in\s+\S/iu.test(title)
    || (!ownPrimary && /^(?:trip|travel|vacation)(?:$|\s+(?:to|in|at|from)\b)/iu.test(title))
    || /^[\p{L}][\p{L}\p{M}.'’ ]*\s*[-:–—]\s*(?:trip|travel|vacation)\b/iu.test(title)) {
    return { blocks: false, reason: owner === undefined ? 'Unclassified' : 'Someone else’s trip' }
  }
  return { blocks: false, reason: 'Unclassified' }
}

function nameKey(value: string): string {
  return value.normalize('NFKC').toLowerCase().replace(/['’]s\b/gu, '')
    .replace(/[^\p{L}\p{M}\p{N}]+/gu, ' ').trim()
}
