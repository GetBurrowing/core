/**
 * Display labels for LiveKit participants (task 01a1117f stage 5).
 *
 * The /meetings transcript pane and the quick-meet tiles name a remote
 * participant from the LiveKit `Participant` object alone. A legacy voice
 * worker joins under LiveKit's default job identity (`agent-AJ_…`) with no
 * name, so both surfaces used to print that raw identity even after core had
 * folded the row onto its agent (Burrow).
 *
 * The server knows better: it renders `data-participant-names` on the hook
 * element, a JSON object from LiveKit identity to display name for the
 * room's resolved AGENT rows (`MeetingLive.participant_names_json/1`). The
 * label is, in order: the participant's own LiveKit name, that map, the
 * identity. Humans carry a name from their token, so their labels never
 * reach the map; an identity nobody resolved keeps its identity, so nothing
 * is hidden.
 */

/** Parse `el.dataset.participantNames`; missing or malformed gives `{}`. */
export function readParticipantNames(el) {
  const raw = el && el.dataset && el.dataset.participantNames
  if (!raw) return {}
  try {
    const parsed = JSON.parse(raw)
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {}
  } catch (_) {
    return {}
  }
}

/** `participant.name`, then the server map, then the identity. */
export function participantLabel(participant, names) {
  if (!participant) return ""
  const own = typeof participant.name === "string" ? participant.name.trim() : ""
  if (own) return participant.name
  const identity = participant.identity || ""
  const mapped = names && identity ? names[identity] : null
  if (typeof mapped === "string" && mapped.trim() !== "") return mapped
  return identity
}
