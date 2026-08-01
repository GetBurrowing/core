defmodule Platform.Meetings.IntentRouting do
  @moduledoc """
  The single table mapping a classified meeting intent onto the
  responsibility that serves it, and onto the PubSub topic + event atom
  the dispatch travels on.

  ## Why this module exists

  Task `019fb90f-36e3` wired ONE intent — `action_items` — onto a
  responsibility, and spread the three facts about it across three
  files: `IntentDispatcher.@responsibility_intents` held the key,
  `Meetings.PubSub` held the topic string and a bespoke broadcast
  function, and `Handlers.MeetingActionItems.register/0` re-declared the
  same topic and event atom in its `trigger_config`.

  Three copies of one fact is survivable at one intent and is not at
  six. The failure mode is silent in the worst way: the Router
  subscribes at boot to the topic strings its ENABLED ROWS declare, so
  a handler that declares `"meeting:visual_adjust_intent"` while the
  dispatcher broadcasts on `"meeting:visual_adjust"` produces no error,
  no log, and no dispatch. The intent is marked `:dispatched`, the
  meeting's serial cursor is held, and the row times out 90 seconds
  later against a listener that was never there.

  So the topic, the event atom and the responsibility key are declared
  here exactly once, and every consumer reads them from here.

  ## The event atom is NOT derived from the intent

  It would be tempting to write `:"\#{intent}_intent"` and delete the
  table. Two reasons not to:

    * **`action_items` maps to `:action_item_intent`** — singular
      "item", plural intent. That asymmetry shipped in `019fb90f-36e3`
      and is load-bearing: `MeetingActionItems.register/0` declares
      `"event_match" => "action_item_intent"`, and
      `event_topic_delivery_test.exs` binds it end-to-end. Deriving the
      atom would rename it and silently unfire the responsibility —
      which the function's own docs warn about.
    * **Building atoms from a classifier's output string is unsafe.**
      `classified_intent` is whatever a small local model emitted. The
      atom table is not garbage-collected, so `String.to_atom/1` on
      model output is an unbounded leak reachable from anything that
      can talk in a meeting. Every atom here is a compile-time literal
      and lookup is by string key, so an unknown intent returns `nil`
      rather than minting anything.

  ## Adding an intent

  Add a row here, add the handler, and add the responsibility key to
  the owning role's bundle in `Platform.Roles.Seeds`. The pairing test
  in `test/platform/meetings/intent_routing_test.exs` asserts that
  every row's `topic` and `event` match what the handler's `register/0`
  declares, so a new intent cannot be half-wired.

  Note that the responsibility key is namespaced `meetings.*` while the
  role that owns it is frequently NOT a meetings role — `visual_adjust`
  is a `meetings.` key held by the **designer**. That is deliberate per
  Rowan (2026-07-31): the namespace records where the work originates,
  the bundle records who does it.
  """

  @typedoc "One routing row."
  @type entry :: %{
          intent: String.t(),
          key: String.t(),
          topic: String.t(),
          event: atom(),
          role: String.t()
        }

  # Ordered for reading; lookup is by key so order is cosmetic.
  #
  # `role` is documentation of intent-ownership at the point the routing
  # is declared — the authoritative bundle is still
  # `Platform.Roles.Seeds.@default_roles`, and the pairing test asserts
  # the two agree rather than letting this one drift into fiction.
  @entries [
    %{
      intent: "action_items",
      key: "meetings.action_items",
      # Singular "item" — see moduledoc. Do not normalise.
      topic: "meeting:action_item_intent",
      event: :action_item_intent,
      role: "meeting_scribe"
    },
    %{
      intent: "visual_adjust",
      key: "meetings.visual_adjust",
      topic: "meeting:visual_adjust_intent",
      event: :visual_adjust_intent,
      role: "designer"
    },
    %{
      intent: "interaction_design",
      key: "meetings.interaction_design",
      topic: "meeting:interaction_design_intent",
      event: :interaction_design_intent,
      role: "designer"
    },
    %{
      intent: "brief_worthy",
      key: "meetings.brief_worthy",
      topic: "meeting:brief_worthy_intent",
      event: :brief_worthy_intent,
      role: "meeting_scribe"
    },
    %{
      intent: "decision_recorded",
      key: "meetings.decision_recorded",
      topic: "meeting:decision_recorded_intent",
      event: :decision_recorded_intent,
      role: "historian"
    },
    %{
      intent: "open_question",
      key: "meetings.open_question",
      topic: "meeting:open_question_intent",
      event: :open_question_intent,
      role: "triage_officer"
    }
  ]

  # `off_topic` is deliberately absent. The classifier emits it with
  # `target_role: null` and the dispatcher lands the row
  # `:dispatch_failed`/`:no_target_role` — which is the correct outcome
  # for small talk, and the one intent that should reach nobody.

  @by_intent Map.new(@entries, &{&1.intent, &1})

  @doc "Every routing row, in declaration order."
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc "Every classified intent string that routes to a responsibility."
  @spec intents() :: [String.t()]
  def intents, do: Enum.map(@entries, & &1.intent)

  @doc """
  The full routing row for a classified intent, or `nil` when the intent
  is served by a role's runtime rather than by a responsibility.

  `nil` is not an error. It means the intent is served by a role's
  runtime instead — `off_topic` is the standing example, and it is
  deliberately unrouted because the correct audience for small talk is
  nobody. An unrecognised string from the classifier answers `nil` for
  the same reason.

  Deliberately no list of which intents fall through. An earlier draft
  of this docstring named four, three of which gained routing rows in
  the same change that wrote it — leaving the module whose entire
  purpose is being the single source of truth for this fact carrying a
  sentence that contradicted its own `@entries` thirty lines above.
  `entries/0` and `intents/0` answer the question without going stale.
  """
  @spec entry(String.t() | atom() | any()) :: entry() | nil
  def entry(intent) when is_binary(intent), do: Map.get(@by_intent, intent)

  def entry(intent) when is_atom(intent) and not is_nil(intent),
    do: Map.get(@by_intent, Atom.to_string(intent))

  def entry(_), do: nil

  @doc """
  The responsibility key serving a classified intent, or `nil`.

  This is the fork `IntentDispatcher.dispatch_row/3` takes BEFORE role
  resolution — a non-nil answer means the row is handed to the
  Responsibilities Router instead of to a runtime.
  """
  @spec responsibility_key(String.t() | atom() | any()) :: String.t() | nil
  def responsibility_key(intent) do
    case entry(intent) do
      %{key: key} -> key
      nil -> nil
    end
  end

  @doc "The global PubSub topic a classified intent is broadcast on, or `nil`."
  @spec topic(String.t() | atom() | any()) :: String.t() | nil
  def topic(intent) do
    case entry(intent) do
      %{topic: topic} -> topic
      nil -> nil
    end
  end

  @doc """
  The event atom at the head of the broadcast tuple, or `nil`.

  This is what the Router matches against a responsibility's
  `trigger_config["event_match"]`, so it is the same string on both
  sides of the wire.
  """
  @spec event(String.t() | atom() | any()) :: atom() | nil
  def event(intent) do
    case entry(intent) do
      %{event: event} -> event
      nil -> nil
    end
  end

  @doc """
  The routing row a responsibility key belongs to, or `nil`.

  Used by handlers so `register/0` reads its topic and `event_match`
  from this table rather than restating them.
  """
  @spec entry_for_key(String.t()) :: entry() | nil
  def entry_for_key(key) when is_binary(key),
    do: Enum.find(@entries, &(&1.key == key))

  def entry_for_key(_), do: nil
end
