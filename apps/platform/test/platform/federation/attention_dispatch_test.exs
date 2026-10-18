defmodule Platform.Federation.AttentionDispatchTest do
  @moduledoc """
  Task 019fb90f stage 2 — `Platform.Federation.AttentionDispatch`.

  ## What each group would catch

    * **Ordering** — the only test here that could not be replaced by reading
      the source. It reads the mailbox *positionally* (`assert_receive` with a
      bare variable, then match) rather than selectively, because
      `assert_receive` scans the whole mailbox: a pair of pattern-matched
      `assert_receive`s passes identically whether the invite committed before
      or after the broadcast, and *after* is the bug.
    * **Refusal never blocks delivery** — one test per refusal shape, each
      asserting the signal still arrived AND that the distinct outcome atom
      reached telemetry. A funnel that returned early on `{:skip, _}` would
      turn a writability problem into a delivery failure, which is worse than
      the bug being fixed.
    * **`:space_id` is an option** — the payload carries a `space_id` in two
      places and the opts carry none. A funnel that sniffed the payload would
      invite; this asserts it does not, and that the payload still reaches the
      wire unaltered. Without the second half, "did not invite" would also be
      satisfied by a funnel that stripped the key.
    * **`:endpoint_not_ready`** — reached by unconfiguring the endpoint's
      `:pubsub_server`, not asserted by inspection. Before this test the arm
      was decoration: it was lifted verbatim from three copies in
      `Platform.Federation` that no test has ever entered, so it could have
      been deleted with the suite staying green.

  This module is `async: false` and that is required, not incidental: the
  `:endpoint_not_ready` test mutates the endpoint's global config table.
  ExUnit runs sync modules one at a time after the async ones, so no sibling
  test is in flight during that window.
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Federation.AttentionDispatch
  alias Platform.Repo

  @invite_event [:platform, :chat, :dispatch_auto_invite]

  # ── Builders ───────────────────────────────────────────────────────────────

  defp space!(attrs \\ %{}) do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, space} =
      Chat.create_space(
        Map.merge(%{name: "Funnel #{n}", slug: "funnel-#{n}", kind: "channel"}, attrs)
      )

    space
  end

  defp agent!(attrs \\ %{}) do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(
        Map.merge(
          %{
            slug: "funnel-target-#{n}",
            name: "Funnel Target #{n}",
            status: "active",
            max_concurrent: 1,
            sandbox_mode: "off",
            model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
          },
          attrs
        )
      )
      |> Repo.insert()

    agent
  end

  # A runtime_id that is subscribed but NOT backed by an AgentRuntime row. The
  # funnel takes the runtime_id it is handed and never looks it up — resolution
  # is the caller's job (see `Federation.dispatch_scribe_attention/2`), and
  # keeping that out of here is what lets stage 3 reuse it from the TaskRouter.
  defp subscribed_runtime_id do
    runtime_id = "funnel-runtime-#{System.unique_integer([:positive])}"
    PlatformWeb.Endpoint.subscribe(AttentionDispatch.topic(runtime_id))
    runtime_id
  end

  defp participant_count(space_id, agent_id) do
    Repo.aggregate(
      from(p in Participant,
        where:
          p.space_id == ^space_id and p.participant_type == "agent" and
            p.participant_id == ^agent_id
      ),
      :count
    )
  end

  defp attach_invite_telemetry do
    ref = make_ref()
    pid = self()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      @invite_event,
      fn _event, measurements, metadata, _cfg ->
        send(pid, {:auto_invite, ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  defp signal_payload(overrides \\ %{}) do
    %{signal: Map.merge(%{reason: "funnel_probe"}, overrides)}
  end

  # ── Ordering ───────────────────────────────────────────────────────────────

  describe "ordering of invite vs broadcast" do
    test "the invite is committed before the attention broadcast leaves" do
      ref = attach_invite_telemetry()
      space = space!()
      agent = agent!()
      runtime_id = subscribed_runtime_id()

      assert :ok =
               AttentionDispatch.broadcast(runtime_id, signal_payload(),
                 space_id: space.id,
                 agent_id: agent.id,
                 source: :meeting_scribe
               )

      # POSITIONAL, not selective. `assert_receive` with a pattern searches the
      # entire mailbox, so writing the two assertions as patterns would pass
      # with the order inverted — and inverted is precisely the dead-on-arrival
      # window this module exists to close. Both sends originate in this
      # process, so mailbox order IS the happens-before order.
      assert_receive first, 1000
      assert {:auto_invite, ^ref, %{count: 1}, %{outcome: :invited}} = first

      assert_receive second, 1000
      assert %Phoenix.Socket.Broadcast{event: "attention"} = second

      # And "committed", not merely "attempted": the row is readable outside the
      # ensure_writable/3 call.
      assert %Participant{attention_mode: "mention", role: "member"} =
               Chat.get_agent_participant(space.id, agent.id)
    end
  end

  # ── Refusals never block delivery ──────────────────────────────────────────

  describe "broadcast/3 delivers regardless of the invite outcome" do
    test "invites and delivers when the dispatch names a live space" do
      ref = attach_invite_telemetry()
      space = space!()
      agent = agent!()
      runtime_id = subscribed_runtime_id()

      assert participant_count(space.id, agent.id) == 0

      assert :ok =
               AttentionDispatch.broadcast(runtime_id, signal_payload(),
                 space_id: space.id,
                 agent_id: agent.id,
                 source: :meeting_triage
               )

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1000
      assert_receive {:auto_invite, ^ref, _, %{outcome: :invited, source: :meeting_triage}}, 1000
      assert participant_count(space.id, agent.id) == 1
    end

    test "delivers with outcome :no_space_named when space_id is nil" do
      ref = attach_invite_telemetry()
      agent = agent!()
      runtime_id = subscribed_runtime_id()

      assert :ok =
               AttentionDispatch.broadcast(runtime_id, signal_payload(),
                 space_id: nil,
                 agent_id: agent.id,
                 source: :meeting_intent
               )

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1000
      assert_receive {:auto_invite, ^ref, _, %{outcome: :no_space_named}}, 1000

      assert Repo.aggregate(
               from(p in Participant,
                 where: p.participant_type == "agent" and p.participant_id == ^agent.id
               ),
               :count
             ) == 0
    end

    test "delivers with outcome :direct_space when the named space is a DM" do
      ref = attach_invite_telemetry()
      space = space!(%{kind: "dm", is_direct: true})
      agent = agent!()
      runtime_id = subscribed_runtime_id()

      assert :ok =
               AttentionDispatch.broadcast(runtime_id, signal_payload(),
                 space_id: space.id,
                 agent_id: agent.id,
                 source: :agent_responder
               )

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1000
      assert_receive {:auto_invite, ^ref, _, %{outcome: :direct_space}}, 1000
      assert participant_count(space.id, agent.id) == 0
    end

    test "delivers with outcome :space_archived when the named space is archived" do
      ref = attach_invite_telemetry()
      {:ok, space} = Chat.archive_space(space!())
      agent = agent!()
      runtime_id = subscribed_runtime_id()

      assert :ok =
               AttentionDispatch.broadcast(runtime_id, signal_payload(),
                 space_id: space.id,
                 agent_id: agent.id,
                 source: :task_router
               )

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1000
      assert_receive {:auto_invite, ^ref, _, %{outcome: :space_archived}}, 1000
      assert participant_count(space.id, agent.id) == 0
    end

    test "delivers with outcome :agent_not_found when the named agent is unknown" do
      ref = attach_invite_telemetry()
      space = space!()
      runtime_id = subscribed_runtime_id()
      missing = Ecto.UUID.generate()

      assert :ok =
               AttentionDispatch.broadcast(runtime_id, signal_payload(),
                 space_id: space.id,
                 agent_id: missing,
                 source: :meeting_scribe
               )

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1000
      assert_receive {:auto_invite, ^ref, _, %{outcome: :agent_not_found}}, 1000
    end
  end

  # ── space_id is an option, never sniffed ───────────────────────────────────

  describe "space_id is an option, not payload-derived" do
    test "a space named only inside the payload does not produce an invite" do
      ref = attach_invite_telemetry()
      space = space!()
      agent = agent!()
      runtime_id = subscribed_runtime_id()

      # The space is named in BOTH places a sniffing implementation would look:
      # top-level and inside the signal envelope. Neither is an instruction.
      payload = %{space_id: space.id, signal: %{reason: "probe", space_id: space.id}}

      assert :ok =
               AttentionDispatch.broadcast(runtime_id, payload,
                 agent_id: agent.id,
                 source: :meeting_intent
               )

      assert_receive {:auto_invite, ^ref, _, %{outcome: :no_space_named, space_id: nil}}, 1000
      assert participant_count(space.id, agent.id) == 0

      # Second half: the payload still reached the wire intact. Without this,
      # "no invite happened" would also be satisfied by a funnel that stripped
      # the key on the way out — which would break the client-side permission
      # prompt pinning that keeping `space_id` an option exists to protect.
      space_id = space.id

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{space_id: ^space_id, signal: %{space_id: ^space_id}}
                     },
                     1000
    end
  end

  # ── Topic ──────────────────────────────────────────────────────────────────

  describe "topic/1" do
    test "is keyed by the runtime_id string, which is what RuntimeChannel joins" do
      assert AttentionDispatch.topic("alex-claude-agent-1") == "runtime:alex-claude-agent-1"
    end

    test "is keyed by runtime_id and not by the linked agent's id" do
      # The distinction is invisible in most fixtures because both are opaque
      # strings; it is the difference between a live runtime receiving the
      # dispatch and nobody receiving it.
      user =
        Repo.insert!(%Platform.Accounts.User{
          email: "funnel-#{System.unique_integer([:positive])}@example.com",
          name: "Funnel User",
          oidc_sub: "oidc-funnel-#{System.unique_integer([:positive])}"
        })

      agent = agent!()
      runtime_id = "funnel-topic-#{System.unique_integer([:positive])}"

      {:ok, runtime} =
        Platform.Federation.register_runtime(user.id, %{runtime_id: runtime_id})

      {:ok, _} = Platform.Federation.link_agent(runtime, agent)

      assert %AgentRuntime{runtime_id: ^runtime_id} =
               Repo.get(AgentRuntime, runtime.id)

      assert AttentionDispatch.topic(runtime_id) == "runtime:#{runtime_id}"
      refute AttentionDispatch.topic(runtime_id) == "runtime:#{agent.id}"
    end
  end

  # ── Errors ─────────────────────────────────────────────────────────────────

  describe "broadcast failures" do
    test "returns {:error, :endpoint_not_ready} when the endpoint has no pubsub server" do
      # `PlatformWeb.Endpoint.broadcast/3` resolves `config(:pubsub_server)` and
      # raises ArgumentError when it is absent — that raise is the ONLY way into
      # the rescue arm, and it is reachable only through the endpoint's config
      # table (`Phoenix.Config` creates it `:public`). Restored in `after` so a
      # failing assertion cannot leave the endpoint unusable for the rest of the
      # run.
      original = PlatformWeb.Endpoint.config(:pubsub_server)
      assert original != nil

      runtime_id = "funnel-unready-#{System.unique_integer([:positive])}"

      try do
        :ets.delete(PlatformWeb.Endpoint, :pubsub_server)

        assert {:error, :endpoint_not_ready} =
                 AttentionDispatch.broadcast(runtime_id, signal_payload(),
                   space_id: nil,
                   agent_id: nil,
                   source: :task_router
                 )
      after
        :ets.insert(PlatformWeb.Endpoint, {:pubsub_server, original})
      end

      # And the endpoint is healthy again — otherwise this test would poison
      # every sync module scheduled after it.
      assert PlatformWeb.Endpoint.config(:pubsub_server) == original
      assert :ok = AttentionDispatch.broadcast(runtime_id, signal_payload(), agent_id: nil)
    end

    test "the invite still runs when the broadcast cannot go out" do
      # The invite is NOT conditional on delivery succeeding. Ordering makes
      # this fall out for free, but "for free" is exactly the kind of property
      # a later refactor removes silently.
      ref = attach_invite_telemetry()
      space = space!()
      agent = agent!()
      original = PlatformWeb.Endpoint.config(:pubsub_server)

      try do
        :ets.delete(PlatformWeb.Endpoint, :pubsub_server)

        assert {:error, :endpoint_not_ready} =
                 AttentionDispatch.broadcast("funnel-unready-2", signal_payload(),
                   space_id: space.id,
                   agent_id: agent.id,
                   source: :meeting_scribe
                 )
      after
        :ets.insert(PlatformWeb.Endpoint, {:pubsub_server, original})
      end

      assert_receive {:auto_invite, ^ref, _, %{outcome: :invited}}, 1000
      assert participant_count(space.id, agent.id) == 1
    end
  end
end
