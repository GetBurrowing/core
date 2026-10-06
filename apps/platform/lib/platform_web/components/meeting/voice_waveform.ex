defmodule PlatformWeb.Components.Meeting.VoiceWaveform do
  @moduledoc """
  The voice-only presence glyph: a few vertical bars on a rounded square,
  shown where an avatar would sit for an agent that is in the call by VOICE
  (task 01a1117f stage 4).

  Ported from Saru's canvas 01a11183-8861 ("Meeting transcriber: name and
  presence", section "Signature element: the four-bar listening glyph"),
  which drew it for the transcriber row. The values are the canvas's:

    * **Rail** (`size: :rail`, 4 bars): a 32px square with an 8px radius
      (`rx="8"`), bars 3px wide with 2px gaps and rounded ends, at most 20px
      tall (the canvas's tallest bar).
    * **Tile** (`size: :tile`, 8 bars): the canvas's fallback tile, "a
      centred 8-bar version of the same waveform at max 48px high", on the
      tile's own `bg-base-200` ground. Same 3px bar and 2px gap.

  ## Colour: `currentColor`, not a named token

  Bars are the surface's text colour at 60%, the square the same colour at
  8% (the canvas's `base-content /60` on `base-content /8`). They are
  written against `currentColor` so the glyph takes its text colour from
  where it sits:

    * in a gallery tile the wrapper sets `text-base-content`, so the bars
      ARE `base-content /60` on `base-200` in both themes;
    * in the participant rail the Agents section is the Ask mockup's
      fixed-dark surface (`.meeting-ask`, `assets/css/meeting_ask.css`),
      whose text colour is its own `--t`. `base-content` there would be the
      LIGHT theme's near-black on that dark ground and the bars would
      vanish, so the rail glyph inherits `--t` instead.

  No new colour token, no raw hex, never `primary` (cyan stays the
  speaking ring and the Ask key).

  ## Motion

  The bars move by CSS `transform: scaleY` only. The `MeetingVoiceWaveform`
  hook (`assets/js/hooks/meeting_voice_waveform.js`) paints them with
  `paintBars` from `ptt_waveform.js`, from this participant's SFU
  `audioLevel`, at most every 80ms and only while the participant is
  speaking. Silent, it clears its interval and sets `data-wave-state="idle"`,
  and the slow idle keyframe in `app.css` takes over (deviation 1 of the
  stage spec: the canvas has a static idle; the ticket asks for a subtle
  idle animation). `prefers-reduced-motion` flattens both to a static
  mid-height profile, the per-bar `--wave-mid` below.

  ## Two elements, and why

  The OUTER span is the hook element: stable `id`, `phx-hook`,
  `phx-update="ignore"` (or morphdom would strip the JS-set transforms on
  every patch) and `data-identity`. The INNER span is the glyph itself,
  `[data-voice-waveform]`, and it carries the JS-owned `data-wave-state`.

  The state cannot live on the outer element. On an ignored element
  LiveView 1.1 still syncs `data-*` attributes with the server render, and
  REMOVES any `data-*` the server did not render
  (`deps/phoenix_live_view/assets/js/phoenix_live_view/dom.js`,
  `mergeAttrs/3`, the `isIgnored` branch). So a hook-set
  `data-wave-state` on the outer span is stripped on every patch of the
  row, which in the rail happens every few seconds (measured on the dev
  rig: the rail glyph read `undefined` within seconds of mounting, while a
  freshly promoted tile still read `active`). Children of an ignored
  element are never patched, so the inner span keeps what the hook sets.
  """

  use Phoenix.Component

  attr(:id, :string, required: true, doc: "stable dom id; the hook needs it")
  attr(:identity, :string, required: true, doc: "the participant's LiveKit identity")
  attr(:bars, :integer, default: 4, values: [4, 8])
  attr(:size, :atom, default: :rail, values: [:rail, :tile])
  attr(:class, :any, default: nil)

  def voice_waveform(assigns) do
    assigns = assign(assigns, :mids, mid_profile(assigns.bars))

    ~H"""
    <span
      id={@id}
      phx-hook="MeetingVoiceWaveform"
      phx-update="ignore"
      data-voice-waveform-root
      data-identity={@identity}
      aria-hidden="true"
      class={["inline-flex shrink-0", @class]}
    >
      <span
        data-voice-waveform
        data-size={Atom.to_string(@size)}
        data-identity={@identity}
        class={[
          "inline-flex shrink-0 items-center justify-center gap-[2px]",
          @size == :rail && "size-8 rounded-[8px] bg-current/8",
          @size == :tile && "h-12 text-base-content"
        ]}
      >
        <span
          :for={mid <- @mids}
          data-wave-bar
          class={[
            "block w-[3px] origin-center rounded-full bg-current/60 transition-transform duration-75",
            @size == :rail && "h-5",
            @size == :tile && "h-12"
          ]}
          style={"--wave-mid: #{mid}"}
        >
        </span>
      </span>
    </span>
    """
  end

  # The static mid-height profile `prefers-reduced-motion` shows. The rail's
  # four values are the canvas's own "Listening" frame (bar heights 8, 16,
  # 20 and 12 of 20px). The tile's eight are the same centre-weighted shape
  # `barScale/3` in ptt_waveform.js gives at level 0.45, so both read as one
  # family.
  defp mid_profile(4), do: ["0.4", "0.8", "1", "0.6"]

  defp mid_profile(8),
    do: ["0.45", "0.6", "0.76", "0.91", "0.91", "0.76", "0.6", "0.45"]
end
