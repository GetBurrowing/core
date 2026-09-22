defmodule Platform.Federation.MentionDispatchReachTest do
  @moduledoc """
  Task 01a0ac64-a959-7001-9ca2-e429535a1bb2 stage 3 — the ROUTING half.

  Membership and delivery have different lifetimes: once a participant row
  exists, later dispatches are delivered with no new add. Stages 1-2 closed the
  add and the history read. A fix that only closed membership would still pass a
  test that asked "did a row appear", so the assertion here is about **reach**:
  who actually received a dispatch for this space in this run.

  ## Why the criterion is not "the cited agent receives no dispatch"

  That assertion is an absorber — it passes identically whether routing was
  fixed or the dispatch was simply never recorded, and nothing in
  `runtime_event_list` can tell those apart. So each test asserts BOTH halves in
  ONE run:

    * the assignee's `[:platform, :chat, :dispatch_auto_invite]` event IS
      present — a positive control, so a silently broken apparatus (telemetry
      never attached, funnel never called) reads as a failure rather than a
      pass; AND
    * NO invite event carries a non-assignee `agent_id` for that `space_id`.

  ## What is real here and what is glue

  Two real seams are driven: `AttentionRouter.route/1` decides who hears the
  message, and `AttentionDispatch.broadcast/3` is the one funnel every attention
  dispatch goes through (it is what `Chat.AgentResponder` calls). The loop that
  carries a routing decision into the funnel is test glue, because the real
  carrier additionally requires a connected runtime in `RuntimePresence`. The
  glue is deliberately indiscriminate — it dispatches whatever routing named,
  with no filtering of its own — so if routing named the wrong agent the funnel
  emits that agent's invite and the test fails.

  The bracketed tokens below are fixtures exercising the mention parser. They
  are the defect under repair and must never appear in a posted message.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.ActiveAgentStore
  alias Platform.Chat.AttentionRouter
  alias Platform.Chat.Participant
  alias Platform.Federation.AttentionDispatch
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks

  @invite_event [:platform, :chat, :dispatch_auto_invite]

  defmodule StubAgentChat do
    def chat(message, _opts), do: {:ok, %{content: "ack: #{message}", model: "stub", usage: %{}}}
  end

  setup do
    previous_module = Application.get_env(:platform, :chat_agent_module)
    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
    Application.put_env(:platform, :chat_agent_module, StubAgentChat)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)

    on_exit(fn ->
      Application.put_env(:platform, :chat_agent_module, previous_module)
      Application.put_env(:platform, :chat_agent_dispatch_mode, previous_mode)
    end)

    router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
    Sandbox.allow(Repo, self(), router)

    store = Process.whereis(ActiveAgentStore) || start_supervised!({ActiveAgentStore, []})
    Sandbox.allow(Repo, self(), store)

    :ok
  end

  # ── Builders ───────────────────────────────────────────────────────────────

  defp agent!(name) do
    n = System.unique_integer([:positive])

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "reach-#{String.downcase(name)}-#{n}",
        name: "#{name} #{n}",
        status: "active",
        max_concurrent: 1,
        sandbox_mode: "off",
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })
      |> Repo.insert()

    agent
  end

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "Reach User #{n}",
      email: "reach-#{n}@example.com",
      oidc_sub: "reach-sub-#{n}"
    })
  end

  defp user_participant!(space_id, role) do
    user = user!()

    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        role: role,
        joined_at: DateTime.utc_now()
      })

    p
  end

  # An execution space whose task is assigned to `assignee`.
  defp execution_space!(assignee) do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Reach project #{n}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Reach task #{n}",
        status: "in_progress",
        assignee_id: assignee.id,
        assignee_type: "agent"
      })

    {:ok, space} = ExecutionSpace.find_or_create(task.id)
    {space, task}
  end

  defp attach_invite_telemetry do
    ref = make_ref()
    pid = self()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      @invite_event,
      fn _event, _measurements, metadata, _cfg ->
        send(pid, {:auto_invite, ref, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  defp agent_rows(space_id, agent_id) do
    Repo.all(
      from(p in Participant,
        where:
          p.space_id == ^space_id and p.participant_type == "agent" and
            p.participant_id == ^agent_id
      )
    )
  end

  # The glue: carry every routing decision into the real dispatch funnel,
  # unfiltered. Returns the agent ids it dispatched for.
  defp dispatch_all(space_id, decisions) do
    Enum.map(decisions, fn %{participant_id: participant_id} ->
      %Participant{participant_id: agent_id} = Repo.get!(Participant, participant_id)

      :ok =
        AttentionDispatch.broadcast(
          "reach-runtime-#{System.unique_integer([:positive])}",
          %{signal: %{reason: "reach_probe"}},
          space_id: space_id,
          agent_id: agent_id,
          source: :agent_responder
        )

      agent_id
    end)
  end

  # Drain the invite mailbox for `space_id` and return the agent ids seen.
  defp invited_agent_ids(ref, space_id) do
    collect(ref, space_id, [])
  end

  defp collect(ref, space_id, acc) do
    receive do
      {:auto_invite, ^ref, %{space_id: ^space_id, agent_id: agent_id}} ->
        collect(ref, space_id, [agent_id | acc])

      {:auto_invite, ^ref, _other_space} ->
        collect(ref, space_id, acc)
    after
      300 -> Enum.reverse(acc)
    end
  end

  # ── Acceptance ─────────────────────────────────────────────────────────────

  describe "an unauthorized bracketed mention in an execution space reaches only the assignee" do
    test "the assignee's invite event is present AND no non-assignee is invited for that space" do
      ref = attach_invite_telemetry()

      assignee = agent!("Assignee")
      cited = agent!("Cited")
      {space, _task} = execution_space!(assignee)

      # A plain member, not an admin of the space and not the task sponsor:
      # exactly the author the stage-1 gate refuses.
      author = user_participant!(space.id, "member")

      {:ok, message} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "can you take a look @[" <> cited.slug <> "]"
        })

      # Membership half (stage 1): the citation created no row.
      assert agent_rows(space.id, cited.id) == []

      # Routing half (this stage): the mention names nobody routable, so the
      # execution assignee fallback is what answers.
      assert {:ok, decisions} = AttentionRouter.route(message)
      assert decisions != []

      dispatched = dispatch_all(space.id, decisions)
      invited = invited_agent_ids(ref, space.id)

      # Positive control, same run: if the funnel or the handler were broken,
      # this fails rather than the run reading as a clean pass.
      assert assignee.id in invited,
             "assignee #{assignee.id} was not invited; invited=#{inspect(invited)} dispatched=#{inspect(dispatched)}"

      # The criterion: nobody but the assignee got a dispatch for this space.
      assert Enum.uniq(invited) == [assignee.id],
             "a non-assignee was dispatched for this space: #{inspect(invited)}"

      refute cited.id in invited
    end
  end

  # ── Removal (ADR-0038 dismissal is a hard delete, no tombstone) ────────────

  describe "a removed agent is not resurrected by an unauthorized citation" do
    test "hard-deleting the participant row and then citing the agent leaves no row" do
      assignee = agent!("Assignee")
      {space, _task} = execution_space!(assignee)
      removed = agent!("Removed")

      {:ok, participant} = Chat.add_agent_participant(space.id, removed)
      assert [_] = agent_rows(space.id, removed.id)

      # Dismissal: a hard delete with nothing left behind to consult.
      {:ok, _} = Chat.remove_participant(participant)
      assert agent_rows(space.id, removed.id) == []

      author = user_participant!(space.id, "member")

      {:ok, message} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "@[" <> removed.slug <> "] are you still on this?"
        })

      assert message.id
      # This is the 2026-09-20 scenario verbatim: before stage 1 the citation
      # re-added the row a human had just deleted.
      assert agent_rows(space.id, removed.id) == []

      # And the dismissed agent is not routed to either — a row-count assertion
      # alone would pass against a router that dispatched to a participant-less
      # agent.
      assert {:ok, decisions} = AttentionRouter.route(message)

      routed_agent_ids =
        Enum.map(decisions, fn %{participant_id: pid} ->
          Repo.get!(Participant, pid).participant_id
        end)

      refute removed.id in routed_agent_ids
    end
  end
end
