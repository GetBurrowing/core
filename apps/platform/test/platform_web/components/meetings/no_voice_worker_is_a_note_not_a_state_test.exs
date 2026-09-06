defmodule PlatformWeb.Components.Meetings.NoVoiceWorkerIsANoteNotAStateTest do
  @moduledoc """
  A missing voice worker is a NOTE, never the state word (task `01a07400`
  stage 3, behavioural-gate remedy).

  ## The defect this pins

  An agent that was demonstrably working rendered as
  `Delayed · no voice worker in this room`. Stage 2 put `no_voice_worker?`
  into `AgentDelayReason.specific_for_agent/1` — the PROMOTION set — so
  `Delayed.from_facts/1` turned it into a state, `apply_delays/2` overwrote
  the working state with `:delayed`, and the row lost the working colour,
  lost `animate-pulse` (so `:composing` stopped being distinguishable from
  `:thinking`), and grew a second block line.

  ## Why the promotion was unconditionally wrong, not merely too eager

  `apply_delays/2` only qualifies a state in
  `AgentActivity.delayable_states/0`, and that list is
  `[:computing, :typing, :thinking, :composing]` — **`:speaking` is not in
  it**, deliberately, because audio going out right now is the one state
  that cannot simultaneously be stuck.

  So a `no_voice_worker?` promotion could only ever fire on an agent that
  is NOT speaking. And a missing voice worker does not hold up thinking,
  composing, computing or typing. There is therefore no configuration in
  which "Delayed · no voice worker in this room" is the true reading —
  which is why the remedy is REMOVAL from the promotion set rather than an
  age threshold. A threshold would only make a false statement arrive
  later. `delayable_states_excludes_speaking/0` below pins the premise of
  that argument, so the argument fails loudly if the list ever changes.

  ## The configuration under test is the one that was measured

  Not "an agent with no runtime", which is a different branch and would
  test nothing about this fix: `Meetings.runtime_offline?/1` is ALSO true
  there, so such a row promotes to `:delayed` through a clause this change
  does not touch and would stay `Delayed` either way.

  The measured failing case, and the one seeded here, is an ordinary
  deployment whose voice worker has dropped:

    * a CONNECTED brain runtime (`agent.runtime_id`, tracked in
      `RuntimePresence`) — so `runtime_offline?/1` is false, and
    * a registered voice-capable runtime that is OFFLINE — so
      `resolve_voice_target/1` finds a `:capable` row, finds none online,
      returns `{:error, :voice_runtime_offline}` (it never reaches its
      legacy fallback, which only runs when NO row declares the feature),
      and `VoiceSeatCache.seated?/1` is false.

  The voice row's `meeting_voice` feature is declared EXPLICITLY via
  `Federation.update_metadata/2`. `register_voice_runtime/3` alone writes
  only `"role" => "voice"`, which `capability_from_metadata/1` reads as
  `:unknown`, not `:capable` — a fixture that skipped the declaration
  would fall through to the legacy fallback and seat the brain, i.e. it
  would not reproduce the bug at all.

  `async: false` — `RuntimePresence` is one named process and
  `VoiceSeatCache` owns one named ETS table, both shared process-wide.
  """
  use PlatformWeb.ChannelCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.Meetings
  alias Platform.Meetings.AgentActivity
  alias Platform.Meetings.AgentActivity.Delayed
  alias Platform.Meetings.AgentDelayReason
  alias Platform.Meetings.VoiceSeatCache
  alias Platform.Repo
  alias PlatformWeb.Components.Meetings.ParticipantRail

  @voice_seat_table :meeting_voice_seat_cache

  # ── Fixtures ──────────────────────────────────────────────────────────

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "no-voice-worker-#{n}@example.com",
      name: "No Voice Worker #{n}",
      oidc_sub: "oidc-no-voice-worker-#{n}"
    })
  end

  defp agent! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "no-voice-worker-agent-#{n}",
      name: "Vox",
      status: "active"
    })
  end

  # The brain, CONNECTED. `link_agent/2` is what makes it the brain: it
  # sets `agent.runtime_id`, which is the only row
  # `Federation.get_runtime_for_agent/1` — and therefore
  # `Meetings.runtime_offline?/1` — ever looks at.
  defp connected_brain!(owner, agent) do
    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: "brain-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)

    RuntimePresence.track(activated.runtime_id)
    on_exit(fn -> RuntimePresence.untrack(activated.runtime_id) end)

    agent
  end

  # A voice-capable row that is registered and NOT connected. The feature
  # declaration is the load-bearing half — see the moduledoc.
  defp offline_voice_runtime!(owner, agent) do
    {:ok, runtime, _raw_token} = Federation.register_voice_runtime(owner.id, agent)

    {:ok, declared} =
      Federation.update_metadata(runtime, %{
        "client_info" => %{
          "product" => "openclaw",
          "version" => "0.1.0",
          "features" => [Meetings.voice_feature()]
        }
      })

    # Nothing is tracked in `RuntimePresence` for it — that absence IS the
    # offline half of the configuration.
    declared
  end

  # The exact failing configuration, asserted to actually BE that
  # configuration before anything is rendered against it. Without these
  # three checks a fixture that silently drifted (a brain that never came
  # online, a voice row that never declared the feature) would still
  # produce a green test, against a case nobody meant to test.
  defp failing_config! do
    owner = user!()
    agent = agent!()
    agent = connected_brain!(owner, agent)
    _voice = offline_voice_runtime!(owner, agent)

    :ets.delete(@voice_seat_table, agent.id)

    refute Meetings.runtime_offline?(agent),
           "the brain must be CONNECTED, or :delayed arrives through the runtime_offline? clause instead"

    assert Meetings.resolve_voice_target(agent) == {:error, :voice_runtime_offline},
           "the voice row must be capable-but-offline, not absent (which takes the legacy fallback)"

    refute VoiceSeatCache.seated?(agent),
           "seated?/1 is what delay_facts/3 reads; if it is true the case under test is not seeded"

    agent
  end

  defp participant(agent) do
    %{
      id: "p-" <> agent.id,
      participant_id: agent.id,
      participant_type: "agent",
      display_name: agent.name,
      avatar_url: nil,
      attention_config: %{}
    }
  end

  # Renders the REAL component against the REAL facts: `agents_by_id`
  # carries the persisted `%Agent{}`, so `delay_facts/3` performs its
  # actual `VoiceSeatCache.seated?/1` and `runtime_offline?/1` reads rather
  # than being handed a `delays:` map. No `delays:` override is passed
  # anywhere in this file — that is the point.
  defp rail(agent, meeting_id, now) do
    render_component(&ParticipantRail.participant_rail/1,
      participants: [participant(agent)],
      agents_by_id: %{agent.id => agent},
      meeting: %{id: meeting_id, host_participant_id: "u-1"},
      agent_activity: AgentActivity.new(),
      now: now
    )
  end

  defp meeting_id, do: "m-no-voice-#{System.unique_integer([:positive])}"

  # ── Reading the row ───────────────────────────────────────────────────
  #
  # `LazyHTML.query/2` throughout, never `filter/2`: filter matches only a
  # fragment's ROOT nodes, so every nested node below would come back `[]`
  # and read as "not there" — an absence assertion that can never fail.

  defp frag(html), do: LazyHTML.from_fragment(html)

  defp text_at(html, selector) do
    html
    |> frag()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end

  defp primary_word(html), do: text_at(html, ~s([data-role="agent-activity-primary"]))
  defp trailing_note(html), do: text_at(html, ~s([data-role="agent-activity-reason"]))
  defp sr_label(html), do: text_at(html, ~s([data-role="agent-activity-avatar"] .sr-only))

  defp nodes(html, selector), do: html |> frag() |> LazyHTML.query(selector) |> Enum.to_list()

  defp ring_class(html) do
    html
    |> frag()
    |> LazyHTML.query(~s([data-role="agent-activity-ring"]))
    |> LazyHTML.attribute("class")
    |> List.first()
  end

  defp activity_state(html) do
    html
    |> frag()
    |> LazyHTML.query(~s([data-role="agent-activity-avatar"]))
    |> LazyHTML.attribute("data-activity-state")
    |> List.first()
  end

  defp glyph(html), do: text_at(html, ~s([data-role="agent-activity-glyph"]))

  # The BLOCK lines of the row's text column — the three `<div>`s that can
  # occupy a line of their own. The trailing note is deliberately NOT
  # counted: it is an inline `<span>` inside the word row, which is why it
  # can be present without changing the row's line count.
  @block_line_roles ~s([data-role="participant-name"], ) <>
                      ~s([data-role="agent-activity-word"], ) <>
                      ~s([data-role="agent-activity-delay-reason"])

  defp block_line_count(html), do: length(nodes(html, @block_line_roles))

  # ── The premise of the argument ───────────────────────────────────────

  test ":speaking is not delayable, which is why the promotion had no true case" do
    refute :speaking in AgentActivity.delayable_states(),
           "if :speaking ever becomes delayable, re-examine whether a missing " <>
             "voice worker can legitimately be a STATE rather than a note"

    assert AgentActivity.delayable_states() == [:computing, :typing, :thinking, :composing]
  end

  # ── The fix, against the exact failing configuration ──────────────────

  describe "an agent working with a registered-but-offline voice worker" do
    test ":composing renders Writing, keeps its ring and pulse, and does not grow a line" do
      agent = failing_config!()
      mid = meeting_id()
      t0 = ~U[2026-01-01 00:00:00Z]

      {:ok, _entry} = AgentActivity.push(mid, agent.id, :composing, now: t0)

      html = rail(agent, mid, DateTime.add(t0, 5, :second))

      # The word is the working one, with its age in the same slot.
      assert primary_word(html) == "Writing · 5s"
      refute primary_word(html) =~ "Delayed"
      assert activity_state(html) == "composing"
      assert glyph(html) == "✎"

      # The working colour, and the pulse that is the ONLY thing
      # distinguishing :composing from :thinking on this row.
      assert ring_class(html) =~ "border-info"
      assert ring_class(html) =~ "text-info"

      assert ring_class(html) =~ "animate-pulse",
             ":composing without animate-pulse is indistinguishable from :thinking"

      refute ring_class(html) =~ "border-base-content/25"

      # The row does not change height: no second block line.
      assert block_line_count(html) == 2
      assert nodes(html, ~s([data-role="agent-activity-delay-reason"])) == []

      # And the accessible sentence says what the agent is doing.
      assert sr_label(html) == "Vox is Writing"
    end

    test ":thinking renders Thinking with the static ring, not Delayed" do
      agent = failing_config!()
      mid = meeting_id()
      t0 = ~U[2026-01-01 00:00:00Z]

      {:ok, _entry} = AgentActivity.push(mid, agent.id, :thinking, now: t0)

      html = rail(agent, mid, DateTime.add(t0, 3, :second))

      assert primary_word(html) == "Thinking · 3s"
      assert activity_state(html) == "thinking"
      assert glyph(html) == "◐"
      assert ring_class(html) =~ "border-info"
      refute ring_class(html) =~ "animate-pulse"
      assert block_line_count(html) == 2
      assert sr_label(html) == "Vox is Thinking"
    end

    # THE OTHER HALF OF THE FIX. Removing the promotion must not delete the
    # fact: when an agent genuinely cannot speak, "no voice worker in this
    # room" is the most useful sentence on the screen. It survives exactly
    # where it lived before stage 2 promoted it — as the trailing note
    # `AgentDelayReason.for_agent/1` returns, inline in the word row.
    #
    # Without this test the fix would trade a false positive for a false
    # negative and both tests above would still pass.
    test "the reason survives as a trailing note, inline, with no age threshold" do
      agent = failing_config!()
      mid = meeting_id()
      t0 = ~U[2026-01-01 00:00:00Z]

      {:ok, _entry} = AgentActivity.push(mid, agent.id, :composing, now: t0)

      # One second in — far below `default_shows_after_s/0`, so this note
      # cannot be the generic "still running a tool" arriving early.
      html = rail(agent, mid, DateTime.add(t0, 1, :second))

      assert trailing_note(html) == "· no voice worker in this room"
      refute trailing_note(html) =~ AgentDelayReason.default_clause()

      # Inline, in the word row — present WITHOUT adding a block line.
      assert block_line_count(html) == 2
      assert nodes(html, ~s([data-role="agent-activity-delay-reason"])) == []

      # The state word is still the true one beside it.
      assert primary_word(html) == "Writing · 1s"
    end
  end

  # ── The t+15s default clause: recorded, deliberately NOT changed ──────

  # The reviewing agent's second, weaker observation was that a `:thinking`
  # row at t+15s gains a trailing `· still running a tool` span
  # (`AgentDelayReason.default_shows_after_s/0` is 10), and that at the
  # rail's ~224px `Thinking · 15s · still running a tool` will WRAP inside
  # its `flex-wrap` row — changing rendered height, which the case says
  # never happens.
  #
  # It is left as it is, and this test is that decision written down rather
  # than left implicit. Three reasons:
  #
  #   1. It is PRE-EXISTING and ratified. The trailing span and its
  #      `flex-wrap` row came from task 01a06e07 stage 3 (commit
  #      `205642c7`, merged as #932), whose own comment states the intent
  #      in terms: the clause "drops to a second line rather than being
  #      clipped — the node used to carry `truncate`, which is exactly the
  #      clip this stage removes". Wrapping instead of clipping was the
  #      decision, not an oversight, and 01a06e07's tests assert the
  #      no-truncate half of it. Nothing in THIS task introduced it.
  #
  #   2. Every available fix contradicts a ratified decision. Re-adding
  #      `truncate` reinstates the clip #932 deliberately removed;
  #      suppressing the default clause deletes a note the direction wants;
  #      moving it to its own line makes the row taller, which is the very
  #      thing being avoided. Choosing among those is a design call for the
  #      canvas owner (`01a07402-99e3`), not a gate remedy.
  #
  #   3. It is not measurable here. `render_component/2` yields DOM, not
  #      layout — no test in this repo can observe a wrap, so a change made
  #      on this basis would be unverifiable by the suite that guards it.
  #
  # What CAN be pinned is the DOM-level invariant, and it is pinned below:
  # the note stays INLINE in the word row and the block line count stays 2.
  # So the residual question is purely one of pixel layout, and it is
  # scoped to a note that has been rendering this way since #932.
  test "the t+15s default clause stays inline — block lines stay 2 (see comment)" do
    agent = failing_config!()
    mid = meeting_id()
    t0 = ~U[2026-01-01 00:00:00Z]

    {:ok, _entry} = AgentActivity.push(mid, agent.id, :thinking, now: t0)

    html = rail(agent, mid, DateTime.add(t0, 15, :second))

    assert primary_word(html) == "Thinking · 15s"

    # This configuration has a specific cause, so the note is the voice one
    # rather than the default clause — the specific clauses have no age
    # threshold and outrank it.
    assert trailing_note(html) == "· no voice worker in this room"

    # The invariant that IS observable in DOM.
    assert block_line_count(html) == 2
    assert nodes(html, ~s([data-role="agent-activity-delay-reason"])) == []
  end

  # The default clause itself, on a clean agent, at t+15s — the exact row
  # the observation is about. Same conclusion: inline, two block lines.
  test "the generic 'still running a tool' note is also inline at t+15s" do
    owner = user!()
    agent = agent!()
    agent = connected_brain!(owner, agent)

    # A brain and NO voice row at all, so `resolve_voice_target/1` takes its
    # legacy fallback and seats the brain — the reviewer's PASSING config.
    :ets.delete(@voice_seat_table, agent.id)
    assert VoiceSeatCache.seated?(agent)
    refute Meetings.runtime_offline?(agent)

    mid = meeting_id()
    t0 = ~U[2026-01-01 00:00:00Z]
    {:ok, _entry} = AgentActivity.push(mid, agent.id, :thinking, now: t0)

    # t+3s: no note at all, and the state word is the working one — this is
    # the reviewer's measured PASSING row, reproduced.
    early = rail(agent, mid, DateTime.add(t0, 3, :second))
    assert primary_word(early) == "Thinking · 3s"
    assert trailing_note(early) == ""
    assert block_line_count(early) == 2

    # t+15s: the default clause appears, inline, still two block lines.
    late = rail(agent, mid, DateTime.add(t0, 15, :second))
    assert primary_word(late) == "Thinking · 15s"
    assert trailing_note(late) == "· " <> AgentDelayReason.default_clause()
    assert block_line_count(late) == 2
    assert activity_state(late) == "thinking"
  end

  # ── The promotion set still promotes what genuinely blocks ────────────

  # The fix narrows the promotion set; it does not empty it. An agent whose
  # BRAIN is offline is genuinely stuck, and must still read Delayed with
  # its reason on the protected second line. Without this, a change that
  # simply stopped promoting anything at all would pass every test above.
  test "an offline BRAIN still promotes to Delayed, with the second line" do
    owner = user!()
    agent = agent!()

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: "brain-off-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, _raw} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)

    # Never tracked in RuntimePresence — the brain is down.
    assert Meetings.runtime_offline?(agent)

    :ets.delete(@voice_seat_table, agent.id)

    mid = meeting_id()
    t0 = ~U[2026-01-01 00:00:00Z]
    {:ok, _entry} = AgentActivity.push(mid, agent.id, :composing, now: t0)

    html = rail(agent, mid, DateTime.add(t0, 5, :second))

    assert primary_word(html) == "Delayed"
    assert activity_state(html) == "delayed"
    assert text_at(html, ~s([data-role="agent-activity-delay-reason"])) == "agent went offline"
    assert block_line_count(html) == 3
    assert sr_label(html) == "Vox is Delayed, agent went offline"
  end

  # ── The unit-level statement of the same rule ─────────────────────────

  describe "AgentDelayReason: the two readers now differ by exactly one clause" do
    test "no_voice_worker? is a note but never a state" do
      facts = %{no_voice_worker?: true}

      assert AgentDelayReason.for_agent(facts) == "no voice worker in this room"
      assert AgentDelayReason.specific_for_agent(facts) == nil
      assert Delayed.from_facts(facts) == :none
      assert AgentActivity.delays_from_facts(%{"a-1" => facts}) == %{}
    end

    # `for_agent/1`'s behaviour is UNCHANGED by the fix, including the
    # priority order the stage specified. Pinned here because the two
    # readers are now separate code paths and could drift.
    test "for_agent/1 keeps its order: budget > voice > chain > offline > default" do
      assert AgentDelayReason.for_agent(%{
               reply_budget_exhausted?: true,
               reply_budget_reset_in_s: 5,
               no_voice_worker?: true
             }) == "reply budget resets in 5s"

      assert AgentDelayReason.for_agent(%{no_voice_worker?: true, agent_chain_too_deep?: true}) ==
               "no voice worker in this room"

      assert AgentDelayReason.for_agent(%{agent_chain_too_deep?: true, runtime_offline?: true}) ==
               "waiting for a human to speak"

      assert AgentDelayReason.for_agent(%{runtime_offline?: true, age_s: 600}) ==
               "agent went offline"

      assert AgentDelayReason.for_agent(%{age_s: 600}) == AgentDelayReason.default_clause()
      assert AgentDelayReason.for_agent(%{age_s: 0}) == nil
    end

    # The voice clause must not have been quietly swallowed by the budget
    # clause's position: with the budget fact FALSE it still shows.
    test "the voice note shows on its own, not only behind another cause" do
      assert AgentDelayReason.for_agent(%{
               reply_budget_exhausted?: false,
               no_voice_worker?: true,
               agent_chain_too_deep?: false,
               runtime_offline?: false,
               age_s: 0
             }) == "no voice worker in this room"
    end

    test "the other three causes are still promotable" do
      for facts <- [
            %{reply_budget_exhausted?: true, reply_budget_reset_in_s: 7},
            %{agent_chain_too_deep?: true},
            %{runtime_offline?: true}
          ] do
        assert {:ok, %Delayed{}} = Delayed.from_facts(facts)
      end
    end
  end
end
