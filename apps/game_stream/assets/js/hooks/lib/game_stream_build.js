// The Building card's pure rules (task 01a17b51 stage 3; design canvas
// 01a170ca addendum 2b). The server renders the first view; these keep a
// phx-update="ignore" card current as statuses arrive. Mirrored by
// Platform.Chat.Canvas.Kinds.GameStream (build_step/1, build_failure_step/1,
// longer_than_usual?/2), and pinned against it by the same word lists.

// The step words the play host puts at the start of a building detail.
// "Preparing" and Godot's "Importing assets" are not steps.
export const BUILD_STEPS = ["Editor scripts", "Compiling", "Cooking", "Staging", "Packaging", "Archiving"]

export function buildStep(detail) {
  if (typeof detail !== "string") return null
  return (
    BUILD_STEPS.find(w => detail === w || detail.startsWith(w + " ") || detail.startsWith(w + ":")) || null
  )
}

// What follows the short sha in the card's title.
export function buildTail(detail) {
  const step = buildStep(detail)
  return step ? ` · ${step}` : " on the play host…"
}

// The step a failed build stopped in, from "Build failed during Cooking: ..."
// or "Build timed out during Cooking" (with or without the host's "build: "
// prefix); null for any other failure.
export function buildFailureStep(detail) {
  if (typeof detail !== "string") return null
  const m = /^(?:build: )?Build (?:failed|timed out) during (Editor scripts|[A-Z][a-z]+)\b/.exec(detail)
  return m ? m[1] : null
}

// True once the build has run more than twice as long as the last one.
// Never without a last build, and never at a fixed number of seconds.
export function longerThanUsual(elapsedMs, lastBuildMs) {
  return (
    Number.isFinite(elapsedMs) && Number.isFinite(lastBuildMs) && lastBuildMs > 0 && elapsedMs > 2 * lastBuildMs
  )
}
