defmodule PlatformWeb.Components.Meetings.TranscriptPane do
  @moduledoc """
  The scrollback behind the call rail's Transcript tab (task 01a06524).

  This component renders the HOST and the empty state, nothing more. The
  lines themselves are written by the `MeetingTranscript` JS hook from
  `meeting:caption` — a client-side DOM CustomEvent that `meeting_room.js`
  dispatches from LiveKit's `TranscriptionReceived`. The payload never
  reaches the server, so there is nothing here for LiveView to render a
  list from; the hook appends into this element and `phx-update="ignore"`
  keeps morphdom from discarding the buffer on the next patch. The hook
  pushes NOTHING back, which is why it may live anywhere in the root
  LiveView's markup without the `pushEvent`-ignores-`phx-target` hazard
  — but it must never be re-parented under a LiveComponent, because the
  next person to add a push would hit that hazard silently.

  Two attributes are load-bearing for the host:

    * `phx-update="ignore"` — without it every LiveView patch would erase
      the transcript mid-call. `transcript_pane_test.exs` pins it.
    * `id` must be STABLE across renders, both because a hook needs one
      and because morphdom keys the ignored subtree on it.

  Under `phx-update="ignore"` the element's non-`data-*` attributes are
  PRESERVED across renders, so no server-driven class or `hidden` flip
  may live on this element. `CallShell` wraps it in an outer div it owns
  for exactly that purpose (`data-role="meeting-transcript-wrap"`).

  The empty state is rendered OUTSIDE the host, as a sibling `<p>` before
  it, for the mirror-image reason (task 01a0693d): anything inside the
  ignored host is frozen at first render, so a `captions_available` that
  changes on a later patch never reached the copy. As a sibling it lands
  in the LiveView-owned wrap and re-renders like any other assign. The
  hook hides it once lines exist by toggling `transcript-has-lines` on
  its OWN host (a client-added class on an ignored element survives, a
  client-added attribute on the LiveView-owned `<p>` would not: morphdom
  re-syncs attributes on every patch and `/meetings` patches constantly),
  and one `:has()` rule in `app.css` does the hiding.

  Design direction: Saru's canvas `01a068fc-991d-7001-a3fd-a1845732477b`.
  The pane is the tab, not a card inside it; the only rule is a hairline
  on speaker change; `primary` appears once, on the jump-to-live pill.
  All of that is rendered by the hook — see `meeting_transcript.js`.
  """
  use Phoenix.Component

  attr(:id, :string, required: true, doc: "stable DOM id of the hook host")

  attr(:captions_available, :boolean,
    default: true,
    doc: """
    Whether captions can reach this surface at all. False when the media
    plane that emits `TranscriptionReceived` is not configured, in which
    case the pane says so outright instead of showing a "nothing yet"
    line that implies a transcriber is attached and merely quiet.
    """
  )

  def transcript_pane(assigns) do
    ~H"""
    <%!-- Honest empty state, a SIBLING of the hook host on purpose — see
         the moduledoc. It must never read as "transcription is running":
         if the room has no transcriber attached, nothing is being
         captured, and a spinner or a "Listening…" line would be the
         always-on lie the `Listening` refusal exists to prevent. The word
         "listening" is also spoken for on `/meetings` by the intents bar
         (Saru's canvas, "Three calls"), so it is refuted by test. --%>
    <p
      :if={@captions_available}
      class="px-3 py-5 text-[12.5px] leading-normal text-base-content/50"
      data-role="transcript-empty"
    >
      No speech yet. Lines appear here as people talk.
    </p>
    <p
      :if={!@captions_available}
      class="px-3 py-5 text-[12.5px] leading-normal text-base-content/50"
      data-role="transcript-empty"
    >
      Captions are unavailable for this meeting, so no transcript lines will
      appear here.
    </p>
    <div
      id={@id}
      phx-hook="MeetingTranscript"
      phx-update="ignore"
      data-role="meeting-transcript"
      class="relative min-h-0 flex-1 overflow-y-auto overscroll-contain pb-2"
    >
    </div>
    """
  end
end
