defmodule Platform.Agents.UnblockAsksTest do
  @moduledoc """
  `Platform.Agents.UnblockAsks`, task 01a1b6de stage 4: one ask per subject
  and class, re-asked only when the state is unchanged AND the interval has
  passed, a changed state updating the ask in place, clearing derived from
  the subject's state, "I did it, check again" re-running the check before
  resolving, and the interval read through the experiment surface and an
  operator value that survives boot re-registration.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Agents.TeamCheck
  alias Platform.Agents.UnblockAsk
  alias Platform.Agents.UnblockAsks
  alias Platform.Experiments
  alias Platform.Experiments.Assignment
  alias Platform.Experiments.SurfaceDefault
  alias Platform.Inbox
  alias Platform.Inbox.Item
  alias Platform.Orchestration.RuntimeEvent
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.AgentsTeamCheck
  alias Platform.Tasks

  @now ~U[2026-11-07 12:00:00.000000Z]
  @refusal "git push failed: remote: Permission to example-org/example-repo.git denied to example-bot. " <>
             "fatal: unable to access: The requested URL returned error: 403"

  setup do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Unblock #{n}"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Unblock #{n}"})
    [spec] = AgentsTeamCheck.register()
    {:ok, row} = Responsibilities.upsert_by_key(spec)
    %{task: task, row: row}
  end

  defp user!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "ua-#{label}-#{n}@example.com",
      name: "Person#{n}",
      oidc_sub: "oidc-ua-#{label}-#{n}"
    })
  end

  defp federated!(sponsor) do
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(%Agent{
        slug: "ua-agent-#{n}",
        name: "Agent#{n}",
        status: "active",
        kind: "native",
        runtime_type: "external"
      })

    runtime =
      Repo.insert!(%AgentRuntime{
        runtime_id: "rt-ua-#{n}",
        agent_id: agent.id,
        owner_user_id: sponsor.id,
        status: "active"
      })

    {agent, runtime}
  end

  defp event!(task, type, runtime_id, payload, at) do
    Repo.insert!(
      RuntimeEvent.changeset(%RuntimeEvent{}, %{
        task_id: task.id,
        phase: "execution",
        runtime_id: runtime_id,
        event_type: type,
        occurred_at: at,
        idempotency_key: "ua-#{System.unique_integer([:positive])}",
        payload: payload
      })
    )
  end

  defp online(agent), do: [%{agent_id: agent.id, online: true, last_seen_at: @now}]

  defp offline(agent),
    do: [%{agent_id: agent.id, online: false, last_seen_at: DateTime.add(@now, -3 * 3600)}]

  defp sync(row, federation, now) do
    [row: row, now: now, federation: federation]
    |> TeamCheck.statuses()
    |> UnblockAsks.sync_agents(row: row, now: now)
  end

  defp asks_for(agent),
    do: Repo.all(from(a in UnblockAsk, where: a.subject_id == ^agent.id, order_by: a.inserted_at))

  defp rows_for(user, ask) do
    Repo.all(
      from(i in Item,
        where:
          i.user_id == ^user.id and i.source_type == "unblock_ask" and i.source_id == ^ask.id,
        order_by: i.inserted_at
      )
    )
  end

  defp listed(rows), do: Enum.filter(rows, &is_nil(&1.dismissed_at))

  defp hours(h), do: DateTime.add(@now, h * 3600, :second)

  describe "one ask per subject and class" do
    test "a 403 on a connected agent asks its sponsor once, in the sponsor's inbox", ctx do
      sponsor = user!("sponsor")
      {agent, runtime} = federated!(sponsor)

      event!(
        ctx.task,
        "execution.blocked",
        runtime.runtime_id,
        %{"description" => @refusal},
        @now
      )

      assert [{:asked, ask, _}] = sync(ctx.row, online(agent), hours(1))
      assert ask.class == "access"
      assert ask.subject_type == "agent"
      assert ask.owner_user_id == sponsor.id
      assert ask.status == "open"
      assert ask.ask_count == 1
      assert ask.details["org"] == "example-org"
      assert ask.details["repo"] == "example-repo"
      assert ask.details["account"] == "example-bot"

      assert [item] = rows_for(sponsor, ask)
      assert item.kind == "agent_unblock_ask"
      assert item.title == "Give #{agent.name} write access so they can save code to your project"
      assert item.url == UnblockAsks.url(ask.id)

      # A second fire straight after: no new ask, no re-ask, no bump.
      assert sync(ctx.row, online(agent), hours(2)) == []
      assert [same] = asks_for(agent)
      assert same.last_asked_at == ask.last_asked_at
      assert same.ask_count == 1
      assert [_] = rows_for(sponsor, ask)
    end

    test "unchanged past the interval re-asks once: one ask, one listed row", ctx do
      sponsor = user!("sponsor")
      {agent, runtime} = federated!(sponsor)

      event!(
        ctx.task,
        "execution.blocked",
        runtime.runtime_id,
        %{"description" => @refusal},
        @now
      )

      [{:asked, ask, _}] = sync(ctx.row, online(agent), hours(1))

      # 71h after the ask: still inside the 72h default.
      assert sync(ctx.row, online(agent), hours(72)) == []

      assert [{:reasked, reasked, _}] = sync(ctx.row, online(agent), hours(73))
      assert reasked.id == ask.id
      assert reasked.ask_count == 2
      assert reasked.last_asked_at == hours(73)
      assert reasked.asked_at == ask.asked_at
      assert [_] = asks_for(agent)
      assert [_live] = listed(rows_for(sponsor, ask))
      assert length(rows_for(sponsor, ask)) == 2
    end

    test "a changed state updates the ask in place and does not re-ask", ctx do
      sponsor = user!("sponsor")
      {agent, runtime} = federated!(sponsor)

      event!(
        ctx.task,
        "execution.blocked",
        runtime.runtime_id,
        %{"description" => @refusal},
        @now
      )

      [{:asked, ask, _}] = sync(ctx.row, online(agent), hours(1))

      event!(
        ctx.task,
        "execution.blocked",
        runtime.runtime_id,
        %{"description" => "remote: Permission to example-org/other.git denied to example-bot. 403"},
        hours(2)
      )

      assert [{:updated, updated, _}] = sync(ctx.row, online(agent), hours(3))
      assert updated.id == ask.id
      assert updated.state_fingerprint != ask.state_fingerprint
      assert updated.details["repo"] == "other"
      assert updated.last_asked_at == ask.last_asked_at
      assert updated.ask_count == 1
      assert [_] = asks_for(agent)
      assert [_] = rows_for(sponsor, ask)
    end

    test "the fingerprint ignores the growing age of an offline agent", ctx do
      sponsor = user!("sponsor")
      {agent, _runtime} = federated!(sponsor)

      assert [{:asked, ask, _}] = sync(ctx.row, offline(agent), hours(1))
      assert ask.class == "offline"
      assert ask.evidence =~ "last seen 4h ago"

      # The evidence line now reads "8h ago"; the state did not change.
      assert sync(ctx.row, offline(agent), hours(5)) == []
      assert [same] = asks_for(agent)
      assert same.state_fingerprint == ask.state_fingerprint
    end

    test "an offline agent with a 403 on record gets an offline ask, never an access ask", ctx do
      sponsor = user!("sponsor")
      {agent, runtime} = federated!(sponsor)

      event!(
        ctx.task,
        "execution.blocked",
        runtime.runtime_id,
        %{"description" => @refusal},
        @now
      )

      assert [{:asked, %{class: "offline"}, _}] = sync(ctx.row, offline(agent), hours(1))
      refute Enum.any?(asks_for(agent), &(&1.class == "access"))
    end
  end

  describe "the table keeps one live ask per subject and class" do
    test "a second live ask is refused; a resolved one leaves room for a new episode" do
      owner = user!("owner")
      first = ask!(owner, "access")

      dup =
        UnblockAsk.changeset(%UnblockAsk{}, %{
          subject_type: "agent",
          subject_id: first.subject_id,
          class: "access",
          state_fingerprint: "fp2",
          owner_user_id: owner.id,
          status: "open",
          asked_at: @now,
          last_asked_at: @now
        })

      assert {:error, changeset} = Repo.insert(dup)
      assert {_, [constraint: :unique, constraint_name: _]} = changeset.errors[:subject_type]

      Repo.update!(Ecto.Changeset.change(first, status: "resolved"))
      assert {:ok, _} = Repo.insert(dup)
    end
  end

  describe "clearing is derived from the subject's state" do
    test "execution.unblocked resolves the ask and clears its row", ctx do
      sponsor = user!("sponsor")
      {agent, runtime} = federated!(sponsor)

      event!(
        ctx.task,
        "execution.blocked",
        runtime.runtime_id,
        %{"description" => @refusal},
        @now
      )

      [{:asked, ask, _}] = sync(ctx.row, online(agent), hours(1))

      event!(ctx.task, "execution.unblocked", runtime.runtime_id, %{}, hours(2))

      assert [{:resolved, resolved, _}] = sync(ctx.row, online(agent), hours(3))
      assert resolved.id == ask.id
      assert resolved.status == "resolved"
      assert resolved.resolved_at == hours(3)
      assert listed(rows_for(sponsor, ask)) == []
    end

    test "going offline does not resolve a live access ask", ctx do
      sponsor = user!("sponsor")
      {agent, runtime} = federated!(sponsor)

      event!(
        ctx.task,
        "execution.blocked",
        runtime.runtime_id,
        %{"description" => @refusal},
        @now
      )

      [{:asked, access, _}] = sync(ctx.row, online(agent), hours(1))

      sync(ctx.row, offline(agent), hours(2))
      assert Repo.get!(UnblockAsk, access.id).status == "open"
    end

    test "coming back online resolves the offline ask", ctx do
      sponsor = user!("sponsor")
      {agent, _runtime} = federated!(sponsor)
      [{:asked, ask, _}] = sync(ctx.row, offline(agent), hours(1))

      assert [{:resolved, %{id: id}, _}] = sync(ctx.row, online(agent), hours(2))
      assert id == ask.id
    end

    test "the inbox reconciler dismisses a resolved ask's row" do
      sponsor = user!("sponsor")
      ask = ask!(sponsor, "access")
      {:ok, item} = emit!(sponsor, ask)

      Repo.update!(Ecto.Changeset.change(ask, status: "resolved"))
      Inbox.reconcile_for_user(sponsor.id)
      assert Repo.get!(Item, item.id).dismissed_at
    end

    test "the inbox reconciler leaves an open ask's row listed" do
      sponsor = user!("sponsor")
      ask = ask!(sponsor, "access")
      {:ok, item} = emit!(sponsor, ask)

      Inbox.reconcile_for_user(sponsor.id)
      refute Repo.get!(Item, item.id).dismissed_at
    end
  end

  describe "I did it, check again" do
    test "with the state NOT fixed it reopens the ask and says what is missing", ctx do
      sponsor = user!("sponsor")
      {agent, runtime} = federated!(sponsor)

      event!(
        ctx.task,
        "execution.blocked",
        runtime.runtime_id,
        %{"description" => @refusal},
        @now
      )

      [{:asked, ask, _}] = sync(ctx.row, online(agent), hours(1))

      assert {:ok, %{outcome: :still_missing, ask: open, message: message}} =
               UnblockAsks.check_again(ask.id, sponsor.id,
                 row: ctx.row,
                 now: hours(2),
                 federation: online(agent)
               )

      assert open.status == "open"
      assert message =~ "#{agent.name} still can't save changes to your project."
      assert message =~ "403"
      assert open.still_missing == message
      assert [_] = listed(rows_for(sponsor, ask))
    end

    test "with the state fixed it resolves with the success line", ctx do
      sponsor = user!("sponsor")
      {agent, runtime} = federated!(sponsor)

      event!(
        ctx.task,
        "execution.blocked",
        runtime.runtime_id,
        %{"description" => @refusal},
        @now
      )

      [{:asked, ask, _}] = sync(ctx.row, online(agent), hours(1))
      event!(ctx.task, "execution.unblocked", runtime.runtime_id, %{}, hours(2))

      assert {:ok, %{outcome: :resolved, ask: resolved, message: message}} =
               UnblockAsks.check_again(ask.id, sponsor.id,
                 row: ctx.row,
                 now: hours(3),
                 federation: online(agent)
               )

      assert resolved.status == "resolved"
      assert message == "Unblocked. #{agent.name} can save changes to your project now."
      assert listed(rows_for(sponsor, ask)) == []
    end

    test "begin_check sets verifying, resolves nothing, and asks the owning runtime", ctx do
      sponsor = user!("sponsor")
      {agent, runtime} = federated!(sponsor)

      event!(
        ctx.task,
        "execution.blocked",
        runtime.runtime_id,
        %{"description" => @refusal},
        @now
      )

      [{:asked, ask, _}] = sync(ctx.row, online(agent), hours(1))

      PlatformWeb.Endpoint.subscribe("runtime:#{runtime.runtime_id}")
      Phoenix.PubSub.subscribe(Platform.PubSub, UnblockAsks.topic(sponsor.id))

      assert {:ok, verifying} =
               UnblockAsks.begin_check(ask.id, sponsor.id,
                 row: ctx.row,
                 now: hours(2),
                 federation: online(agent)
               )

      assert verifying.status == "verifying"
      assert Repo.get!(UnblockAsk, ask.id).status == "verifying"

      assert_receive %Phoenix.Socket.Broadcast{
        event: "unblock_check_requested",
        payload: %{ask_id: ask_id, class: "access"}
      }

      assert ask_id == ask.id
      assert_receive {:unblock_ask_changed, %UnblockAsk{status: "verifying"}}
    end

    test "only the ask's fixer may check it", ctx do
      sponsor = user!("sponsor")
      stranger = user!("stranger")
      {agent, runtime} = federated!(sponsor)

      event!(
        ctx.task,
        "execution.blocked",
        runtime.runtime_id,
        %{"description" => @refusal},
        @now
      )

      [{:asked, ask, _}] = sync(ctx.row, online(agent), hours(1))

      assert {:error, :not_found} = UnblockAsks.check_again(ask.id, stranger.id, row: ctx.row)
      assert {:error, :not_found} = UnblockAsks.check_again("not-a-uuid", sponsor.id)
      assert Repo.get!(UnblockAsk, ask.id).status == "open"
    end

    test "a resolved ask cannot be checked again" do
      sponsor = user!("sponsor")
      ask = ask!(sponsor, "access", status: "resolved")
      assert {:error, :already_resolved} = UnblockAsks.check_again(ask.id, sponsor.id)
    end
  end

  describe "Not now" do
    test "puts the ask off and clears its row; the interval brings it back", ctx do
      sponsor = user!("sponsor")
      {agent, runtime} = federated!(sponsor)

      event!(
        ctx.task,
        "execution.blocked",
        runtime.runtime_id,
        %{"description" => @refusal},
        @now
      )

      [{:asked, ask, _}] = sync(ctx.row, online(agent), hours(1))

      assert {:ok, %{status: "dismissed"}} = UnblockAsks.not_now(ask.id, sponsor.id)
      assert listed(rows_for(sponsor, ask)) == []
      assert UnblockAsks.inbox_row_stale?(ask.id)

      assert sync(ctx.row, online(agent), hours(10)) == []
      assert [{:reasked, %{status: "open"}, _}] = sync(ctx.row, online(agent), hours(80))
      assert [_] = listed(rows_for(sponsor, ask))
      assert {:error, :not_found} = UnblockAsks.not_now(ask.id, user!("other").id)
    end
  end

  describe "stuck people" do
    test "a stuck person is asked in their own inbox, and resolved once not stuck" do
      person = user!("member")

      {:ok, login} =
        Platform.Audit.record(%{
          event_type: "platform.auth.external_admission",
          actor_id: person.id,
          actor_type: "user",
          action: "full",
          resource_type: "session",
          resource_id: person.id
        })

      later = DateTime.add(login.inserted_at, 2 * 3600, :second)
      opts = [users: [person], stuck_after_seconds: 3600]

      assert [{:asked, ask, _}] = UnblockAsks.sync_people([now: later] ++ opts)
      assert ask.subject_type == "person"
      assert ask.class == "person_setup"
      assert ask.owner_user_id == person.id
      assert "notifications" in ask.details["steps"]
      assert [item] = listed(rows_for(person, ask))
      assert item.title == "Finish setting up so your team can reach you"

      assert UnblockAsks.sync_people([now: DateTime.add(later, 60)] ++ opts) == []

      assert {:ok, %{outcome: :still_missing, message: message}} =
               UnblockAsks.check_again(ask.id, person.id,
                 now: DateTime.add(later, 120),
                 stuck_after_seconds: 3600
               )

      assert message =~ "Turn on notifications"

      # Nothing is stuck once the threshold is unset.
      assert [{:resolved, %{id: id}, _}] =
               UnblockAsks.sync_people(
                 users: [person],
                 now: DateTime.add(later, 180),
                 stuck_after_seconds: nil
               )

      assert id == ask.id
    end
  end

  describe "the interval is data" do
    test "the default is the configured 72h", %{row: row} do
      assert UnblockAsks.interval_for(Ecto.UUID.generate(), row) == {72, nil}
    end

    test "an operator-set interval survives a boot re-registration", %{row: row} do
      assert {:ok, _} =
               Responsibilities.put_operator_config("agents.team_check", %{
                 "reask_after_hours" => 5
               })

      [spec] = AgentsTeamCheck.register()
      {:ok, reregistered} = Responsibilities.upsert_by_key(spec)

      assert reregistered.id == row.id
      assert reregistered.metadata["operator_config"] == %{"reask_after_hours" => 5}
      assert reregistered.metadata["owner"] == "platform.agents"
      assert TeamCheck.reask_after_hours(reregistered) == 5
      assert UnblockAsks.interval_for(Ecto.UUID.generate(), reregistered) == {5, nil}

      # The declared part of metadata is still replaced on boot.
      {:ok, _} =
        Responsibilities.update_responsibility(reregistered, %{
          metadata: Map.put(reregistered.metadata, "owner", "someone.else")
        })

      {:ok, again} = Responsibilities.upsert_by_key(spec)
      assert again.metadata["owner"] == "platform.agents"
      assert again.metadata["operator_config"] == %{"reask_after_hours" => 5}
    end

    test "a promoted surface default wins over the operator value", %{row: row} do
      {:ok, row} = Responsibilities.put_operator_config(row.key, %{"reask_after_hours" => 5})
      promote!(%{"reask_after_hours" => 24})
      assert UnblockAsks.interval_for(Ecto.UUID.generate(), row) == {24, nil}
    end

    test "a running arm decides its subject's interval and is recorded on the ask", ctx do
      sponsor = user!("sponsor")
      {agent, runtime} = federated!(sponsor)

      event!(
        ctx.task,
        "execution.blocked",
        runtime.runtime_id,
        %{"description" => @refusal},
        @now
      )

      {:ok, experiment} =
        Experiments.create_experiment(%{
          slug: "ua-#{System.unique_integer([:positive])}",
          name: "Reask",
          status: "draft",
          surface_key: "agents.unblock_ask.reask_interval",
          surface_target: "agents.unblock_ask.reask_interval"
        })

      {:ok, _} =
        Experiments.add_variant(experiment, %{
          slug: "short",
          content: "short",
          weight: 1,
          payload: %{"reask_after_hours" => 2}
        })

      Repo.insert!(%Assignment{
        experiment_id: experiment.id,
        subject_type: "unblock_subject",
        subject_id: agent.id,
        variant_slug: "short",
        assigned_at: DateTime.utc_now()
      })

      assert UnblockAsks.interval_for(agent.id, ctx.row) == {2, "short"}

      [{:asked, ask, _}] = sync(ctx.row, online(agent), hours(1))
      assert ask.variant == "short"
      assert ask.reask_after_hours == 2

      assert sync(ctx.row, online(agent), DateTime.add(hours(3), -1, :second)) == []
      assert [{:reasked, _, _}] = sync(ctx.row, online(agent), hours(3))
    end
  end

  describe "the team check fire" do
    test "raises the agent once with a link to its ask, then not inside the interval", ctx do
      sponsor = user!("sponsor")
      {agent, runtime} = federated!(sponsor)

      event!(
        ctx.task,
        "execution.blocked",
        runtime.runtime_id,
        %{"description" => @refusal},
        @now
      )

      first =
        AgentsTeamCheck.build_context(ctx.row, hours(1), federation: online(agent), users: [])

      assert [%{agent_id: agent_id, url: url}] = first.raise
      assert agent_id == agent.id
      assert {:ok, %{user: prompt}} = AgentsTeamCheck.build_prompt(first)
      assert prompt =~ url
      assert prompt =~ sponsor.name

      second =
        AgentsTeamCheck.build_context(ctx.row, hours(2), federation: online(agent), users: [])

      assert second.raise == []
      assert {:error, {:nothing_to_raise, _}} = AgentsTeamCheck.build_prompt(second)
    end
  end

  defp ask!(owner, class, overrides \\ []) do
    Repo.insert!(
      struct(
        %UnblockAsk{
          subject_type: "agent",
          subject_id: Ecto.UUID.generate(),
          class: class,
          state_fingerprint: "fp",
          owner_user_id: owner.id,
          status: "open",
          details: %{"agent" => "{agent}"},
          asked_at: @now,
          last_asked_at: @now
        },
        overrides
      )
    )
  end

  defp emit!(owner, ask) do
    Inbox.emit(%{
      user_id: owner.id,
      kind: "agent_unblock_ask",
      source_type: "unblock_ask",
      source_id: ask.id,
      title: "t",
      url: UnblockAsks.url(ask.id)
    })
  end

  defp promote!(payload) do
    %SurfaceDefault{}
    |> SurfaceDefault.changeset(%{
      surface_key: "agents.unblock_ask.reask_interval",
      surface_target: "agents.unblock_ask.reask_interval",
      seq: System.unique_integer([:positive]),
      kind: "promote",
      payload: payload
    })
    |> Repo.insert!()
  end
end
