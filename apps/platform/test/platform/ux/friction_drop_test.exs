defmodule Platform.Ux.FrictionDropTest do
  @moduledoc """
  `Platform.Ux.FrictionDrop`: the post-ship friction drop (task 01a1f048).
  Counts are asserted against posts placed on each side of the ship time,
  with controls that must NOT count (another topic, no friction phrase,
  another space, outside both windows).
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Experiments.Metrics
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.PhaseTransition
  alias Platform.Ux.Finding
  alias Platform.Ux.FrictionDrop

  @now ~U[2026-11-18 12:00:00.000000Z]
  @shipped ~U[2026-10-01 12:00:00.000000Z]

  setup do
    user = Platform.ExternalUserFixtures.create_user!()
    space = space!()
    other = space!()
    member = join!(space, user.id)
    other_member = join!(other, user.id)
    %{user: user, space: space, other: other, member: member, other_member: other_member}
  end

  defp space! do
    n = System.unique_integer([:positive])
    {:ok, space} = Chat.create_space(%{name: "fd-#{n}", slug: "fd-#{n}", kind: "channel"})
    space
  end

  defp join!(space, user_id) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user_id,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp post!(space, participant, content, days_from_ship) do
    at = DateTime.add(@shipped, days_from_ship * 86_400, :second)

    %Message{}
    |> Message.changeset(%{
      space_id: space.id,
      participant_id: participant.id,
      content_type: "text",
      content: content,
      author_display_name: "Member"
    })
    |> Ecto.Changeset.force_change(:inserted_at, at)
    |> Repo.insert!()
  end

  defp shipped_task!(shipped_at \\ @shipped) do
    {:ok, project} = Tasks.create_project(%{name: "FD #{System.unique_integer([:positive])}"})

    task =
      Repo.insert!(
        Ecto.Changeset.change(%Platform.Tasks.Task{}, %{
          project_id: project.id,
          title: "Give direct messages their own tab",
          status: "done",
          inserted_at: DateTime.add(shipped_at, -40, :day),
          updated_at: @now
        })
      )

    Repo.insert!(%PhaseTransition{
      task_id: task.id,
      from_status: "in_progress",
      to_status: "done",
      occurred_at: shipped_at,
      actor_kind: "system"
    })

    task
  end

  defp finding!(user, space, task, msg) do
    %Finding{}
    |> Finding.changeset(%{
      recipient_user_id: user.id,
      question: "Should direct messages get their own sidebar tab?",
      kind: "decision",
      group_key: "dm-findability-#{System.unique_integer([:positive])}",
      task_id: task && task.id,
      evidence: %{
        "count" => 1,
        "quotes" => ["I can't find my direct messages in the sidebar"],
        "citations" => [Finding.citation(space.id, msg.id)]
      },
      options: [%{"label" => "Add a tab", "recommended" => true}]
    })
    |> Repo.insert!()
  end

  test "counts the same friction before and after the ship, and nothing else", ctx do
    %{user: user, space: space, other: other, member: m, other_member: om} = ctx

    first = post!(space, m, "I can't find my direct messages in the sidebar", -20)
    post!(space, m, "where are my direct messages? the sidebar hides them", -10)
    post!(space, m, "how do I get to direct messages from the sidebar", -3)
    post!(space, m, "where is the sidebar tab for direct messages now", 5)

    # Controls: no friction phrase; another topic; another space; outside both windows.
    post!(space, m, "direct messages in the sidebar look great", 6)
    post!(space, m, "how do I export a calendar invite", 7)
    post!(other, om, "I can't find my direct messages in the sidebar", 8)
    post!(space, m, "I can't find my direct messages in the sidebar", -40)

    task = shipped_task!()
    finding = finding!(user, space, task, first)

    summary = FrictionDrop.summary(now: @now)
    assert [outcome] = summary.outcomes
    assert outcome.finding_id == finding.id
    assert outcome.before == 3
    assert outcome.after == 1
    assert_in_delta summary.value, 1 - 1 / 3, 0.0001
    assert summary.n == 1
    assert summary.pending == 0

    assert [%{before: 3, after: 1}] = FrictionDrop.for_task(task.id, now: @now)
  end

  test "a card used by a shipped fix gains weight from the drop, once", ctx do
    %{user: user, space: space, member: m} = ctx
    first = post!(space, m, "I can't find my direct messages in the sidebar", -20)
    post!(space, m, "where are my direct messages? the sidebar hides them", -10)
    task = shipped_task!()
    finding!(user, space, task, first)

    agent =
      %Platform.Agents.Agent{}
      |> Platform.Agents.Agent.changeset(%{
        slug: "cards-#{System.unique_integer([:positive])}",
        name: "UX",
        status: "active",
        kind: "native",
        metadata: %{Platform.Designer.Cards.home_key() => space.id}
      })
      |> Repo.insert!()

    path = Platform.Designer.Cards.prefix(agent) <> "dm-tab.md"

    {:ok, _} =
      Platform.Org.Wiki.upsert_page(path, %{
        content: """
        ---
        title: "DM tab"
        status: untested
        weight: 0.4
        used_in_tasks: ["#{task.id}"]
        weighed_tasks: []
        ---
        # DM tab
        """
      })

    assert {:ok, [move]} = Platform.Designer.Cards.reweigh(agent, now: @now)
    assert move.drop == 1.0
    assert move.from == 0.4
    assert move.to == 0.5

    page = Platform.Org.Wiki.get_page(path)
    assert page.frontmatter["weight"] == 0.5
    assert page.frontmatter["status"] == "tested"
    assert page.frontmatter["weighed_tasks"] == [task.id]
    assert page.content =~ "## Weight log"

    assert {:ok, []} = Platform.Designer.Cards.reweigh(agent, now: @now)
  end

  test "a ship still inside its after-window is pending, never a drop", ctx do
    %{user: user, space: space, member: m} = ctx
    msg = post!(space, m, "I can't find my direct messages in the sidebar", -2)
    task = shipped_task!(DateTime.add(@now, -5, :day))
    finding!(user, space, task, msg)

    summary = FrictionDrop.summary(now: @now)
    assert summary.pending == 1
    assert summary.value == nil
    assert summary.outcomes == []
    assert FrictionDrop.for_task(task.id, now: @now) == []
  end

  test "a finding whose task is not done does not count", ctx do
    %{user: user, space: space, member: m} = ctx
    msg = post!(space, m, "I can't find my direct messages in the sidebar", -2)
    task = shipped_task!()
    task |> Ecto.Changeset.change(status: "in_progress") |> Repo.update!()
    finding!(user, space, task, msg)

    assert %{value: nil, n: 0, pending: 0, outcomes: []} = FrictionDrop.summary(now: @now)
  end

  test "is a registered metric slug" do
    assert Metrics.metric_module("ux_friction_drop") ==
             Platform.Experiments.Metrics.UxFrictionDrop
  end

  test "recurrence needs the friction phrase AND shared terms" do
    terms = ["direct", "messages", "sidebar"]
    assert FrictionDrop.recurrence?("I can't find direct messages in the sidebar", terms)
    refute FrictionDrop.recurrence?("Direct messages in the sidebar are lovely", terms)
    refute FrictionDrop.recurrence?("I can't find the calendar export", terms)
  end
end
