defmodule Platform.Meetings.AgentActivitySpeakingDelayedTest do
  @moduledoc """
  The two states CORE can produce honestly — `:speaking` and `:delayed`
  (task `01a07400` stage 2).

  Stage 1 gave the agent two states core cannot see. These are the other
  side, and both are asserted here at the level where the guarantee lives:

    * `:speaking` — that it is SET at dispatch and CLEARED on the ack.
      Both halves, in one test, because a test that only checks it appears
      passes against an implementation that never clears it, and an agent
      pinned as permanently speaking is `:listening` in a new costume.
      The end-to-end version of that pair — through `Meetings.say/4` and
      `record_agent_say_ack/2`, so the CALL SITES are covered and not just
      these two functions — is in `meeting_say_speaking_test.exs`.

    * `:delayed` — that one without a reason is UNREPRESENTABLE, not
      merely discouraged. Three barriers, tested separately so that
      removing any one of them turns a test red rather than quietly
      widening the type.

  `async: false` and no `Application.put_env/3`: the two ETS tables are
  single named tables owned by `AgentActivity.Store`, and every row written
  here is keyed by a fresh generated `meeting_id`, so the tests do not
  collide with each other even though the tables are shared.
  """
  use ExUnit.Case, async: false

  alias Platform.Meetings.AgentActivity
  alias Platform.Meetings.AgentActivity.Delayed
  alias Platform.Meetings.AgentDelayReason

  # A clock far enough out that nothing seeded from a real `utc_now/0`
  # anywhere else can land inside a window these tests measure.
  @t0 ~U[2099-04-01 09:00:00Z]

  setup do
    {:ok,
     meeting_id: Platform.Types.UUIDv7.generate(),
     agent_id: Platform.Types.UUIDv7.generate(),
     other_agent_id: Platform.Types.UUIDv7.generate(),
     utterance_id: Platform.Types.UUIDv7.generate()}
  end

  defp state_of(meeting_id, agent_id, now) do
    case AgentActivity.resolve_at(AgentActivity.new(), meeting_id, now) do
      %{^agent_id => %{state: state}} -> state
      _ -> :idle
    end
  end

  defp entry_of(meeting_id, agent_id, now) do
    AgentActivity.resolve_at(AgentActivity.new(), meeting_id, now)[agent_id]
  end

  # ── `:speaking` ──────────────────────────────────────────────────────────

  describe ":speaking is set at dispatch and cleared on the ack" do
    # THE anti-vacuity test for `:speaking`.
    #
    # Both halves are asserted, by IDENTITY on each side (`== :speaking`,
    # then `== :idle`), and the clear is checked through all three readers
    # so it cannot be hiding in one of them.
    #
    # Named mutation, run: make `clear_speaking/3` a no-op (`def
    # clear_speaking(_, _, _), do: :ok`). The second half of this test goes
    # RED — the agent stays `:speaking` for the life of its ttl — while
    # "the window opens at dispatch" below stays green. The mutant did not
    # survive.
    test "set, then cleared — and the clear is the half that matters",
         %{meeting_id: meeting_id, agent_id: agent_id, utterance_id: utterance_id} do
      {:ok, entry} =
        AgentActivity.mark_speaking(meeting_id, agent_id, utterance_id,
          ttl_ms: 600_000,
          now: @t0
        )

      assert entry.state == :speaking
      assert entry.utterance_id == utterance_id

      # Set.
      assert state_of(meeting_id, agent_id, @t0) == :speaking
      assert %{utterance_id: ^utterance_id} = AgentActivity.speaking(meeting_id, agent_id, @t0)
      assert Map.keys(AgentActivity.speaking_all(meeting_id, @t0)) == [agent_id]

      :ok = AgentActivity.clear_speaking(meeting_id, agent_id, utterance_id)

      # Cleared. The ttl is ten minutes and has not remotely elapsed, so
      # nothing but the ack can be responsible for this.
      assert state_of(meeting_id, agent_id, @t0) == :idle
      refute state_of(meeting_id, agent_id, @t0) == :speaking
      assert AgentActivity.speaking(meeting_id, agent_id, @t0) == nil
      assert AgentActivity.speaking_all(meeting_id, @t0) == %{}
    end

    # The green half of the mutation pair above: if removing the clear also
    # broke this, the red would not be evidence of anything.
    test "the window opens at dispatch, and its age is how long the agent has been talking",
         %{meeting_id: meeting_id, agent_id: agent_id, utterance_id: utterance_id} do
      {:ok, _} =
        AgentActivity.mark_speaking(meeting_id, agent_id, utterance_id,
          ttl_ms: 600_000,
          now: @t0
        )

      # A large, explicit gap — 45 seconds — asserted by identity, not by
      # "positive" or "non-nil". A wrong clock that produced 0, or that
      # stamped `now` at read time, fails this.
      at_45s = DateTime.add(@t0, 45, :second)

      assert %{state: :speaking, entered_at: @t0, age_s: 45} =
               entry_of(meeting_id, agent_id, at_45s)
    end

    test "a clear for a DIFFERENT utterance leaves the window open",
         %{meeting_id: meeting_id, agent_id: agent_id, utterance_id: utterance_id} do
      {:ok, _} =
        AgentActivity.mark_speaking(meeting_id, agent_id, utterance_id,
          ttl_ms: 600_000,
          now: @t0
        )

      :ok =
        AgentActivity.clear_speaking(meeting_id, agent_id, Platform.Types.UUIDv7.generate())

      assert state_of(meeting_id, agent_id, @t0) == :speaking
    end

    # The over-report bias, stated as a scenario rather than as a
    # preference. Two says overlap; the first one's ack arrives while the
    # second is still playing. The agent must stay `:speaking`.
    test "a late ack for the first utterance does not silence the second",
         %{meeting_id: meeting_id, agent_id: agent_id} do
      first = Platform.Types.UUIDv7.generate()
      second = Platform.Types.UUIDv7.generate()

      {:ok, _} =
        AgentActivity.mark_speaking(meeting_id, agent_id, first, ttl_ms: 600_000, now: @t0)

      at_1s = DateTime.add(@t0, 1, :second)

      {:ok, _} =
        AgentActivity.mark_speaking(meeting_id, agent_id, second, ttl_ms: 600_000, now: at_1s)

      # The first utterance finally reports in.
      :ok = AgentActivity.clear_speaking(meeting_id, agent_id, first)

      assert state_of(meeting_id, agent_id, at_1s) == :speaking
      assert %{utterance_id: ^second} = AgentActivity.speaking(meeting_id, agent_id, at_1s)

      # And the second one's own ack does end it.
      :ok = AgentActivity.clear_speaking(meeting_id, agent_id, second)
      assert state_of(meeting_id, agent_id, at_1s) == :idle
    end

    # The backstop for an ack that never arrives — a runtime killed
    # mid-playout. Small explicit ttl, wide margins on both sides: live at
    # one fifth of it, lapsed at twelve times it.
    test "an ack that never arrives lapses on the ttl",
         %{meeting_id: meeting_id, agent_id: agent_id, utterance_id: utterance_id} do
      {:ok, entry} =
        AgentActivity.mark_speaking(meeting_id, agent_id, utterance_id, ttl_ms: 5_000, now: @t0)

      assert entry.ttl_ms == 5_000

      assert state_of(meeting_id, agent_id, DateTime.add(@t0, 1, :second)) == :speaking

      at_60s = DateTime.add(@t0, 60, :second)
      assert state_of(meeting_id, agent_id, at_60s) == :idle
      assert AgentActivity.speaking(meeting_id, agent_id, at_60s) == nil
      assert AgentActivity.speaking_all(meeting_id, at_60s) == %{}
    end

    test "the sweep deletes lapsed rows and leaves live ones",
         %{meeting_id: meeting_id, agent_id: agent_id, other_agent_id: other_agent_id} do
      {:ok, _} =
        AgentActivity.mark_speaking(meeting_id, agent_id, Platform.Types.UUIDv7.generate(),
          ttl_ms: 5_000,
          now: @t0
        )

      {:ok, _} =
        AgentActivity.mark_speaking(meeting_id, other_agent_id, Platform.Types.UUIDv7.generate(),
          ttl_ms: 600_000,
          now: @t0
        )

      at_60s = DateTime.add(@t0, 60, :second)
      assert AgentActivity.sweep_speaking(at_60s) >= 1

      assert :ets.lookup(AgentActivity.speaking_table(), {meeting_id, agent_id}) == []
      assert [_row] = :ets.lookup(AgentActivity.speaking_table(), {meeting_id, other_agent_id})

      AgentActivity.clear_speaking(
        meeting_id,
        other_agent_id,
        AgentActivity.speaking(meeting_id, other_agent_id, at_60s).utterance_id
      )
    end
  end

  describe "the :speaking ttl is derived from the utterance, not configured" do
    # Magnitude, not sign. A rate that had been dropped or zeroed would
    # still give a "positive" ttl and still be "non-nil"; what it would not
    # give is a ttl that grows by more than a minute across two thousand
    # characters.
    test "a long utterance gets a much longer window than a short one" do
      short = AgentActivity.speaking_ttl_ms(5)
      long = AgentActivity.speaking_ttl_ms(2_000)

      assert long - short >= 60_000
      assert long > short * 5

      # The floor is a real floor: even an empty utterance gets seconds,
      # not milliseconds.
      assert AgentActivity.speaking_ttl_ms(0) >= 1_000
    end

    test "a dispatch with no explicit ttl takes the derived one",
         %{meeting_id: meeting_id, agent_id: agent_id, utterance_id: utterance_id} do
      {:ok, entry} =
        AgentActivity.mark_speaking(meeting_id, agent_id, utterance_id,
          char_count: 500,
          now: @t0
        )

      assert entry.ttl_ms == AgentActivity.speaking_ttl_ms(500)
      assert entry.ttl_ms > AgentActivity.speaking_ttl_ms(0)

      AgentActivity.clear_speaking(meeting_id, agent_id, utterance_id)
    end
  end

  describe ":speaking in the resolution order" do
    test "outranks :failed, so an agent that is audibly talking is not captioned 'Couldn't'",
         %{meeting_id: meeting_id, agent_id: agent_id, utterance_id: utterance_id} do
      failed =
        AgentActivity.put_at(AgentActivity.new(), :failed, agent_id, true, @t0)

      assert %{^agent_id => %{state: :failed}} =
               AgentActivity.resolve_at(failed, meeting_id, @t0)

      {:ok, _} =
        AgentActivity.mark_speaking(meeting_id, agent_id, utterance_id,
          ttl_ms: 600_000,
          now: @t0
        )

      assert %{^agent_id => %{state: :speaking}} =
               AgentActivity.resolve_at(failed, meeting_id, @t0)

      # And it is bounded: the failure is not painted over indefinitely.
      :ok = AgentActivity.clear_speaking(meeting_id, agent_id, utterance_id)

      assert %{^agent_id => %{state: :failed}} =
               AgentActivity.resolve_at(failed, meeting_id, @t0)
    end

    test "outranks a pushed :thinking and a :typing signal",
         %{meeting_id: meeting_id, agent_id: agent_id, utterance_id: utterance_id} do
      typing = AgentActivity.put_at(AgentActivity.new(), :typing, agent_id, true, @t0)
      {:ok, _} = AgentActivity.push(meeting_id, agent_id, :thinking, ttl_ms: 600_000, now: @t0)

      assert %{^agent_id => %{state: :typing}} = AgentActivity.resolve_at(typing, meeting_id, @t0)

      {:ok, _} =
        AgentActivity.mark_speaking(meeting_id, agent_id, utterance_id,
          ttl_ms: 600_000,
          now: @t0
        )

      assert %{^agent_id => %{state: :speaking}} =
               AgentActivity.resolve_at(typing, meeting_id, @t0)

      AgentActivity.clear_speaking(meeting_id, agent_id, utterance_id)
      AgentActivity.clear_pushed(meeting_id, agent_id)
    end

    # A human talking over an agent delivers a transcript segment to that
    # agent's runtime, which stamps `:heard`. If the receipt won, the
    # speaking indicator would vanish for two seconds at the exact moment
    # two people are already talking at once.
    test "a live :heard does NOT hide a live :speaking",
         %{meeting_id: meeting_id, agent_id: agent_id, utterance_id: utterance_id} do
      heard = AgentActivity.put_at(AgentActivity.new(), :heard, agent_id, true, @t0)

      assert %{^agent_id => %{state: :heard}} = AgentActivity.resolve_at(heard, meeting_id, @t0)

      {:ok, _} =
        AgentActivity.mark_speaking(meeting_id, agent_id, utterance_id,
          ttl_ms: 600_000,
          now: @t0
        )

      assert %{^agent_id => %{state: :speaking}} =
               AgentActivity.resolve_at(heard, meeting_id, @t0)

      AgentActivity.clear_speaking(meeting_id, agent_id, utterance_id)
    end

    # The decay `agent_activity_test.exs` pins is untouched by this stage:
    # with no `:speaking` in play, `:heard` still overlays and still decays
    # on exactly the same schedule.
    test "with nothing speaking, :heard still overlays and still decays in two seconds",
         %{meeting_id: meeting_id, agent_id: agent_id} do
      heard =
        AgentActivity.new()
        |> AgentActivity.put_at(:computing, agent_id, true, @t0)
        |> AgentActivity.put_at(:heard, agent_id, true, @t0)

      assert %{^agent_id => %{state: :heard}} = AgentActivity.resolve_at(heard, meeting_id, @t0)

      at_decay = DateTime.add(@t0, AgentActivity.heard_decay_seconds(), :second)

      assert %{^agent_id => %{state: :computing}} =
               AgentActivity.resolve_at(heard, meeting_id, at_decay)
    end

    test "the store-blind readers never surface :speaking",
         %{meeting_id: meeting_id, agent_id: agent_id, utterance_id: utterance_id} do
      {:ok, _} =
        AgentActivity.mark_speaking(meeting_id, agent_id, utterance_id,
          ttl_ms: 600_000,
          now: @t0
        )

      # Neither takes a `now`, so neither can age anything out.
      assert AgentActivity.resolve(AgentActivity.new()) == %{}
      assert AgentActivity.for_agent(AgentActivity.new(), agent_id) == :idle
      assert AgentActivity.resolve_at(AgentActivity.new(), @t0) == %{}

      AgentActivity.clear_speaking(meeting_id, agent_id, utterance_id)
    end

    test "speaking_all/2 is meeting-scoped", %{agent_id: agent_id, utterance_id: utterance_id} do
      one = Platform.Types.UUIDv7.generate()
      two = Platform.Types.UUIDv7.generate()

      {:ok, _} =
        AgentActivity.mark_speaking(one, agent_id, utterance_id, ttl_ms: 600_000, now: @t0)

      assert Map.keys(AgentActivity.speaking_all(one, @t0)) == [agent_id]
      assert AgentActivity.speaking_all(two, @t0) == %{}
      assert AgentActivity.speaking(two, agent_id, @t0) == nil

      AgentActivity.clear_speaking(one, agent_id, utterance_id)
    end
  end

  describe "the second table has the same owner as the first" do
    test "AgentActivity.Store owns both, and AgentActivity is still not a process" do
      refute function_exported?(AgentActivity, :init, 1)
      refute function_exported?(AgentActivity, :handle_info, 2)

      assert is_pid(Process.whereis(AgentActivity.Store))
      assert :ets.info(AgentActivity.pushed_table()) != :undefined
      assert :ets.info(AgentActivity.speaking_table()) != :undefined

      # Two tables, not one shared key space — an agent can be mid-
      # `:composing` by its own declaration and `:speaking` by core's
      # observation at the same instant.
      assert length(Enum.uniq([AgentActivity.pushed_table(), AgentActivity.speaking_table()])) ==
               2
    end
  end

  # ── `:delayed` ───────────────────────────────────────────────────────────

  describe "a :delayed without a reason is unrepresentable" do
    # BARRIER 1 — `@enforce_keys [:reason]`.
    #
    # Named mutation: remove `:reason` from `@enforce_keys` in `Delayed`.
    # This test goes RED (`struct!/2` stops raising) while every other
    # `:delayed` test here stays green, which is what makes it a test of
    # this barrier specifically and not of the feature in general.
    test "the struct cannot be built without one" do
      assert_raise ArgumentError, fn -> struct!(Delayed, %{}) end

      assert %Delayed{reason: "waiting for a human to speak"} =
               Delayed.new!("waiting for a human to speak")
    end

    # BARRIER 2 — the constructor.
    #
    # Named mutation: relax `new/1` to accept a nil or blank reason (that
    # is exactly "make the reason optional"). Every assertion in this test
    # goes RED.
    test "the constructor refuses nil, non-binaries, and blank strings" do
      for reason <- [nil, "", "   ", "\n\t ", :delayed, 42, %{}] do
        assert Delayed.new(reason) == {:error, :reason_required},
               "expected #{inspect(reason)} to be refused as a delay reason"
      end

      assert_raise ArgumentError, fn -> Delayed.new!(nil) end
      assert_raise ArgumentError, fn -> Delayed.new!("  ") end

      # The positive control, so the refusals above are not simply "new/1
      # refuses everything".
      assert {:ok, %Delayed{reason: "agent went offline"}} = Delayed.new("agent went offline")
      assert {:ok, %Delayed{reason: "trimmed"}} = Delayed.new("  trimmed  ")
    end

    test "a reason longer than the cap is truncated, not refused" do
      long = String.duplicate("x", Delayed.reason_max_chars() * 3)
      {:ok, delayed} = Delayed.new(long)

      assert String.length(delayed.reason) == Delayed.reason_max_chars()
      assert Delayed.valid?(delayed)
    end

    # BARRIER 3 — re-checked at the point of use.
    #
    # `struct/2` (non-bang) bypasses `@enforce_keys` and produces
    # `%Delayed{reason: nil}`. Without `Delayed.valid?/1` in
    # `apply_delays/2` that value reaches the screen as a spinner that says
    # nothing — the exact opacity this state exists to remove.
    #
    # Named mutation: delete the `Delayed.valid?(delayed)` conjunct from
    # `apply_delays/2`. This test goes RED.
    test "a forced reason-less struct is dropped at the point of use, and so is a bare atom",
         %{agent_id: agent_id} do
      resolved = %{agent_id => %{state: :computing, entered_at: @t0, age_s: 30}}

      for bogus <- [struct(Delayed, %{}), :delayed, "delayed", nil, %{reason: "sneaky"}] do
        assert %{^agent_id => entry} = AgentActivity.apply_delays(resolved, %{agent_id => bogus})

        assert entry.state == :computing,
               "expected #{inspect(bogus)} not to produce a :delayed"

        refute Map.has_key?(entry, :reason)
      end
    end

    # The other half of "unrepresentable": there is no route from facts to
    # a `:delayed` when there is nothing specific to say. Not a `:delayed`
    # with an empty reason, not a `:delayed` with a placeholder — no key at
    # all.
    test "an agent that is merely slow gets no :delayed, at any age", %{agent_id: agent_id} do
      # 600 seconds is sixty times `default_shows_after_s/0`. The default
      # clause fires for `for_agent/1` at this age and still must not
      # promote the agent to a state.
      facts = %{age_s: 600}

      assert AgentDelayReason.for_agent(facts) == AgentDelayReason.default_clause()
      assert AgentDelayReason.specific_for_agent(facts) == nil
      assert Delayed.from_facts(facts) == :none
      assert AgentActivity.delays_from_facts(%{agent_id => facts}) == %{}

      resolved = %{agent_id => %{state: :computing, entered_at: @t0, age_s: 600}}

      assert AgentActivity.apply_delays(
               resolved,
               AgentActivity.delays_from_facts(%{agent_id => facts})
             ) == resolved
    end
  end

  describe ":delayed carries its reason onto the resolved state" do
    test "a specific cause becomes :delayed, with the reason and the working state's clock",
         %{agent_id: agent_id} do
      facts = %{reply_budget_exhausted?: true, reply_budget_reset_in_s: 12, age_s: 3}

      assert {:ok, %Delayed{reason: reason}} = Delayed.from_facts(facts)
      assert reason == "reply budget resets in 12s"

      resolved = %{agent_id => %{state: :computing, entered_at: @t0, age_s: 3}}
      delays = AgentActivity.delays_from_facts(%{agent_id => facts})

      assert %{^agent_id => entry} = AgentActivity.apply_delays(resolved, delays)
      assert entry.state == :delayed
      assert entry.reason == "reply budget resets in 12s"

      # The delay explains the work; it does not restart its clock.
      assert entry.entered_at == @t0
      assert entry.age_s == 3
    end

    # NARROWED in stage 3: `no_voice_worker?` was in this list and is not
    # any more. `apply_delays/2` only qualifies `delayable_states/0`, which
    # excludes `:speaking`, so that clause could only ever have fired on an
    # agent that was NOT speaking — and a missing voice worker does not
    # hold up thinking or composing. It has no true configuration as a
    # state, so it goes back to being the trailing note it already was.
    # `no_voice_worker_is_a_note_not_a_state_test.exs` is where that is
    # pinned end to end.
    test "every promotable cause is reachable and they are different sentences",
         %{agent_id: agent_id} do
      causes = [
        %{reply_budget_exhausted?: true, reply_budget_reset_in_s: 7},
        %{agent_chain_too_deep?: true},
        %{runtime_offline?: true}
      ]

      reasons =
        for facts <- causes do
          assert {:ok, %Delayed{reason: reason}} = Delayed.from_facts(facts)
          assert reason != AgentDelayReason.default_clause()

          resolved = %{agent_id => %{state: :thinking, entered_at: @t0, age_s: 1}}
          delays = AgentActivity.delays_from_facts(%{agent_id => facts})

          assert %{^agent_id => %{state: :delayed, reason: ^reason}} =
                   AgentActivity.apply_delays(resolved, delays)

          reason
        end

      assert length(Enum.uniq(reasons)) == length(causes)
    end

    test "it qualifies only the WORKING states", %{agent_id: agent_id} do
      facts = %{runtime_offline?: true}
      delays = AgentActivity.delays_from_facts(%{agent_id => facts})
      assert map_size(delays) == 1

      for state <- AgentActivity.delayable_states() do
        resolved = %{agent_id => %{state: state, entered_at: @t0, age_s: 1}}

        assert %{^agent_id => %{state: :delayed, reason: "agent went offline"}} =
                 AgentActivity.apply_delays(resolved, delays)
      end

      # `:idle` is not blocked, it is idle. `:failed` already said something
      # went wrong. `:heard` is a two-second receipt. `:speaking` is audio
      # going out right now, which cannot simultaneously be stuck.
      for state <- [:idle, :failed, :heard, :speaking, :listening] do
        refute state in AgentActivity.delayable_states()
        resolved = %{agent_id => %{state: state, entered_at: @t0, age_s: 1}}

        assert AgentActivity.apply_delays(resolved, delays) == resolved
      end
    end

    test "an agent absent from the resolved map gains nothing",
         %{agent_id: agent_id, other_agent_id: other_agent_id} do
      delays = AgentActivity.delays_from_facts(%{other_agent_id => %{runtime_offline?: true}})
      resolved = %{agent_id => %{state: :computing, entered_at: @t0, age_s: 1}}

      assert AgentActivity.apply_delays(resolved, delays) == resolved
    end
  end

  # ── The states this stage did and did not add ────────────────────────────

  describe "the state vocabulary" do
    test ":speaking and :delayed are states, but neither is a signal or pushable" do
      for state <- [:speaking, :delayed] do
        assert state in AgentActivity.states()
        refute state in AgentActivity.signals()
        refute state in AgentActivity.pushed_states()
      end
    end

    # A runtime that could assert `:speaking` could claim the room's
    # attention without core having sent any audio, and one that could
    # assert `:delayed` could excuse itself for a cause core never
    # observed. Both are core's, and `push/4` refuses them.
    test "a federated runtime cannot push either of them",
         %{meeting_id: meeting_id, agent_id: agent_id} do
      for state <- [:speaking, :delayed] do
        assert AgentActivity.push(meeting_id, agent_id, state, now: @t0) ==
                 {:error, {:unsupported_state, state}}
      end

      assert AgentActivity.speaking(meeting_id, agent_id, @t0) == nil
      assert AgentActivity.pushed(meeting_id, agent_id, @t0) == nil
    end

    # `:listening` is untouched by this stage and must stay that way. It is
    # deliberately unreachable (canvas `01a05b11-54ff`, ratified by Harper
    # 2026-09-03); restoring it would rebuild the always-on badge that
    # decision removed. `:speaking` and `:delayed` are not a route back in.
    test ":listening gained no producer here", %{meeting_id: meeting_id, agent_id: agent_id} do
      assert :listening in AgentActivity.states()
      refute :listening in AgentActivity.signals()
      refute :listening in AgentActivity.pushed_states()
      refute :listening in AgentActivity.delayable_states()

      assert AgentActivity.push(meeting_id, agent_id, :listening, now: @t0) ==
               {:error, {:unsupported_state, :listening}}

      # Nothing in this stage's readers can produce it either.
      states =
        AgentActivity.new()
        |> AgentActivity.resolve_at(meeting_id, @t0)
        |> AgentActivity.apply_delays(%{agent_id => Delayed.new!("agent went offline")})
        |> Map.values()
        |> Enum.map(& &1.state)

      refute :listening in states
    end
  end
end
