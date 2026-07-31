defmodule Platform.Meetings.IntentRuntimeAdapterTest do
  @moduledoc """
  Unit tests for `Platform.Meetings.IntentRuntimeAdapter` (task
  019f70b8 stage 4) — the shared helper that turns an intent row into
  something a runtime can receive.

  The integration behaviour (a real classified intent walking role →
  agent → runtime → topic) lives in
  `Platform.Meetings.IntentDispatcherTest`. What is pinned HERE is the
  narrower contract that dispatcher relies on:

    * `resolve_target/1` distinguishes three failure facts, and none of
      them is "close enough" to the others
    * a runtime row with no addressable `runtime_id` is `:no_runtime`,
      not a topic named `"runtime:"`
    * both payload builders read the ROW, so a payload can never
      disagree with the queue about where an intent went
  """

  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Federation
  alias Platform.Meetings.IntentRuntimeAdapter, as: Adapter
  alias Platform.Repo

  defp create_agent! do
    %Agent{}
    |> Agent.changeset(%{
      slug: "adapter-agent-#{System.unique_integer([:positive])}",
      name: "Adapter Test Agent",
      status: "active",
      kind: "native"
    })
    |> Repo.insert!()
  end

  defp create_user! do
    Repo.insert!(%User{
      email: "adapter_#{System.unique_integer([:positive])}@example.com",
      name: "Adapter Test User",
      oidc_sub: "oidc-adapter-#{System.unique_integer([:positive])}"
    })
  end

  defp create_linked_agent! do
    agent = create_agent!()
    user = create_user!()

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "adapter-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, linked} = Federation.link_agent(runtime, agent)
    {linked, runtime}
  end

  defp row(overrides) do
    Map.merge(
      %{
        id: Platform.Types.UUIDv7.generate(),
        meeting_id: Platform.Types.UUIDv7.generate(),
        room_id: "room-adapter",
        chunk_excerpt: "we should book a follow-up",
        classified_intent: "book_followup",
        target_role: "designer",
        target_agent_id: nil,
        confidence: 0.91,
        subagent_id: nil,
        status: :dispatched
      },
      overrides
    )
  end

  describe "resolve_target/1" do
    test "resolves an agent with a linked runtime to its topic" do
      {agent, runtime} = create_linked_agent!()

      assert {:ok, target} = Adapter.resolve_target(agent)
      assert target.agent.id == agent.id
      assert target.runtime.id == runtime.id
      assert target.runtime_id == runtime.runtime_id
      assert target.topic == "runtime:#{runtime.runtime_id}"
    end

    test "accepts an agent id and reads the agent itself" do
      {agent, runtime} = create_linked_agent!()

      assert {:ok, target} = Adapter.resolve_target(agent.id)
      assert target.topic == "runtime:#{runtime.runtime_id}"
    end

    test "nil, missing, and runtime-less are three different facts" do
      # Collapsing these would cost the producer the difference between
      # "the classifier named nobody", "the role points at a deleted
      # agent", and "this agent has no runtime linked" — three
      # different fixes.
      assert Adapter.resolve_target(nil) == {:error, :no_target_agent}

      assert Adapter.resolve_target(Platform.Types.UUIDv7.generate()) ==
               {:error, :agent_not_found}

      assert Adapter.resolve_target(create_agent!()) == {:error, :no_runtime}
    end

    test "the topic key can never be null — why the is_binary guard is belt-and-braces" do
      # `resolve_target/1` guards on `is_binary(runtime_id)` so a
      # half-provisioned runtime can never resolve to the topic
      # `"runtime:"` — a topic every runtime-less dispatch would then
      # silently share. That branch is unreachable today, and this is
      # the reason: `agent_runtimes.runtime_id` is NOT NULL in the
      # schema and required by the changeset. If either ever relaxes,
      # this test fails and the guard starts earning its keep.
      changeset = AgentRuntime.changeset(%AgentRuntime{}, %{owner_user_id: create_user!().id})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :runtime_id)
    end
  end

  describe "attention_payload/2" do
    test "carries the seven signal fields off the row" do
      agent_id = Platform.Types.UUIDv7.generate()
      r = row(%{target_agent_id: agent_id})

      payload = Adapter.attention_payload(r)

      assert payload.reason == "meeting_intent_dispatch"
      assert payload.intent_id == r.id
      assert payload.meeting_id == r.meeting_id
      assert payload.transcript_chunk_excerpt == "we should book a follow-up"
      assert payload.classified_intent == "book_followup"
      assert payload.target_agent_id == agent_id
      assert payload.confidence == 0.91
    end

    test "names the space as target_space_id and leaves the space_id slot free" do
      space_id = Platform.Types.UUIDv7.generate()

      payload = Adapter.attention_payload(row(%{}), space_id)

      # BOTH halves, because either alone is satisfied by the bug. The
      # positive alone passes for an envelope that helpfully emits both keys
      # — which is the thing that would re-pin a live client-side permission
      # prompt (see `Chat.AgentResponder.build_system_event_payload/1`). The
      # negative alone passes for an envelope that names no space at all,
      # which is the dead-on-arrival state this whole task exists to close.
      assert payload.target_space_id == space_id
      refute Map.has_key?(payload, :space_id)
    end

    test "a nil space omits the key rather than emitting a null one" do
      r = row(%{})
      payload = Adapter.attention_payload(r, nil)

      refute Map.has_key?(payload, :target_space_id)
      refute Map.has_key?(payload, :space_id)

      # The rest of the envelope is unaffected — a missing space is not a
      # reason to ship a degraded signal.
      assert payload.reason == "meeting_intent_dispatch"
      assert payload.intent_id == r.id
    end
  end

  describe "send_attention/3" do
    test "the space argument has no default — arity 2 is not exported" do
      # Pinning the ABSENCE of `\\ nil` deliberately. A default would compile,
      # keep every existing caller green, and let a future dispatch path ship
      # an envelope with no space — reintroducing the dead-on-arrival gap
      # without anyone editing the adapter. Making the argument mandatory is
      # what forces that decision into the diff.
      assert function_exported?(Adapter, :send_attention, 3)
      refute function_exported?(Adapter, :send_attention, 2)
    end

    test "the resolved space reaches the wire as target_space_id" do
      {agent, runtime} = create_linked_agent!()
      :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime.runtime_id}")

      space_id = Platform.Types.UUIDv7.generate()
      r = row(%{target_agent_id: agent.id})

      assert :ok = Adapter.send_attention(r, %{agent: agent}, space_id)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention", payload: %{signal: signal}},
                     500

      assert signal.target_space_id == space_id
      refute Map.has_key?(signal, :space_id)
    end
  end

  describe "cancel_payload/4" do
    test "carries the subagent_id the target stamped at ack time" do
      r = row(%{subagent_id: "cancel-probe-9x", status: :acked})

      payload = Adapter.cancel_payload(r, :wrong_target)

      assert payload.intent_id == r.id
      assert payload.subagent_id == "cancel-probe-9x"
      assert payload.reason == :wrong_target
      assert payload.status == :acked
      assert payload.corrected_intent == nil
      assert payload.corrected_target_agent_id == nil
    end

    test "carries a pencil edit's corrected fields" do
      r = row(%{subagent_id: "pencil-probe"})
      corrected_id = Platform.Types.UUIDv7.generate()

      payload = Adapter.cancel_payload(r, :wrong_intent, "draft_brief", corrected_id)

      assert payload.corrected_intent == "draft_brief"
      assert payload.corrected_target_agent_id == corrected_id
    end
  end

  describe "cancel/2" do
    test "broadcasts on the resolved runtime's topic" do
      {agent, runtime} = create_linked_agent!()
      :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime.runtime_id}")

      r = row(%{target_agent_id: agent.id, subagent_id: "sub-1", status: :acked})

      assert :ok = Adapter.cancel(r, reason: :not_actionable)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: topic,
                       event: "intent_cancelled",
                       payload: %{subagent_id: "sub-1", reason: :not_actionable}
                     },
                     500

      assert topic == "runtime:#{runtime.runtime_id}"
    end

    test "surfaces the resolution error rather than silently doing nothing" do
      # Unlike dispatch, a cancel that never leaves has no ack contract
      # behind it to eventually resolve the row — the caller has to
      # know so it can land the row itself.
      r = row(%{target_agent_id: create_agent!().id})
      assert Adapter.cancel(r) == {:error, :no_runtime}

      assert Adapter.cancel(row(%{target_agent_id: nil})) == {:error, :no_target_agent}
    end
  end
end
