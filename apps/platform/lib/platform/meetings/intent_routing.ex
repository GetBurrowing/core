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
  The operator (2026-07-31): the namespace records where the work originates,
  the bundle records who does it.
  """

  alias Platform.Roles.Role

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

  # `off_topic` is deliberately absent from `@entries`, and absence alone
  # was not enough — see `@unroutable_intents` below.

  # The intents that reach NOBODY, whatever else a classification says
  # about them.
  #
  # Absence from `@entries` says "no responsibility serves this". It does
  # NOT say "this reaches nobody", because `routable?/2` has a second
  # branch: a role. The classifier is a cheap model answering a schema
  # that demands a `target_role` STRING on every answer, so
  # `{"intent": "off_topic", "target_role": "meeting_scribe"}` is an
  # ordinary output — and through the second branch it armed a card and
  # the countdown minted small talk into `tasks` (task 01a06575).
  #
  # A role named on a decline is model noise, not routing. It is the
  # answer to "who would act IF anybody did", asked of a model that has
  # just said nobody should. So the intent decides first and the role is
  # never consulted for a member of this list.
  #
  # This is a list rather than a hardcoded `"off_topic"` so that the
  # standing example is not the only thing the rule can express, but it
  # is NOT a general escape hatch: an intent belongs here only when the
  # correct audience for it is nobody. An intent that is merely unserved
  # today (`pull_numbers`) is not unroutable — it goes to its role's
  # runtime.
  @unroutable_intents ["off_topic"]

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
  Can a row carrying this classification and this `target_role` reach
  ANYBODY?

  The two-arity boolean form of the fork `IntentDispatcher.dispatch_row/3`
  takes, asked in three steps and NOT as an `or`:

    1. An intent in `unroutable_intents/0` reaches nobody, whatever role
       it names. `off_topic` is the standing case.
    2. Otherwise an intent with a responsibility row here is routable,
       whatever role it names — including the string `"null"`, which is
       a correct answer for an unaddressed ask.
    3. Otherwise it is routable exactly when the classifier named a role
       that exists, because that role's runtime serves it.

  Step 1 is not a special case of step 2. Absence from `@entries` only
  says no RESPONSIBILITY serves the intent; step 3 would then route it
  on the role string, and the prompt makes the model emit one on every
  answer. That is how small talk reached `tasks` (task 01a06575).

  ## Why this is not private to the dispatcher

  Because the dispatcher is not the only thing that has to know. A
  candidate's 30-second countdown (`Platform.Meetings.Candidates`) mints
  a task through `graduate/2` WITHOUT consulting the queue at all — two
  rails, one card. While an unroutable card carried a live countdown,
  the only thing standing between small talk and a `tasks` row was the
  dispatcher closing the row first, which is a race the dispatcher wins
  by a second or two and loses whenever a responsibility handler holds
  the meeting's serial cursor across a slow model call (task 01a06575).

  So "who can this reach" is asked in two places and must have ONE
  answer. The dispatcher keeps its own `cond` because it distinguishes
  `:no_target_role` from `:unknown_role` for the failure REASON it
  records; what it does not keep is a private notion of which role keys
  exist — that is `routable_role?/1` below, and both callers read it.
  """
  @spec routable?(term(), term()) :: boolean()
  def routable?(intent, target_role) do
    cond do
      # Asked FIRST, and it short-circuits both branches below. An
      # `off_topic` naming a real role used to satisfy the role branch of
      # what was a plain `or`, which is door 1 of task 01a06575: the
      # answer that says "this reaches nobody" was routable because of a
      # field the prompt forces the model to fill in anyway.
      unroutable_intent?(intent) -> false
      # The responsibility branch, unchanged: a routable intent keeps its
      # route however the target role came out, including `"null"`.
      not is_nil(responsibility_key(intent)) -> true
      # And the OTHER half of the original `or`, also unchanged: an
      # intent with no responsibility row is still routable when the
      # classifier named a role that exists, because that role's runtime
      # serves it. Closing this branch would take the countdown away from
      # every runtime-served ask.
      true -> routable_role?(target_role)
    end
  end

  @doc """
  Every intent whose correct audience is nobody.

  Distinct from "absent from `entries/0`", which only means no
  responsibility serves it — see `@unroutable_intents` for why the
  difference mints tasks.
  """
  @spec unroutable_intents() :: [String.t()]
  def unroutable_intents, do: @unroutable_intents

  @doc """
  Does this classification reach nobody REGARDLESS of the role it names?

  True for `off_topic` in either spelling. The `target_role` is not a
  parameter on purpose: for these intents it is not consulted, and a
  two-arity form would invite a caller to think it might be.
  """
  @spec unroutable_intent?(term()) :: boolean()
  def unroutable_intent?(intent) when is_binary(intent), do: intent in @unroutable_intents

  def unroutable_intent?(intent) when is_atom(intent) and not is_nil(intent),
    do: Atom.to_string(intent) in @unroutable_intents

  def unroutable_intent?(_), do: false

  @doc """
  Is `role` a role key a dispatch can actually be resolved against?

  False for `nil`, for `Platform.Meetings.IntentClassifier.no_target_role/0`
  (the STRING `"null"` the classifier writes for "this reaches nobody",
  which is not a member of the roster and so needs no special case here),
  and for anything else outside `Platform.Roles.Role.valid_keys/0`.
  """
  @spec routable_role?(term()) :: boolean()
  def routable_role?(role) when is_binary(role), do: role in Role.valid_keys()

  def routable_role?(role) when is_atom(role) and not is_nil(role),
    do: Atom.to_string(role) in Role.valid_keys()

  def routable_role?(_), do: false

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
