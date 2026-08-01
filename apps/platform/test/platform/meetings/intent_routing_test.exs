defmodule Platform.Meetings.IntentRoutingTest do
  @moduledoc """
  The guard that makes a half-wired intent impossible.

  Three facts about a mid-meeting intent responsibility used to live in
  three files: the responsibility key in `IntentDispatcher`, the topic
  string and event atom in `Meetings.PubSub`, and both of those again in
  the handler's `register/0`. `IntentRouting` collapsed them into one
  row; this file asserts every consumer still agrees with that row.

  The failure this exists to catch is silent in the worst way. The
  Responsibilities Router subscribes at boot to the topic strings its
  ENABLED ROWS declare. A handler declaring one topic while the
  dispatcher broadcasts on another produces no error and no log — the
  intent is marked `:dispatched`, the meeting's serial cursor is held,
  and the row times out 90 seconds later against a listener that was
  never there. Nothing goes red; the meeting just gets slower.
  """
  use Platform.DataCase, async: true

  alias Platform.Meetings.IntentRouting
  alias Platform.Responsibilities.Providers.Meetings, as: MeetingsProvider
  alias Platform.Roles.Seeds

  describe "the routing table is internally consistent" do
    test "every row has a distinct intent, key, topic and event" do
      entries = IntentRouting.entries()

      for field <- [:intent, :key, :topic, :event] do
        values = Enum.map(entries, &Map.fetch!(&1, field))

        assert length(Enum.uniq(values)) == length(values),
               "duplicate #{field} in IntentRouting.entries/0: #{inspect(values -- Enum.uniq(values))}"
      end
    end

    test "the table is not empty" do
      # Control against every assertion in this file passing vacuously
      # over an empty list — the exact shape that makes a coverage guard
      # green while covering nothing.
      assert length(IntentRouting.entries()) >= 6
    end

    test "lookup by intent, by key, and the accessors all agree" do
      for %{intent: intent, key: key, topic: topic, event: event} = entry <-
            IntentRouting.entries() do
        assert IntentRouting.entry(intent) == entry
        assert IntentRouting.entry_for_key(key) == entry
        assert IntentRouting.responsibility_key(intent) == key
        assert IntentRouting.topic(intent) == topic
        assert IntentRouting.event(intent) == event
      end
    end

    test "an unrouted intent answers nil rather than minting an atom" do
      # `classified_intent` is whatever a small local model emitted. The
      # atom table is not garbage-collected, so a lookup that built atoms
      # from model output would be an unbounded leak reachable by anyone
      # who can speak in a meeting.
      before = :erlang.system_info(:atom_count)

      for junk <- ["off_topic", "not_a_real_intent", "", "sudo_rm_rf"] do
        assert IntentRouting.entry(junk) == nil
        assert IntentRouting.responsibility_key(junk) == nil
        assert IntentRouting.topic(junk) == nil
        assert IntentRouting.event(junk) == nil
      end

      assert :erlang.system_info(:atom_count) == before
    end

    test "off_topic is deliberately absent" do
      # The one intent that should reach nobody. The classifier emits it
      # with `target_role: null` and the dispatcher lands the row
      # `:dispatch_failed`/`:no_target_role`, which is correct for small
      # talk. A routing row for it would wake an agent for every joke.
      assert IntentRouting.entry("off_topic") == nil
    end
  end

  describe "every routing row is wired end to end" do
    test "the handler's register/0 declares the row's topic and event_match" do
      for %{key: key, topic: topic, event: event} <- IntentRouting.entries() do
        handler = MeetingsProvider.handler_for(key)

        assert handler != nil,
               "IntentRouting has a row for #{key} but Providers.Meetings.handler_for/1 " <>
                 "returns nil — the fork will find a key with no handler behind it"

        spec = Enum.find(handler.register(), &(&1.key == key))

        assert spec != nil,
               "#{inspect(handler)}.register/0 declares no row for #{key}"

        assert spec.trigger_config["topic"] == topic,
               "#{key} subscribes to #{inspect(spec.trigger_config["topic"])} but the " <>
                 "dispatcher broadcasts on #{inspect(topic)} — dispatches would reach nobody"

        assert spec.trigger_config["event_match"] == Atom.to_string(event),
               "#{key} matches event #{inspect(spec.trigger_config["event_match"])} but the " <>
                 "dispatcher publishes #{inspect(event)}"
      end
    end

    test "every routing row's key is in the SEEDED bundle of the role it names" do
      # Against the DATABASE, not `Seeds.default_roles/0`. This
      # distinction is the whole reason this test exists in this shape.
      #
      # The code-list version of this assertion was green while
      # production had no bundle rows at all for these keys, because
      # `Roles.Seeds.seed_defaults/0` runs from a migration and Ecto
      # invokes each migration exactly once per version — so a bundle
      # key added to `@default_roles` afterwards never reaches an
      # already-migrated database. Found on prod after deploying, with
      # every other check green: responsibility rows present and
      # enabled, Router subscribed to all five topics, prompt rows
      # correct, and `assignee_for/1` still nil for all five.
      #
      # That is the quiet failure. The dispatcher forks, the Router
      # receives the broadcast, resolves nobody, and answers
      # `{:ok, :unfilled}` — which reads like success. Nothing stalls,
      # nothing errors, the feature is simply inert.
      for %{key: key, role: role} <- IntentRouting.entries() do
        seeded = Platform.Roles.bundle_for(role)

        assert key in seeded,
               "#{key} routes to #{role} but no role_responsibilities row pairs them. " <>
                 "Adding the key to Roles.Seeds.@default_roles is not enough on an " <>
                 "already-migrated database — it needs a migration that re-runs " <>
                 "seed_defaults/0 (see 20260801022000_seed_meeting_intent_role_bundles)."
      end
    end

    test "every routing row's key is in the declared bundle of the role it names" do
      bundles =
        Map.new(Seeds.default_roles(), fn role -> {role.key, role.bundle} end)

      for %{key: key, role: role} <- IntentRouting.entries() do
        bundle = Map.get(bundles, role)

        assert bundle != nil, "IntentRouting names role #{inspect(role)}, which is not a role"

        assert key in bundle,
               "#{key} routes to the #{role} role but is not in that role's bundle — " <>
                 "`Roles.assignee_for/1` would resolve nobody and the intent would fail " <>
                 "`:no_assignee` every time"
      end
    end

    test "every routing row's handler is registered in BuiltIns" do
      # A handler absent from `BuiltIns.providers/0` never gets its row
      # upserted at boot, so the Router has nothing to subscribe with and
      # the topic is dead even though every other file agrees on it.
      registered =
        Platform.Responsibilities.BuiltIns.providers()
        |> Enum.flat_map(& &1.register())
        |> MapSet.new(& &1.key)

      for %{key: key} <- IntentRouting.entries() do
        assert MapSet.member?(registered, key),
               "#{key} is not registered by any module in BuiltIns.providers/0"
      end
    end
  end

  describe "the action_items row is byte-preserved" do
    test "topic and event keep their pre-existing singular spelling" do
      # `action_items` (plural intent) maps to `:action_item_intent`
      # (singular event). That asymmetry shipped in 019fb90f-36e3 and is
      # bound end-to-end by `event_topic_delivery_test.exs`. Normalising
      # it while generalising the table would have silently unfired the
      # responsibility — this pins it so the tidy-up cannot happen by
      # accident.
      assert IntentRouting.topic("action_items") == "meeting:action_item_intent"
      assert IntentRouting.event("action_items") == :action_item_intent
      assert IntentRouting.responsibility_key("action_items") == "meetings.action_items"
    end
  end
end
