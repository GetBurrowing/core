defmodule Platform.Ux.MorningReviewTest do
  @moduledoc """
  `Platform.Ux.MorningReview`: the designer's morning canvas after a cron
  fire, and what an Inbox answer does when the morning review is on (an
  approval files a task, a decline is journaled). Off by default.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Mox

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Chat.Message
  alias Platform.Org.Wiki
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.UxFrictionWatch
  alias Platform.Responsibilities.Router
  alias Platform.Roles
  alias Platform.Roles.Seeds
  alias Platform.Tasks
  alias Platform.Tasks.Task
  alias Platform.TenancyFixtures
  alias Platform.Ux.Decisions
  alias Platform.Ux.Finding
  alias Platform.Ux.MorningReview

  Mox.defmock(Platform.Ux.MorningReviewProviderMock, for: Platform.Agents.Providers.Provider)

  @mock Platform.Ux.MorningReviewProviderMock

  setup :verify_on_exit!

  setup do
    previous = Application.get_env(:platform, :ux_friction_watch_provider)
    Application.put_env(:platform, :ux_friction_watch_provider, @mock)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :ux_friction_watch_provider, previous),
        else: Application.delete_env(:platform, :ux_friction_watch_provider)
    end)

    :ok = Seeds.seed_defaults(only_keys: ["designer"])
    [spec] = UxFrictionWatch.register()
    {:ok, row} = Responsibilities.upsert_by_key(spec)
    TenancyFixtures.root_admin!()

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "loki-#{u()}",
        name: "Loki",
        status: "active",
        kind: "native",
        workspace_id: nil
      })
      |> Repo.insert!()

    {:ok, _} = Roles.assign_role("designer", agent.id)
    {:ok, project} = Tasks.create_project(%{name: "Core #{u()}"})
    sponsor = user!()

    %{row: row, agent: agent, project: project, sponsor: sponsor}
  end

  defp u, do: System.unique_integer([:positive])

  defp user! do
    n = u()

    %User{}
    |> User.changeset(%{email: "mr-#{n}@example.com", name: "Member #{n}", oidc_sub: "mr-#{n}"})
    |> Repo.insert!()
  end

  defp configure!(row, sponsor, project, extra \\ %{}) do
    config =
      (row.trigger_config || %{})
      |> Map.merge(%{
        "escalate_user_id" => sponsor.id,
        "operator_set" => true,
        "morning_review" => true,
        "fix_project_id" => project.id
      })
      |> Map.merge(extra)

    {:ok, row} = Responsibilities.update_responsibility(row, %{trigger_config: config})
    row
  end

  defp finding!(recipient) do
    %Finding{}
    |> Finding.changeset(%{
      recipient_user_id: recipient.id,
      question: "Should direct messages get their own tab?",
      kind: "decision",
      evidence: %{count: 4, spaces: 1, quotes: ["can't find my DMs"], citations: []},
      options: [
        %{
          label: "Add a DMs tab",
          recommended: true,
          detail: "Why: people hunt. Effect: fewer asks."
        },
        %{label: "Pin DMs at the top of the rail", recommended: false}
      ],
      group_key: "dm-findability-#{u()}"
    })
    |> Repo.insert!()
  end

  defp channel_with_friction!(agent) do
    {:ok, space} = Chat.create_space(%{name: "general", slug: "mr-#{u()}", kind: "channel"})

    for {type, id} <- [{"agent", agent.id}, {"user", user!().id}] do
      {:ok, _} =
        Chat.add_participant(space.id, %{
          participant_type: type,
          participant_id: id,
          joined_at: DateTime.utc_now()
        })
    end

    member = Enum.find(Chat.list_participants(space.id), &(&1.participant_type == "user"))

    for i <- 1..3 do
      %Message{}
      |> Message.changeset(%{
        space_id: space.id,
        participant_id: member.id,
        content_type: "text",
        content: "I can't find my direct messages anywhere (#{i})",
        author_display_name: "Member"
      })
      |> Repo.insert!()
    end

    space
  end

  defp expect_group do
    expect(@mock, :chat, fn _credentials, messages, _opts ->
      signals =
        messages |> Enum.find(&(&1.role == "user")) |> Map.fetch!(:content) |> Jason.decode!()

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "groups" => [
               %{
                 "group_key" => "dm-findability",
                 "kind" => "decision",
                 "question" => "Should direct messages get their own tab?",
                 "meaning" => "People lose DMs among channels.",
                 "similarity" => 0.9,
                 "signal_ids" => Enum.map(signals, & &1["id"]),
                 "options" => [
                   %{
                     "label" => "Add a DMs tab",
                     "recommended" => true,
                     "detail" => "Why: three people hunted. Effect: no more asks."
                   }
                 ]
               }
             ]
           })
       }}
    end)
  end

  describe "the morning canvas" do
    test "a cron fire posts ONE canvas in the agent's DM with the escalation human", ctx do
      configure!(ctx.row, ctx.sponsor, ctx.project)
      channel_with_friction!(ctx.agent)
      expect_group()

      assert Router.fire("ux.friction_watch", %{kind: :cron}) == {:ok, :handled}

      assert [finding] = Repo.all(Finding)
      assert finding.evidence["meaning"] == "People lose DMs among channels."

      {:ok, dm} = Chat.find_or_create_agent_dm(ctx.agent.id, ctx.sponsor.id)
      assert [canvas] = Repo.all(from(c in Canvas, where: c.space_id == ^dm.id))
      assert canvas.title =~ ~r/^Loki · \w{3} \d{1,2} \w{3}$/

      body = Jason.encode!(canvas.document)
      assert body =~ "Should direct messages get their own tab?"
      assert body =~ "can't find my direct messages"
      assert body =~ "People lose DMs among channels."
      assert body =~ "Why: three people hunted. Effect: no more asks."
      assert body =~ Decisions.url(finding.id)

      assert Repo.exists?(
               from(m in Message, where: m.space_id == ^dm.id and m.canvas_id == ^canvas.id)
             )
    end

    test "off without morning_review: no canvas", ctx do
      configure!(ctx.row, ctx.sponsor, ctx.project, %{"morning_review" => false})
      channel_with_friction!(ctx.agent)
      expect_group()

      assert Router.fire("ux.friction_watch", %{kind: :cron}) == {:ok, :handled}
      assert [_finding] = Repo.all(Finding)
      assert Repo.all(Canvas) == []
    end

    test "nothing new, nothing posted", ctx do
      assert MorningReview.post(ctx.agent, ctx.sponsor.id, DateTime.utc_now()) ==
               {:skipped, :nothing_new}
    end
  end

  describe "answers" do
    test "Build it files one auto-approved task for the designer and links it", ctx do
      configure!(ctx.row, ctx.sponsor, ctx.project)
      finding = finding!(ctx.sponsor)

      assert {:ok, answered} = Decisions.answer(finding.id, ctx.sponsor.id, "build", "go")
      assert is_binary(answered.task_id)
      assert Repo.reload!(finding).task_id == answered.task_id

      task = Repo.get!(Task, answered.task_id)
      assert task.project_id == ctx.project.id
      assert task.auto_approve_plan
      assert task.title == "UX: Add a DMs tab"
      assert task.sponsor_user_id == ctx.sponsor.id
      assert task.description =~ "Why: people hunt."

      for phase <- ~w(planning execution review) do
        assert task.phase_assignees[phase]["assignee_id"] == ctx.agent.id
      end
    end

    test "Try the other option files the task for that option", ctx do
      configure!(ctx.row, ctx.sponsor, ctx.project)
      finding = finding!(ctx.sponsor)

      assert {:ok, answered} = Decisions.answer(finding.id, ctx.sponsor.id, "other")
      assert Repo.get!(Task, answered.task_id).title == "UX: Pin DMs at the top of the rail"
    end

    test "Not now files no task and journals the reason", ctx do
      configure!(ctx.row, ctx.sponsor, ctx.project)
      finding = finding!(ctx.sponsor)

      assert {:ok, declined} =
               Decisions.answer(finding.id, ctx.sponsor.id, "not_now", "tabs are cluttered")

      assert declined.task_id == nil
      assert Repo.all(Task) == []

      {:ok, dm} = Chat.find_or_create_agent_dm(ctx.agent.id, ctx.sponsor.id)
      path = "space/#{dm.id}/private/#{ctx.agent.id}/journal/#{Date.utc_today()}.md"
      page = Wiki.get_page(path)
      assert page.content =~ "Declined: Should direct messages get their own tab?"
      assert page.content =~ "tabs are cluttered"
    end

    test "with the morning review off an approval files nothing", ctx do
      configure!(ctx.row, ctx.sponsor, ctx.project, %{"morning_review" => false})
      finding = finding!(ctx.sponsor)

      assert {:ok, answered} = Decisions.answer(finding.id, ctx.sponsor.id, "build")
      assert answered.task_id == nil
      assert Repo.all(Task) == []
    end
  end
end
