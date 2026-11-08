defmodule PlatformWeb.Components.VoiceSessionBlock do
  @moduledoc """
  The pieces of the Voice chat session bracket a DM row draws (task 01a1b6c3
  stage 3, design canvas 01a1b6c4 nodes `layout`, `pal`, `type`, `crit`).
  What each row draws is decided by `PlatformWeb.ChatLive.VoiceBlocks`; this
  module only renders it.

  Tokens, from the canvas palette: the bands are `--color-base-200`; the
  "Voice chat" label is the ONLY `--color-info` text; date, length, count and
  the mic glyph are `--color-neutral`, the figures in JetBrains Mono
  (`font-mono`). Turns keep the normal message styles: no tinted bubble.

  Collapse and expand are `Phoenix.LiveView.JS` class toggles over
  `[data-voice-session=<id>][data-voice-middle]`, so they never round-trip;
  each also dispatches `chat:regroup` so the list's author grouping
  (`hooks/scroll_to_bottom.js`) re-reads which rows are on screen.
  """

  use Phoenix.Component
  use PlatformWeb, :verified_routes

  alias Phoenix.LiveView.JS

  @band "bg-base-200 rounded-xl"

  @doc "Expand a collapsed session."
  def expand(session_id) do
    JS.remove_class("hidden", to: middle(session_id))
    |> JS.add_class("hidden", to: "#voice-show-all-#{session_id}")
    |> JS.remove_class("hidden", to: "#voice-collapse-#{session_id}")
    |> JS.dispatch("chat:regroup", to: "#message-list")
  end

  @doc "Collapse an expanded session back to its first and last two turns."
  def collapse(session_id) do
    JS.add_class("hidden", to: middle(session_id))
    |> JS.remove_class("hidden", to: "#voice-show-all-#{session_id}")
    |> JS.add_class("hidden", to: "#voice-collapse-#{session_id}")
    |> JS.dispatch("chat:regroup", to: "#message-list")
  end

  defp middle(session_id), do: "[data-voice-session='#{session_id}'][data-voice-middle]"

  @doc """
  The session header band: "🎙 Voice chat · <date> · <length> · <count>",
  and "Collapse" on a collapsible session. In progress (no summary yet) it
  shows the date only.
  """
  attr(:head, :map, required: true)

  def header(assigns) do
    assigns = assign(assigns, :band, @band)

    ~H"""
    <div
      id={"voice-head-#{@head.session_id}"}
      data-role="voice-session-header"
      class={[@band, "mt-3 mb-1 flex min-w-0 items-center gap-2 px-3 py-1.5 text-xs"]}
    >
      <span class="flex min-w-0 flex-1 flex-wrap items-baseline gap-x-1.5">
        <span aria-hidden="true">🎙</span>
        <span data-role="voice-label" class="font-semibold text-info">Voice chat</span>
        <span :if={@head.date} data-role="voice-meta" class="font-mono text-neutral">
          · {@head.date}
        </span>
        <span :if={@head.length} data-role="voice-meta" class="font-mono text-neutral">
          · {@head.length}
        </span>
        <span :if={@head.count} data-role="voice-meta" class="font-mono text-neutral">
          · {@head.count}
        </span>
      </span>
      <button
        :if={@head.collapsible?}
        type="button"
        id={"voice-collapse-#{@head.session_id}"}
        data-role="voice-collapse"
        class="hidden shrink-0 rounded px-1.5 py-0.5 font-semibold text-base-content lg:hover:bg-base-300 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
        phx-click={collapse(@head.session_id)}
      >
        Collapse
      </button>
    </div>
    """
  end

  @doc ~S(The "Show all {N} turns" band a collapsed session shows after its second turn.)
  attr(:session_id, :string, required: true)
  attr(:count, :integer, required: true)

  def show_all(assigns) do
    assigns = assign(assigns, :band, @band)

    ~H"""
    <button
      type="button"
      id={"voice-show-all-#{@session_id}"}
      data-role="voice-show-all"
      class={[
        @band,
        "my-1 block w-full px-3 py-1.5 text-left text-xs font-semibold text-base-content lg:hover:bg-base-300 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
      ]}
      phx-click={expand(@session_id)}
    >
      Show all {@count} turns
    </button>
    """
  end

  @doc "The small mic glyph on a voice turn."
  attr(:id, :string, required: true)

  def mic(assigns) do
    ~H"""
    <span
      id={@id}
      data-role="voice-mic"
      class="hero-microphone-micro size-3 shrink-0 self-center text-neutral"
      aria-label="Said by voice"
      role="img"
    />
    """
  end

  @doc """
  A pointer or summary row's body, inside the session band: the context
  pointer line ("Your side was posted to #<context>", linking there), or the
  summary card plus the footer ("End of voice chat · Open on Voice tab").
  """
  attr(:msg, :map, required: true)
  attr(:context_path, :string, default: nil)

  def system_body(%{msg: %{metadata: %{"voice_kind" => "context_pointer"}}} = assigns) do
    assigns = assign(assigns, :band, @band)

    ~H"""
    <div data-role="voice-pointer" class={[@band, "my-1 px-3 py-1.5 text-sm text-base-content"]}>
      <.link
        :if={@context_path}
        navigate={@context_path}
        class="underline underline-offset-2 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
      >
        {@msg.content}
      </.link>
      <span :if={is_nil(@context_path)}>{@msg.content}</span>
    </div>
    """
  end

  def system_body(assigns) do
    assigns = assign(assigns, :band, @band)

    ~H"""
    <div data-role="voice-summary" class={[@band, "mt-1 mb-3 px-3 py-2"]}>
      <p data-role="voice-summary-card" class="text-sm font-semibold text-base-content">
        {@msg.content}
      </p>
      <p
        :if={is_binary(@msg.metadata["gist"]) and @msg.metadata["gist"] != ""}
        class="mt-0.5 line-clamp-2 text-sm text-base-content"
      >
        {@msg.metadata["gist"]}
      </p>
      <p data-role="voice-footer" class="mt-1 text-xs text-base-content">
        End of voice chat ·
        <.link
          navigate={~p"/voice"}
          class="underline underline-offset-2 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
        >
          Open on Voice tab
        </.link>
      </p>
    </div>
    """
  end
end
