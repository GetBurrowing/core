defmodule Platform.FederationIntentDispatchTest do
  @moduledoc """
  Tests for `Platform.Federation.dispatch_intent_attention/2` (task
  019f70b8 stage 4) — the meeting-intent parallel of
  `dispatch_scribe_attention/2` and `dispatch_triage_attention/2`.

  Mirrors the `dispatch_triage_attention/2` describe block in
  `Platform.FederationTest` case for case, because the contract is
  deliberately identical: always `:ok`, every failure reported through
  `[:platform, :meetings, :intent_dispatch, :assignee_unresolvable]`
  telemetry, broadcast on `runtime:<runtime_id>` under the `"attention"`
  event with a `%{signal: payload}` envelope.

  Kept in its own file rather than appended to `federation_test.exs`
  because the intent-dispatch surface has a second consumer contract
  the sibling dispatchers don't — `Platform.Meetings.IntentRuntimeAdapter`
  resolves the runtime BEFORE calling this, and the reason it has to is
  the whole subject of the last describe block here.
  """

  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation
  alias Platform.Meetings.IntentRuntimeAdapter, as: Adapter
  alias Platform.Repo

  @intent_event [:platform, :meetings, :intent_dispatch, :assignee_unresolvable]

  setup do
    handler_id = "test-intent-dispatch-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      @intent_event,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp create_user do
    Repo.insert!(%User{
      email: "intent_dispatch_#{System.unique_integer([:positive])}@example.com",
      name: "Intent Dispatch Test User",
      oidc_sub: "oidc-intent-dispatch-#{System.unique_integer([:positive])}"
    })
  end

  defp create_agent do
    %Agent{}
    |> Agent.changeset(%{
      slug: "intent-dispatch-agent-#{System.unique_integer([:positive])}",
      name: "Intent Dispatch Test Agent",
      status: "active"
    })
    |> Repo.insert!()
  end

  defp link_runtime!(agent) do
    user = create_user()

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "intent-dispatch-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, linked} = Federation.link_agent(runtime, agent)
    {linked, runtime}
  end

  describe "dispatch_intent_attention/2" do
    test "broadcasts an attention signal to the linked runtime and returns :ok" do
      {agent, runtime} = link_runtime!(create_agent())

      PlatformWeb.Endpoint.subscribe("runtime:#{runtime.runtime_id}")

      intent_id = Platform.Types.UUIDv7.generate()
      meeting_id = Platform.Types.UUIDv7.generate()

      payload = %{
        reason: "meeting_intent_dispatch",
        intent_id: intent_id,
        meeting_id: meeting_id,
        transcript_chunk_excerpt: "we should redesign onboarding",
        classified_intent: "design_task",
        target_agent_id: agent.id,
        confidence: 0.92
      }

      assert :ok = Federation.dispatch_intent_attention(agent.id, payload)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{
                         signal: %{
                           reason: "meeting_intent_dispatch",
                           intent_id: ^intent_id,
                           meeting_id: ^meeting_id,
                           classified_intent: "design_task",
                           confidence: 0.92
                         }
                       }
                     },
                     500

      refute_received {:telemetry, @intent_event, _, _}
    end

    test "emits :agent_not_found telemetry and returns :ok when the agent id is unknown" do
      missing_id = Ecto.UUID.generate()

      assert :ok =
               Federation.dispatch_intent_attention(missing_id, %{
                 reason: "meeting_intent_dispatch"
               })

      assert_receive {:telemetry, @intent_event, %{count: 1},
                      %{
                        agent_id: ^missing_id,
                        reason: :agent_not_found,
                        actor_type: "system",
                        resource_type: "agent",
                        resource_id: ^missing_id
                      }},
                     500
    end

    test "emits :runtime_unresolvable telemetry when the agent has no linked runtime" do
      agent = create_agent()

      assert :ok =
               Federation.dispatch_intent_attention(agent.id, %{
                 reason: "meeting_intent_dispatch"
               })

      assert_receive {:telemetry, @intent_event, %{count: 1},
                      %{
                        agent_id: agent_id,
                        reason: :runtime_unresolvable,
                        actor_type: "system",
                        resource_type: "agent",
                        resource_id: resource_id
                      }},
                     500

      assert agent_id == agent.id
      assert resource_id == agent.id
    end

    test "uses its own telemetry event, not the triage or scribe one" do
      # Three parallel dispatchers, three event names. A shared event
      # would make a meeting-producer outage indistinguishable from a
      # scribe outage in the audit trail.
      triage_handler = "test-triage-cross-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach_many(
        triage_handler,
        [
          [:platform, :meetings, :triage_dispatch, :assignee_unresolvable],
          [:platform, :meetings, :scribe_dispatch, :assignee_unresolvable]
        ],
        fn event, _m, _meta, _ -> send(test_pid, {:sibling_telemetry, event}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(triage_handler) end)

      assert :ok = Federation.dispatch_intent_attention(Ecto.UUID.generate(), %{})

      assert_receive {:telemetry, @intent_event, _, _}, 500
      refute_received {:sibling_telemetry, _}
    end
  end

  describe "auto-invite funnel (task 019fb90f stage 2)" do
    @invite_event [:platform, :chat, :dispatch_auto_invite]

    setup do
      handler_id = {__MODULE__, :invite, System.unique_integer([:positive])}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        @invite_event,
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:auto_invite, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "an envelope that names no space is :no_space_named, and is still delivered" do
      # Stage 2 wrote this case to pin a GAP: back then
      # `attention_payload/1` never named a space at all, so every intent
      # dispatch landed here. Stage 4 closed the gap, and this case survives
      # as the residual path — a meeting id with no `meetings` row behind it
      # resolves to `nil`.
      #
      # What it still buys: the refusal has a NAME in telemetry rather than
      # being silence, and the broadcast goes out anyway. A dispatch the agent
      # can read but not write beats one it never receives.
      {agent, runtime} = link_runtime!(create_agent())
      PlatformWeb.Endpoint.subscribe("runtime:#{runtime.runtime_id}")

      assert :ok =
               Federation.dispatch_intent_attention(agent.id, %{
                 reason: "meeting_intent_dispatch",
                 intent_id: Platform.Types.UUIDv7.generate(),
                 meeting_id: Platform.Types.UUIDv7.generate(),
                 target_agent_id: agent.id
               })

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 500
      assert_receive {:auto_invite, _, %{outcome: :no_space_named, source: :meeting_intent}}, 500
    end

    test "target_space_id is invited into, attributed to :meeting_intent" do
      # Proves the intent path is wired to the same funnel as its two siblings
      # rather than merely compiling: give the envelope a real space and a row
      # appears — before the broadcast, which is the ordering assertion below.
      {agent, runtime} = link_runtime!(create_agent())
      PlatformWeb.Endpoint.subscribe("runtime:#{runtime.runtime_id}")

      space = create_meeting_space!()

      refute Platform.Chat.get_agent_participant(space.id, agent.id)

      assert :ok =
               Federation.dispatch_intent_attention(agent.id, %{
                 reason: "meeting_intent_dispatch",
                 target_space_id: space.id,
                 intent_id: Platform.Types.UUIDv7.generate(),
                 meeting_id: Platform.Types.UUIDv7.generate()
               })

      assert_receive first, 500
      assert {:auto_invite, _, %{outcome: :invited, source: :meeting_intent}} = first

      assert_receive second, 500
      assert %Phoenix.Socket.Broadcast{event: "attention"} = second

      assert %Platform.Chat.Participant{attention_mode: "mention", role: "member"} =
               Platform.Chat.get_agent_participant(space.id, agent.id)
    end

    test "a top-level space_id is NOT the key this path reads" do
      # The other side of the decision, and the half that cannot be inferred
      # from the test above. `target_space_id` exists precisely so the intent
      # envelope can name a space WITHOUT occupying `signal.space_id`, which a
      # live client uses to pin a pending permission prompt's answer space.
      #
      # A "helpful" change that read either key would satisfy the positive
      # test forever while quietly making it correct again to emit `space_id`
      # on the wire. Asserting a `space_id`-only envelope invites NOBODY is
      # what keeps the two keys distinguishable.
      {agent, runtime} = link_runtime!(create_agent())
      PlatformWeb.Endpoint.subscribe("runtime:#{runtime.runtime_id}")

      space = create_meeting_space!()

      assert :ok =
               Federation.dispatch_intent_attention(agent.id, %{
                 reason: "meeting_intent_dispatch",
                 space_id: space.id,
                 intent_id: Platform.Types.UUIDv7.generate(),
                 meeting_id: Platform.Types.UUIDv7.generate()
               })

      assert_receive {:auto_invite, _, %{outcome: outcome, source: :meeting_intent}}, 500

      # `:no_space_named`, not `:invited` — and note this is a DIFFERENT atom
      # from the one the test above observes, on the same space, with the same
      # agent. Only the key name changed.
      assert outcome == :no_space_named
      refute Platform.Chat.get_agent_participant(space.id, agent.id)

      # Delivery is unaffected either way.
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 500
    end

    defp create_meeting_space!(kind \\ "meeting") do
      n = System.unique_integer([:positive, :monotonic])

      {:ok, space} =
        Platform.Chat.create_space(%{
          name: "Intent Meeting #{n}",
          slug: "intent-meeting-#{n}",
          kind: kind
        })

      space
    end
  end

  describe "resolution split with IntentRuntimeAdapter" do
    test "the adapter reports what this function deliberately swallows" do
      # The queue has to choose between `:dispatched` (ack window armed)
      # and `:dispatch_failed{:no_runtime}` (retained, visible, red).
      # This function answers `:ok` to both, on purpose — so the
      # dispatcher asks the adapter first. If that split ever collapsed,
      # a runtime-less target would be marked `:dispatched` and then
      # time out 90 seconds later as amber, hiding a broken link behind
      # a "we waited and heard nothing" status.
      agent = create_agent()

      assert :ok = Federation.dispatch_intent_attention(agent.id, %{})
      assert Adapter.resolve_target(agent) == {:error, :no_runtime}
    end
  end
end
