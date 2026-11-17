defmodule Platform.Goals.IntakeDispatchIntegrationTest do
  @moduledoc """
  A New goal start gives the agent EXACTLY ONE trigger, out of the SQL
  sandbox with the REAL `Platform.Chat.AttentionRouter` (task 01a1eab6
  stage 2).

  The start posts the opening message with `route: :none` and signals the
  agent `goals.new_goal`, all inside `Platform.Tasks.PostCommit.scope/1`.
  So:
    * the signal is the only trigger: the router decides nothing for the
      opening message (reason `:caller_suppressed`) and broadcasts nothing to
      the runtime;
    * the router reads the row only after it committed: no
      `[AttentionRouter] message not found` line names it;
    * a later `say_in_conversation/3` is an ordinary turn: exactly one
      `:directed` dispatch.

  The shared SQL sandbox hides the "not found" race (one connection), so
  this module puts the pool in `:auto` mode
  (`Platform.Chat.PostMessageAfterCommitUnboxedTest`, stage 1): every
  process has its own real connection and really commits, and every row the
  test creates is deleted in `on_exit`. It calls `Platform.Goals.Proposals`
  directly (the switch and the `goals.use` check live in the `Platform.Goals`
  delegates and are covered elsewhere), so the rows stay few and known.

  The race is made deterministic: a telemetry handler on
  `[:platform, :chat, :message_posted]`, attached AFTER the router's own
  handler (telemetry runs an event's handlers in attach order), makes a
  synchronous `:__drain__` call to the router. The router handles its
  mailbox in order, so the drain returns only once it has looked the
  message up. If the publish fired inside the open transaction, that lookup
  misses and logs `message not found`.

  Observables: the router's `[:platform, :chat, :attention_routed]` and
  `[:platform, :chat, :attention_skipped]` telemetry (its decisions and
  their reasons), the `"attention"` broadcast on the runtime's topic (a real
  dispatch to an online runtime), and the `:wake_up_dispatcher` capture (the
  Goals signal).
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Access.{Grant, RuntimeProfile}
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Chat.{AttentionRouter, Message, Participant, Space}
  alias Platform.Federation.RuntimePresence
  alias Platform.Goals.{Proposal, Proposals}
  alias Platform.Repo
  alias Platform.Tenancy.{Org, OrgMembership}

  @opening "ORCHID-LANTERN: I want to see a theater play this month"

  setup do
    Sandbox.mode(Repo, :auto)

    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)
    previous_dispatcher = Application.fetch_env(:goals, :wake_up_dispatcher)
    test_pid = self()

    Application.put_env(:goals, :wake_up_dispatcher, fn signal ->
      send(test_pid, {:signal, signal})
      :ok
    end)

    n = System.unique_integer([:positive])
    root = Platform.Tenancy.get_root_org()

    org =
      %Org{}
      |> Org.changeset(%{name: "Intake #{n}", slug: "intake-#{n}", parent_org_id: root.id})
      |> Repo.insert!()

    user =
      Repo.insert!(%User{
        email: "intake-user-#{n}@example.com",
        name: "Intake User",
        oidc_sub: "oidc-intake-user-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
    |> Repo.insert!()

    owner =
      Repo.insert!(%User{
        email: "intake-owner-#{n}@example.com",
        name: "Intake Owner",
        oidc_sub: "oidc-intake-owner-#{n}"
      })

    runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: owner.id,
        status: "active",
        runtime_id: "rt-intake-#{n}",
        display_name: "intake-rt"
      })

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "intake-lead-#{n}",
        name: "Intake Lead",
        status: "active",
        max_concurrent: 1,
        sandbox_mode: "off",
        runtime_type: "external",
        runtime_id: runtime.id,
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })
      |> Repo.insert!()

    lead_role = Chat.Sidebar.agents_leader_role()
    assert {:ok, _} = Platform.Roles.assign_role(lead_role, agent.id)

    # The lead's runtime must be able to call the Goals tools or the start
    # is refused (task 01a1eab6 stage 3): Goals on, the `goals` bundle in the
    # runtime's profile, and its owner a member holding `goals.use`. The
    # grant row is inserted directly (no ledger row to clean up) on a space
    # of the org, all deleted below.
    previous_enabled = Application.fetch_env(:goals, :enabled)
    Application.put_env(:goals, :enabled, true)
    {:ok, _} = Platform.Access.RuntimeProfiles.set_tool_profile(runtime, ["goals"])

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: owner.id, org_id: org.id, role: "member"})
    |> Repo.insert!()

    {:ok, grant_space} =
      Chat.create_space(%{
        name: "Intake grants #{n}",
        slug: "intake-grants-#{n}",
        kind: "channel",
        org_id: org.id
      })

    grant =
      Repo.insert!(%Grant{
        org_id: org.id,
        principal_type: "user",
        principal_id: owner.id,
        permission: "goals.use",
        resource_type: "space",
        resource_id: grant_space.id,
        effect: "allow"
      })

    assert Proposals.check_lead_tools(agent) == :ok

    on_exit(fn ->
      # Runs after the start_supervised router has stopped, still in :auto
      # mode, so these deletes commit on a real connection.
      space_ids =
        Repo.all(
          from(p in Participant,
            where: p.participant_type == "user" and p.participant_id == ^user.id,
            select: p.space_id
          )
        )

      Repo.delete_all(from(p in Proposal, where: p.user_id == ^user.id))
      Repo.delete_all(from(m in Message, where: m.space_id in ^space_ids))
      Repo.delete_all(from(p in Participant, where: p.space_id in ^space_ids))
      Repo.delete_all(from(s in Space, where: s.id in ^space_ids))
      Platform.Roles.unassign_role(lead_role)
      Repo.delete_all(from(g in Grant, where: g.id == ^grant.id))
      Repo.delete_all(from(m in Message, where: m.space_id == ^grant_space.id))
      Repo.delete_all(from(p in Participant, where: p.space_id == ^grant_space.id))
      Repo.delete_all(from(s in Space, where: s.id == ^grant_space.id))
      Repo.delete_all(from(p in RuntimeProfile, where: p.runtime_id == ^runtime.id))

      case previous_enabled do
        {:ok, value} -> Application.put_env(:goals, :enabled, value)
        :error -> Application.delete_env(:goals, :enabled)
      end

      Repo.delete_all(from(a in Agent, where: a.id == ^agent.id))
      Repo.delete_all(from(r in AgentRuntime, where: r.id == ^runtime.id))
      Repo.delete_all(from(m in OrgMembership, where: m.user_id in ^[user.id, owner.id]))
      Repo.delete_all(from(o in Org, where: o.id == ^org.id))
      Repo.delete_all(from(u in User, where: u.id in ^[user.id, owner.id]))

      if previous_mode,
        do: Application.put_env(:platform, :chat_agent_dispatch_mode, previous_mode),
        else: Application.delete_env(:platform, :chat_agent_dispatch_mode)

      case previous_dispatcher do
        {:ok, value} -> Application.put_env(:goals, :wake_up_dispatcher, value)
        :error -> Application.delete_env(:goals, :wake_up_dispatcher)
      end

      Sandbox.mode(Repo, :manual)
    end)

    # An ONLINE runtime, so a router dispatch is an "attention" broadcast on
    # the runtime topic rather than a failure notice posted into the space.
    _presence = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
    RuntimePresence.track(runtime.runtime_id)
    on_exit(fn -> RuntimePresence.untrack(runtime.runtime_id) end)
    topic = "runtime:#{runtime.runtime_id}"
    :ok = PlatformWeb.Endpoint.subscribe(topic)

    refute Process.whereis(AttentionRouter),
           "expected no AttentionRouter running in test (config :start_attention_router)"

    router = start_supervised!({AttentionRouter, []})

    decisions_id = "intake-decisions-#{n}"

    :ok =
      :telemetry.attach_many(
        decisions_id,
        [[:platform, :chat, :attention_routed], [:platform, :chat, :attention_skipped]],
        fn event, _measurements, meta, _ -> send(test_pid, {List.last(event), meta}) end,
        nil
      )

    # Attached AFTER the router's own message_posted handler (the router
    # attaches it when it starts), so it runs second: the router already has
    # the message in its mailbox when this drain is made.
    drain_id = "intake-drain-#{n}"

    :ok =
      :telemetry.attach(
        drain_id,
        [:platform, :chat, :message_posted],
        fn _event, _measurements, _meta, _ ->
          if self() != router, do: GenServer.call(router, :__drain__, 10_000)
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(decisions_id)
      :telemetry.detach(drain_id)
    end)

    %{user: user, agent: agent, router: router, topic: topic}
  end

  defp drain(router), do: :ok = GenServer.call(router, :__drain__, 10_000)

  test "the start is ONE trigger (the signal), never 'not found'; a follow-up is one :directed dispatch",
       %{user: user, agent: agent, router: router, topic: topic} do
    {proposal, log} =
      with_log(fn ->
        assert {:ok, proposal} = Proposals.start_goal_conversation(user, @opening)
        drain(router)
        proposal
      end)

    opening_id = proposal.first_message_id
    space_id = proposal.space_id

    # Exactly one new_goal signal, naming the reply space in metadata.
    assert_received {:signal, signal}
    refute_received {:signal, _}
    assert signal.metadata.responsibility_key == "goals.new_goal"
    assert signal.metadata.space_id == space_id
    refute Map.has_key?(signal, :space_id)
    refute inspect(signal) =~ "ORCHID-LANTERN"

    # Zero router dispatches for the opening message: the router found the
    # committed row and decided nothing.
    refute log =~ "message not found: #{opening_id}"

    assert_received {:attention_skipped, %{message_id: ^opening_id, reason: :caller_suppressed}}

    refute_received {:attention_routed, %{message_id: ^opening_id}}

    refute_received %Phoenix.Socket.Broadcast{
      topic: ^topic,
      event: "attention",
      payload: %{signal: %{message_id: ^opening_id}}
    }

    # The follow-up is an ordinary turn: exactly one :directed dispatch.
    {follow_up, log} =
      with_log(fn ->
        assert {:ok, msg} = Proposals.say_in_conversation(user, proposal.id, "This weekend")
        drain(router)
        msg
      end)

    follow_up_id = follow_up.id
    agent_p_id = Chat.get_agent_participant(space_id, agent.id).id
    refute log =~ "message not found"

    assert_received {:attention_routed,
                     %{message_id: ^follow_up_id, recipient_id: ^agent_p_id, reason: :directed}}

    refute_received {:attention_routed, %{message_id: ^follow_up_id}}

    assert_receive %Phoenix.Socket.Broadcast{
                     topic: ^topic,
                     event: "attention",
                     payload: %{signal: %{message_id: ^follow_up_id}}
                   },
                   2_000

    refute_receive %Phoenix.Socket.Broadcast{
                     topic: ^topic,
                     event: "attention",
                     payload: %{signal: %{message_id: ^follow_up_id}}
                   },
                   300

    refute_received {:signal, _}
  end
end
