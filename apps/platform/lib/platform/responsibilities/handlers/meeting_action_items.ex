defmodule Platform.Responsibilities.Handlers.MeetingActionItems do
  @moduledoc """
  `meetings.action_items` responsibility provider (ADR-0041 Meeting Scribe
  bundle stage 3, task 019f2455).

  Implements the M1 `Platform.Responsibilities.Provider` behaviour for
  the per-meeting action-items extraction that fires alongside
  `meetings.summarize` on the canonical `meeting:finished` event the
  `PlatformWeb.LivekitWebhookController` emits via
  `Platform.Meetings.PubSub.broadcast_meeting_finished/2`.

  ## Spec

    * `key` — `"meetings.action_items"`
    * `feature` — `"meetings"`
    * `trigger_kind` — `event_topic` with `topic: "meeting:finished"`
      (same fan-in topic `meetings.summarize` uses — both responsibilities
      co-subscribe and both fire per meeting)
    * `scope` — `per_meeting`
    * `context_provided` — `["org_identity", "meeting_transcript"]`
    * `output_contract` — `%{"action_items" => "list[string]"}`

  ## Output handling

  Registration-only handler for the M8 stage 3 wiring pass. The Meeting
  Scribe role gets a real row per bundle responsibility so the router →
  role → bundle chain resolves at boot; downstream side-effects
  (e.g. persist action items to the meeting transcript, post to the
  chat space, notify owners) land in a follow-up ticket. `handle_output`
  is a benign log-and-return-`:ok` so a rogue fire before that work
  ships doesn't crash the router.

  ## Wildcard-topic note

  Same as `MeetingSummarize` — Phoenix.PubSub has no wildcard subscribe,
  so the `topic_pattern: "meeting:finished:*"` documented here is
  advisory. The router subscribes to the canonical `"meeting:finished"`
  topic and `PubSub.broadcast_meeting_finished/2` mirrors every per-room
  broadcast there.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Responsibilities.Responsibility

  @key "meetings.action_items"
  @feature "meetings"

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  # ── Provider callbacks ─────────────────────────────────────────────────────

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "event_topic",
        trigger_config: %{
          # Canonical topic the M6 router subscribes to. Mirrors
          # `MeetingSummarize` so both Meeting Scribe responsibilities
          # fan in from the same publisher.
          "topic" => "meeting:finished",
          "topic_pattern" => "meeting:finished:*",
          "event_match" => "meeting_finished"
        },
        scope: "per_meeting",
        context_provided: ["org_identity", "meeting_transcript"],
        output_contract: %{"action_items" => "list[string]"},
        default_prompt_template: "meetings.action_items.v1",
        cost_profile: "low_freq_capable",
        metadata: %{"owner" => "platform.meetings"}
      }
    ]
  end

  @impl true
  def gather_context(%Responsibility{} = _responsibility, _ctx) do
    # Registration-only handler — the router still resolves the shared
    # meetings context slots via the provider shim, so this callback
    # returns an empty map and lets the Router's `dispatch_external`
    # path fall through to the shim.
    {:ok, %{}}
  end

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed) do
    handle_output(responsibility, parsed, %{kind: :unknown})
  end

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed, trigger_meta)
      when is_map(trigger_meta) do
    items = extract_items(parsed)

    Logger.info(
      "[meetings.action_items] received #{length(items)} action item(s) " <>
        "responsibility=#{responsibility.key} trigger_kind=#{inspect(Map.get(trigger_meta, :kind))}"
    )

    :ok
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp extract_items(%{"action_items" => list}) when is_list(list),
    do: Enum.filter(list, &is_binary/1)

  defp extract_items(%{action_items: list}) when is_list(list),
    do: Enum.filter(list, &is_binary/1)

  defp extract_items(other) do
    Logger.warning(
      "[meetings.action_items] handler received unexpected output shape — " <>
        "expected %{action_items: [string]}; got " <> inspect(other)
    )

    []
  end
end
