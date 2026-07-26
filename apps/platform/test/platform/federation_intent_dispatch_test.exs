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
