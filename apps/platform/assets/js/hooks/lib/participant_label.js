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

// A person's video-only second LiveKit connection (task 01a13ca2) joins as
// `video:user:<uuid>` next to their own `user:<uuid>`. This is the JS twin of
// `Platform.Meetings.companion_identity?/1` / `person_identity/1`, and the
// prefix must stay byte-identical to theirs: the shared table in
// test/support/fixtures/companion_identities_v1.json pins all three runtimes.
// Every web grouping (tiles, speaking rings, media states, sharer label,
// transcript) goes through these two functions and nothing else.
const COMPANION_PREFIX = "video:user:"
const PERSON_PREFIX = "user:"

/** True for a companion connection's identity (`video:user:<uuid>`). */
export function isCompanionIdentity(identity) {
  return typeof identity === "string" && identity.startsWith(COMPANION_PREFIX)
}

/**
 * The person an identity belongs to: `video:user:X` -> `user:X`. Every other
 * value, including null and non-strings, is returned unchanged, exactly as
 * the server's `person_identity/1` does.
 */
export function personIdentity(identity) {
  if (!isCompanionIdentity(identity)) return identity
  return PERSON_PREFIX + identity.slice(COMPANION_PREFIX.length)
}

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

/**
 * `participant.name`, then the server map, then the identity. The map lookup
 * and the identity fallback use the PERSON identity, so a nameless companion
 * connection reads as its person and never as `video:user:…`.
 */
export function participantLabel(participant, names) {
  if (!participant) return ""
  const own = typeof participant.name === "string" ? participant.name.trim() : ""
  if (own) return participant.name
  const identity = personIdentity(participant.identity || "")
  const mapped = names && identity ? names[identity] : null
  if (typeof mapped === "string" && mapped.trim() !== "") return mapped
  return identity
}

/**
 * Every connection in `room` (local first, then remotes); [] without a room.
 */
function roomConnections(room) {
  const out = []
  if (room?.localParticipant) out.push(room.localParticipant)
  const remotes = room?.remoteParticipants
  if (remotes && typeof remotes.values === "function") {
    for (const p of remotes.values()) out.push(p)
  }
  return out
}

/**
 * The name to attribute a participant's media to (the screen-share sharer).
 *
 * In order: the connection's own LiveKit name; the name of ANOTHER connection
 * of the same person in `room` (a nameless `video:user:X` share reads as the
 * name `user:X` joined with); the server map; the person identity. The last
 * two are `participantLabel`, so a `video:` identity can never be returned.
 */
export function personLabel(participant, room, names) {
  if (!participant) return ""
  const own = typeof participant.name === "string" ? participant.name.trim() : ""
  if (own) return participant.name
  const person = personIdentity(participant.identity || "")
  if (person) {
    for (const other of roomConnections(room)) {
      if (other === participant || personIdentity(other?.identity || "") !== person) continue
      const name = typeof other.name === "string" ? other.name.trim() : ""
      if (name) return other.name
    }
  }
  return participantLabel({ identity: person, name: "" }, names)
}
