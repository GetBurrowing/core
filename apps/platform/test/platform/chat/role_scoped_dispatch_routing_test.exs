defmodule Platform.Chat.RoleScopedDispatchRoutingTest do
  @moduledoc """
  Role-scoped system dispatches must reach the ROLE HOLDER, never whoever
  happens to hold the `ActiveAgentStore` mutex in the space.

  These assertions are deliberately written against the RECIPIENT rather than
  against the absence of an error. Page writes are Historian-only at the tool
  boundary, so a misrouted curation dispatch raises nothing at all — an
  error-free run is not evidence of correct routing here.
  """
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AttentionRouter, Message}
  alias Platform.Repo
  alias Platform.Roles

  setup do
    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)

    on_exit(fn ->
      Application.put_env(:platform, :chat_agent_dispatch_mode, previous_mode)
    end)

    router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
    Sandbox.allow(Repo, self(), router)

    store = Process.whereis(ActiveAgentStore) || start_supervised!({ActiveAgentStore, []})
    Sandbox.allow(Repo, self(), store)

    :ok
  end

  defp unique_slug, do: "role-scoped-#{System.unique_integer([:positive])}"

  defp create_space do
    {:ok, space} =
      Chat.create_space(%{name: "Role Scoped", slug: unique_slug(), kind: "channel"})

    space
  end

  defp create_agent(name) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "#{String.downcase(name)}-#{System.unique_integer([:positive])}",
        name: name,
        status: "active",
        max_concurrent: 1,
        sandbox_mode: "off",
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })
      |> Repo.insert()

    agent
  end

  defp add_agent_participant(space_id, %Agent{} = agent) do
    {:ok, participant} =
      Chat.add_participant(space_id, %{
        participant_type: "agent",
        participant_id: agent.id,
        display_name: agent.name,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp add_human_participant(space_id) do
    {:ok, participant} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Alex",
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp create_message(space_id, participant_id, metadata) do
    {:ok, message} =
      %Message{}
      |> Message.changeset(%{
        space_id: space_id,
        participant_id: participant_id,
        content_type: "text",
        content: "You are the Historian. Curate pages from today's journal.",
        metadata: metadata
      })
      |> Repo.insert()

    message
  end

  # Two agent participants in one space: `holder_name` is pinned to the role,
  # `mutex_name` holds the ActiveAgentStore mutex and must never receive a
  # role-scoped dispatch.
  defp two_agent_space(opts) do
    space = create_space()
    human = add_human_participant(space.id)

    holder_agent = create_agent("Higgins")
    mutex_agent = create_agent("Moore")

    holder_p = add_agent_participant(space.id, holder_agent)
    mutex_p = add_agent_participant(space.id, mutex_agent)

    # Arm the mutex on the NON-role-holder. This is the whole hazard.
    ActiveAgentStore.set_active(space.id, mutex_p.id)

    case Keyword.get(opts, :assign) do
      nil -> :ok
      {role_key, :holder} -> {:ok, _} = Roles.assign_role(role_key, holder_agent.id)
      {role_key, :mutex} -> {:ok, _} = Roles.assign_role(role_key, mutex_agent.id)
    end

    %{
      space: space,
      human: human,
      holder_agent: holder_agent,
      mutex_agent: mutex_agent,
      holder_p: holder_p,
      mutex_p: mutex_p
    }
  end

  describe "role-scoped dispatch routing" do
    test "routes to the role holder, not the mutex holder" do
      ctx = two_agent_space(assign: {"historian", :holder})

      assert Roles.agent_id_for_role("historian") == ctx.holder_agent.id

      message =
        create_message(ctx.space.id, ctx.human.id, %{
          "source" => "system_event",
          "skip_mention_scan" => true,
          "role_scoped_dispatch" => "historian"
        })

      assert {:ok, decisions} = AttentionRouter.route(message)

      holder_pid = ctx.holder_p.id
      assert [%{participant_id: ^holder_pid, reason: :role_scoped}] = decisions

      # Positively assert the wrong recipient got nothing.
      mutex_pid = ctx.mutex_p.id
      refute Enum.any?(decisions, &(&1.participant_id == mutex_pid))

      # The dispatch is not a conversational turn: it must not move the mutex.
      assert ActiveAgentStore.get_active(ctx.space.id) == mutex_pid
    end

    test "refuses with a named reason when the role is unfilled" do
      ctx = two_agent_space([])

      Roles.unassign_role("historian")
      assert Roles.agent_id_for_role("historian") == nil

      handler_id = "role-scoped-refusal-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:platform, :chat, :role_scoped_dispatch, :refused],
        fn _event, measurements, metadata, _cfg ->
          send(test_pid, {:refused, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      message =
        create_message(ctx.space.id, ctx.human.id, %{
          "source" => "system_event",
          "skip_mention_scan" => true,
          "role_scoped_dispatch" => "historian"
        })

      assert {:ok, decisions} = AttentionRouter.route(message)

      assert decisions == []

      mutex_pid = ctx.mutex_p.id
      refute Enum.any?(decisions, &(&1.participant_id == mutex_pid))

      assert_receive {:refused, _measurements, telemetry_metadata}, 1_000
      assert telemetry_metadata.role_key == "historian"
      assert telemetry_metadata.reason == :role_unfilled
      assert telemetry_metadata.message_id == message.id
      assert telemetry_metadata.space_id == ctx.space.id
    end

    test "refuses when the role holder is not a participant of the space" do
      ctx = two_agent_space([])

      outsider = create_agent("Outsider")
      {:ok, _} = Roles.assign_role("historian", outsider.id)
      assert Chat.get_agent_participant(ctx.space.id, outsider.id) == nil

      handler_id = "role-scoped-absent-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:platform, :chat, :role_scoped_dispatch, :refused],
        fn _event, measurements, metadata, _cfg ->
          send(test_pid, {:refused, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      message =
        create_message(ctx.space.id, ctx.human.id, %{
          "role_scoped_dispatch" => "historian"
        })

      assert {:ok, decisions} = AttentionRouter.route(message)
      assert decisions == []

      mutex_pid = ctx.mutex_p.id
      refute Enum.any?(decisions, &(&1.participant_id == mutex_pid))

      assert_receive {:refused, _measurements, telemetry_metadata}, 1_000
      assert telemetry_metadata.role_key == "historian"
      assert telemetry_metadata.reason == :role_holder_not_in_space
    end

    # Generality: the guard reads the role KEY out of the metadata, so it must
    # hold for a role that has nothing to do with the Historian. If this passes
    # only for "historian", the fix is a special case wearing a general name.
    test "binds to the architect role holder, proving the guard is not Historian-specific" do
      ctx = two_agent_space(assign: {"architect", :mutex})

      # The architect here is the agent that ALSO holds the mutex, and the
      # other agent holds `historian` — so a mutex-shaped bug and a
      # historian-shaped bug would each give the wrong answer to this case.
      {:ok, _} = Roles.assign_role("historian", ctx.holder_agent.id)

      message =
        create_message(ctx.space.id, ctx.human.id, %{
          "role_scoped_dispatch" => "architect"
        })

      assert {:ok, decisions} = AttentionRouter.route(message)

      architect_pid = ctx.mutex_p.id
      assert [%{participant_id: ^architect_pid, reason: :role_scoped}] = decisions

      historian_pid = ctx.holder_p.id
      refute Enum.any?(decisions, &(&1.participant_id == historian_pid))
    end

    test "messages without the metadata key route exactly as before" do
      ctx = two_agent_space(assign: {"historian", :holder})

      message = create_message(ctx.space.id, ctx.human.id, %{"source" => "user"})

      assert {:ok, decisions} = AttentionRouter.route(message)

      mutex_pid = ctx.mutex_p.id
      assert [%{participant_id: ^mutex_pid, reason: :active_agent}] = decisions
    end

    test "a blank role key degrades to ordinary routing rather than refusing" do
      ctx = two_agent_space(assign: {"historian", :holder})

      message = create_message(ctx.space.id, ctx.human.id, %{"role_scoped_dispatch" => ""})

      assert AttentionRouter.role_scoped_dispatch_role(message) == nil

      assert {:ok, decisions} = AttentionRouter.route(message)

      mutex_pid = ctx.mutex_p.id
      assert [%{participant_id: ^mutex_pid, reason: :active_agent}] = decisions
    end
  end
end
