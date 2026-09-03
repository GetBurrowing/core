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

  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.IntentRouting
  alias Platform.Responsibilities.Providers.Meetings, as: MeetingsProvider
  alias Platform.Roles.Role
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
      #
      # This used to read `before = :erlang.system_info(:atom_count)` and
      # then `assert :erlang.system_info(:atom_count) == before`. That was
      # the wrong INSTRUMENT, not a flaky subject: `atom_count` is
      # VM-GLOBAL, and this module is `async: true`, so any other test in
      # the same BEAM that interns an atom inside the window fails the
      # assertion no matter what `IntentRouting` does. Measured 2026-08-17
      # under task 01a01037-d1c0-790d-8e0c-df63cfdffe13: one red in 31
      # file-isolated reps, drifting 36075 -> 36077 with no code change.
      # Retrying could not have fixed it, because the value read was never
      # a property of the code under test.
      #
      # So assert the property on the SPECIFIC strings instead. This is
      # exact and concurrency-immune: another test interning some
      # unrelated atom cannot move these four answers. `atom_exists?/1`
      # wraps `String.to_existing_atom/1`, which does NOT intern, so the
      # probe itself is side-effect free (verified: 0 atom_count delta
      # over 50 calls on absent names).
      #
      # "off_topic" IS expected to already exist as an atom — it appears
      # in other tests and in the classifier. Keep it in the list: the
      # snapshot-BEFORE design is exactly what makes a pre-existing atom
      # harmless, and dropping it would weaken the case for no reason.
      junk_strings = ["off_topic", "not_a_real_intent", "", "sudo_rm_rf"]

      existed_before = Map.new(junk_strings, &{&1, atom_exists?(&1)})

      for junk <- junk_strings do
        assert IntentRouting.entry(junk) == nil
        assert IntentRouting.responsibility_key(junk) == nil
        assert IntentRouting.topic(junk) == nil
        assert IntentRouting.event(junk) == nil
      end

      exists_after = Map.new(junk_strings, &{&1, atom_exists?(&1)})

      minted =
        Enum.filter(junk_strings, fn junk ->
          exists_after[junk] and not existed_before[junk]
        end)

      assert exists_after == existed_before,
             "an IntentRouting lookup interned an atom from unrouted model output: " <>
               "#{inspect(minted)} — the atom table is never garbage-collected, so this " <>
               "is an unbounded leak reachable by anyone who can speak in a meeting"
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

  describe "routable?/2 — does this classification reach anybody" do
    test "a routable intent is routable however the target role came out" do
      # The responsibility fork is taken BEFORE the role is looked at
      # (`IntentDispatcher.dispatch_row/3`), so an unaddressed ask — the
      # whole point of stage 3 — is still routable with a null target.
      for %{intent: intent} <- IntentRouting.entries() do
        assert IntentRouting.routable?(intent, nil)
        assert IntentRouting.routable?(intent, "null")
        assert IntentRouting.routable?(intent, "meeting_scribe")
      end
    end

    test "off_topic reaches nobody, in every spelling of the null role" do
      # The classifier writes the STRING "null"
      # (`IntentClassifier.no_target_role/0`); Elixir's `nil` arrives
      # from any other producer and means the same thing. Both are
      # unroutable, and so is a role outside the roster.
      refute IntentRouting.routable?("off_topic", IntentClassifier.no_target_role())
      refute IntentRouting.routable?("off_topic", "null")
      refute IntentRouting.routable?("off_topic", nil)
      refute IntentRouting.routable?("off_topic", "")
      refute IntentRouting.routable?("off_topic", "wizard")
      refute IntentRouting.routable?(:off_topic, nil)
    end

    test "off_topic reaches nobody even when it names a role that DOES exist" do
      # The corner the null-role test above cannot reach, and the only
      # corner that mints. The response schema demands a `target_role`
      # STRING on every answer, and the classifier is a cheap model that
      # does not follow instructions reliably, so
      # `{"intent": "off_topic", "target_role": "meeting_scribe"}` is an
      # ordinary output rather than a contrived one. While `routable?/2`
      # was a plain OR, that answer armed a card, the countdown fired it
      # and small talk landed in `tasks` (task 01a06575).
      #
      # Asserted across the WHOLE roster rather than one role, so an
      # implementation that special-cases a single key does not pass.
      for role <- Role.valid_keys() do
        refute IntentRouting.routable?("off_topic", role),
               "off_topic named the real role #{role} and was still routable"
      end

      # Both spellings the predicate can be asked in.
      refute IntentRouting.routable?(:off_topic, :meeting_scribe)

      # The control that keeps the refutation from being vacuous: the
      # SAME roles route an intent that is not `off_topic`. A predicate
      # hardcoded to `false` fails here.
      for role <- Role.valid_keys() do
        assert IntentRouting.routable?("pull_numbers", role),
               "pull_numbers named the real role #{role} and lost its route"
      end
    end

    test "an intent with no responsibility row is routable only via a real role" do
      # An intent served by a role's RUNTIME rather than by a
      # responsibility is still routable — the countdown must not be
      # taken away from one. This is why the predicate is two-sided and
      # not `responsibility_key/1 != nil`.
      refute IntentRouting.responsibility_key("pull_numbers")
      assert IntentRouting.routable?("pull_numbers", "historian")
      refute IntentRouting.routable?("pull_numbers", "null")
    end

    test "routable_role?/1 is the roster and nothing else" do
      for key <- Role.valid_keys() do
        assert IntentRouting.routable_role?(key)
      end

      # The atom spelling too — `target_role` reaches this predicate as
      # a binary from the classifier and as an atom from an in-process
      # caller. `:historian` is a literal here rather than interned from
      # the roster: `String.to_existing_atom/1` on a key no module has
      # ever written as an atom raises, which would be a test artefact
      # and not a fact about the roster.
      assert IntentRouting.routable_role?(:historian)

      refute IntentRouting.routable_role?(IntentClassifier.no_target_role())
      refute IntentRouting.routable_role?(nil)
      refute IntentRouting.routable_role?("")
      refute IntentRouting.routable_role?(42)
    end
  end

  # Does an atom of this name already exist? `String.to_existing_atom/1`
  # raises rather than interning when it does not, so asking is free of
  # side effects — which is what lets the same helper be used for both
  # the before and after snapshots without the probe creating the very
  # atom it is looking for.
  defp atom_exists?(name) do
    _ = String.to_existing_atom(name)
    true
  rescue
    ArgumentError -> false
  end
end
