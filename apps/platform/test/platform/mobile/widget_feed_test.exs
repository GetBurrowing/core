defmodule Platform.Mobile.WidgetFeedTest do
  @moduledoc """
  Task 01a21e75 stage 1: `Platform.Mobile.WidgetFeed.for_user/2`, the read
  behind `GET /api/app/widgets` (Waiting on you, Blocked for you, Recent,
  Shipped today).

  Messages are inserted as rows, not posted, so no posting side effect (read
  cursors, mention sweeps) can be what excludes a row: the rule under test is.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.ExternalUserFixtures

  alias Platform.Agents.Agent
  alias Platform.Chat.{Message, Participant}
  alias Platform.Inbox
  alias Platform.Inbox.Item
  alias Platform.Mobile.WidgetFeed
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PhaseTransition, Task}

  # ── fixtures ───────────────────────────────────────────────────────────

  defp agent! do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "widget-agent-#{n}", name: "Build agent #{n}", status: "active"})
  end

  # A channel holding `user` and an agent; returns the participant rows.
  defp conversation!(user) do
    space = channel!()
    me = add_user!(space.id, user.id)
    agent = agent!()
    bot = add_agent!(space.id, agent.id)
    %{space: space, me: me, agent: agent, bot: bot}
  end

  defp message!(space, participant, content, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Message{
          space_id: space.id,
          participant_id: participant.id,
          content_type: "text",
          content: content
        },
        attrs
      )
    )
  end

  defp agent_message!(%{space: space, bot: bot, agent: agent}, content, attrs \\ %{}) do
    message!(
      space,
      bot,
      content,
      Map.merge(
        %{
          author_participant_type: "agent",
          author_agent_id: agent.id,
          author_display_name: "Build agent"
        },
        attrs
      )
    )
  end

  defp mention!(user, message) do
    {:ok, item} =
      Inbox.emit(%{
        user_id: user.id,
        kind: "chat_mention",
        source_type: "chat_message",
        source_id: message.id,
        title: "Mentioned",
        url: "/chat"
      })

    item
  end

  defp org_project!(user) do
    org = Platform.Tenancy.get_org_by_slug!("globex")
    plain_member!(user, org)

    {:ok, project} =
      Tasks.create_project(%{
        name: "Widgets #{System.unique_integer([:positive])}",
        org_id: org.id
      })

    project
  end

  defp hidden_project! do
    org = Platform.Tenancy.get_org_by_slug!("initech")

    {:ok, project} =
      Tasks.create_project(%{
        name: "Hidden #{System.unique_integer([:positive])}",
        org_id: org.id
      })

    project
  end

  defp task!(project, attrs) do
    Repo.insert!(
      struct(%Task{project_id: project.id, title: "Task #{System.unique_integer()}"}, attrs)
    )
  end

  defp done_at!(task, at) do
    Repo.insert!(%PhaseTransition{
      task_id: task.id,
      from_status: "in_progress",
      to_status: "done",
      occurred_at: at,
      actor_kind: "system"
    })
  end

  # ── waiting ────────────────────────────────────────────────────────────

  describe "waiting" do
    test "empty: no mentions gives count 0 and no rows" do
      user = create_user!()
      assert %{waiting: %{count: 0, rows: []}} = WidgetFeed.for_user(user)
    end

    test "some: an unanswered agent mention is a row with asker, summary, time and path" do
      user = create_user!()
      c = conversation!(user)
      msg = agent_message!(c, "Can you approve the release note?")
      item = mention!(user, msg)

      assert %{waiting: %{count: 1, rows: [row]}} = WidgetFeed.for_user(user)

      assert row.item_id == item.id
      assert row.asker == "Build agent"
      assert row.summary == "Can you approve the release note?"
      assert row.space_path_segment == Platform.Chat.space_path_segment(c.space)
      assert %DateTime{} = row.at
      refute Map.has_key?(row, :content)
    end

    test "many: the count is every row, rows cap at 5, newest first" do
      user = create_user!()
      c = conversation!(user)
      msgs = for i <- 1..7, do: agent_message!(c, "Question #{i}")
      for m <- msgs, do: mention!(user, m)

      assert %{waiting: %{count: 7, rows: rows}} = WidgetFeed.for_user(user)
      assert Enum.map(rows, & &1.summary) == for(i <- 7..3//-1, do: "Question #{i}")
    end

    test "a mention the user answered later in the same space is excluded" do
      user = create_user!()
      c = conversation!(user)
      answered = agent_message!(c, "Answered question")
      answered_item = mention!(user, answered)
      _reply = message!(c.space, c.me, "Done")
      open = agent_message!(c, "Still open")
      mention!(user, open)

      # Precondition: the answered row is still listed (undismissed), so its
      # absence below is the answered rule's work, not a dismissal's.
      assert Repo.get!(Item, answered_item.id).dismissed_at == nil

      assert %{waiting: %{count: 1, rows: [row]}} = WidgetFeed.for_user(user)
      assert row.summary == "Still open"
    end

    test "a reply in ANOTHER space does not answer the mention" do
      user = create_user!()
      c = conversation!(user)
      other = conversation!(user)
      mention!(user, agent_message!(c, "Here"))
      message!(other.space, other.me, "Elsewhere")

      assert %{waiting: %{count: 1}} = WidgetFeed.for_user(user)
    end

    test "an opened but unanswered mention still counts" do
      user = create_user!()
      c = conversation!(user)
      item = mention!(user, agent_message!(c, "Opened"))
      {:ok, _} = Inbox.mark_read(item.id, user.id)

      assert %{waiting: %{count: 1}} = WidgetFeed.for_user(user)
    end

    test "a human-authored mention is excluded" do
      user = create_user!()
      c = conversation!(user)
      human = create_user!()
      hp = add_user!(c.space.id, human.id)

      msg =
        message!(c.space, hp, "From a person", %{
          author_participant_type: "user",
          author_user_id: human.id,
          author_display_name: "Test Person"
        })

      mention!(user, msg)

      assert %{waiting: %{count: 0, rows: []}} = WidgetFeed.for_user(user)
    end

    test "another user's mention and a dismissed item are excluded" do
      user = create_user!()
      other = create_user!()
      c = conversation!(user)
      add_user!(c.space.id, other.id)

      mention!(other, agent_message!(c, "For someone else"))
      dismissed = mention!(user, agent_message!(c, "Dismissed"))
      {:ok, _} = Inbox.mark_dismissed(dismissed.id, user.id)

      assert %{waiting: %{count: 0, rows: []}} = WidgetFeed.for_user(user)
      assert %{waiting: %{count: 1}} = WidgetFeed.for_user(other)
    end

    test "a deleted message and one older than 30 days are excluded" do
      user = create_user!()
      c = conversation!(user)
      now = DateTime.utc_now()

      mention!(user, agent_message!(c, "Deleted", %{deleted_at: now}))
      mention!(user, agent_message!(c, "Old", %{inserted_at: DateTime.add(now, -31, :day)}))
      mention!(user, agent_message!(c, "Recent", %{inserted_at: DateTime.add(now, -29, :day)}))

      assert %{waiting: %{count: 1, rows: [%{summary: "Recent"}]}} = WidgetFeed.for_user(user)
    end

    test "a 3-paragraph mention yields one line of at most 101 characters" do
      user = create_user!()
      c = conversation!(user)

      content = """
      @[Test Person] **Heads up**: the release note needs a yes.

      - It covers the widgets
      - and the `voice` control

      > Third paragraph with [a link](https://app.example.test/x) and more words to run long past the cap.
      """

      mention!(user, agent_message!(c, content))

      assert %{waiting: %{rows: [%{summary: summary}]}} = WidgetFeed.for_user(user)
      refute summary =~ "\n"
      refute summary =~ "@["
      refute summary =~ "**"
      refute summary =~ "`"
      refute summary =~ "https://"
      assert String.length(summary) <= 101
      assert String.ends_with?(summary, "…")

      assert String.starts_with?(
               summary,
               "Test Person Heads up: the release note needs a yes. It covers"
             )
    end
  end

  describe "summary/1" do
    test "collapses whitespace and keeps a short line whole" do
      assert WidgetFeed.summary("a\n\n  b\tc") == "a b c"
      assert WidgetFeed.summary(nil) == ""
      assert WidgetFeed.summary(String.duplicate("x", 100)) == String.duplicate("x", 100)
      assert WidgetFeed.summary(String.duplicate("x", 101)) == String.duplicate("x", 100) <> "…"
    end
  end

  # ── blocked ────────────────────────────────────────────────────────────

  describe "blocked" do
    test "empty" do
      user = create_user!()
      org_project!(user)
      assert %{blocked: %{count: 0, rows: []}} = WidgetFeed.for_user(user)
    end

    test "some: sponsored and user-assigned blocked tasks, with a cut first-line reason" do
      user = create_user!()
      project = org_project!(user)
      long = String.duplicate("r", 120)

      sponsored =
        task!(project, %{
          status: "blocked",
          sponsor_user_id: user.id,
          metadata: %{"blocked_reason" => long <> "\nsecond line"}
        })

      assigned =
        task!(project, %{
          status: "blocked",
          assignee_type: "user",
          assignee_id: user.id,
          metadata: %{"blocked_reason" => "Waiting on a key\nmore detail"}
        })

      # Not the user's, not blocked, deleted, agent-assigned with the same id.
      task!(project, %{status: "blocked", sponsor_user_id: create_user!().id})
      task!(project, %{status: "in_progress", sponsor_user_id: user.id})

      task!(project, %{
        status: "blocked",
        sponsor_user_id: user.id,
        deleted_at: DateTime.utc_now()
      })

      task!(project, %{status: "blocked", assignee_type: "agent", assignee_id: user.id})

      assert %{blocked: %{count: 2, rows: rows}} = WidgetFeed.for_user(user)
      by_id = Map.new(rows, &{&1.id, &1})

      assert by_id[assigned.id].reason == "Waiting on a key"
      assert by_id[sponsored.id].reason == String.duplicate("r", 80) <> "…"
      assert by_id[sponsored.id].title == sponsored.title
    end

    test "many: count is every task, rows are the top 3 by updated_at" do
      user = create_user!()
      project = org_project!(user)
      base = ~U[2026-11-20 12:00:00.000000Z]

      tasks =
        for i <- 1..5 do
          task!(project, %{
            status: "blocked",
            sponsor_user_id: user.id,
            updated_at: DateTime.add(base, i, :minute)
          })
        end

      assert %{blocked: %{count: 5, rows: rows}} = WidgetFeed.for_user(user)

      assert Enum.map(rows, & &1.id) ==
               tasks |> Enum.reverse() |> Enum.take(3) |> Enum.map(& &1.id)

      assert Enum.all?(rows, &is_nil(&1.reason))
    end

    test "a blocked task outside the user's visible projects is excluded" do
      user = create_user!()
      org_project!(user)
      hidden = hidden_project!()
      refute Enum.any?(Tasks.list_projects_for_user(user), &(&1.id == hidden.id))

      task!(hidden, %{status: "blocked", sponsor_user_id: user.id})

      assert %{blocked: %{count: 0, rows: []}} = WidgetFeed.for_user(user)
    end
  end

  # ── recent ─────────────────────────────────────────────────────────────

  describe "recent" do
    test "empty: no conversations with messages" do
      user = create_user!()
      conversation!(user)
      assert %{recent: %{rows: []}} = WidgetFeed.for_user(user)
    end

    test "order by newest message, 4 rows, unread flag, DM counterpart" do
      user = create_user!()
      base = DateTime.add(DateTime.utc_now(), -1, :hour)

      convs =
        for i <- 1..5 do
          c = conversation!(user)
          agent_message!(c, "m#{i}", %{inserted_at: DateTime.add(base, i, :minute)})
          c
        end

      # Read the newest channel up to its tip: it is not unread.
      [c5 | _] = Enum.reverse(convs)

      tip =
        Repo.one(
          from(m in Message,
            where: m.space_id == ^c5.space.id,
            order_by: [desc: m.id],
            limit: 1,
            select: m.id
          )
        )

      Repo.update_all(from(p in Participant, where: p.id == ^c5.me.id),
        set: [last_read_message_id: tip]
      )

      # A deleted message does not make a space recent.
      c1 = hd(convs)
      agent_message!(c1, "deleted", %{deleted_at: DateTime.utc_now()})

      assert %{recent: %{rows: rows}} = WidgetFeed.for_user(user)
      assert length(rows) == 4

      assert Enum.map(rows, & &1.space_id) ==
               convs |> Enum.reverse() |> Enum.take(4) |> Enum.map(& &1.space.id)

      assert [%{unread: false, kind: "channel", counterpart: nil} | rest] = rows
      assert Enum.all?(rest, & &1.unread)
      assert hd(rows).name == c5.space.name
    end

    test "a DM names the counterpart and carries its type and id" do
      user = create_user!()
      agent = agent!()

      {:ok, dm} = Platform.Chat.create_space(%{name: "dm", kind: "dm", is_direct: true})
      add_user!(dm.id, user.id)

      {:ok, bot} =
        Platform.Chat.add_participant(dm.id, %{
          participant_type: "agent",
          participant_id: agent.id,
          display_name: "Build agent",
          joined_at: DateTime.utc_now()
        })

      agent_message!(%{space: dm, bot: bot, agent: agent}, "hello")

      assert %{recent: %{rows: [row]}} = WidgetFeed.for_user(user)
      assert row.kind == "dm"
      assert row.name == "Build agent"
      assert row.counterpart == %{type: "agent", id: agent.id}
    end
  end

  # ── shipped ────────────────────────────────────────────────────────────

  describe "shipped" do
    test "empty" do
      user = create_user!()
      org_project!(user)
      assert %{shipped: %{count: 0, newest_title: nil}} = WidgetFeed.for_user(user)
    end

    # 03:30Z on the 28th is 21:30 on the 27th in Chicago (CST, UTC-6), so
    # "today" starts at 2026-11-27 06:00Z. A UTC-only boundary (00:00Z on the
    # 28th) would count the 23:00Z task as yesterday and the 05:00Z one as
    # today; both answers differ from the Chicago ones below.
    test "today's boundary is Chicago midnight, not UTC midnight" do
      user = create_user!()
      project = org_project!(user)
      now = ~U[2026-11-28 03:30:00Z]

      assert WidgetFeed.start_of_today(now) == ~U[2026-11-27 06:00:00.000000Z]

      before_midnight = task!(project, %{status: "done", title: "Before Chicago midnight"})
      done_at!(before_midnight, ~U[2026-11-27 05:00:00.000000Z])

      evening = task!(project, %{status: "done", title: "Chicago evening"})
      done_at!(evening, ~U[2026-11-27 23:00:00.000000Z])

      newest = task!(project, %{status: "done", title: "Newest"})
      done_at!(newest, ~U[2026-11-28 02:00:00.000000Z])

      # Hidden project and deleted tasks never count.
      hidden = task!(hidden_project!(), %{status: "done"})
      done_at!(hidden, ~U[2026-11-28 02:30:00.000000Z])
      deleted = task!(project, %{status: "done", deleted_at: DateTime.utc_now()})
      done_at!(deleted, ~U[2026-11-28 02:30:00.000000Z])

      # A transition to another status is not shipping.
      other = task!(project, %{status: "in_review"})

      Repo.insert!(%PhaseTransition{
        task_id: other.id,
        from_status: "in_progress",
        to_status: "in_review",
        occurred_at: ~U[2026-11-28 02:45:00.000000Z],
        actor_kind: "system"
      })

      assert %{shipped: %{count: 2, newest_title: "Newest"}} =
               WidgetFeed.for_user(user, now: now)
    end

    test "many: a task done twice today counts once" do
      user = create_user!()
      project = org_project!(user)
      now = DateTime.utc_now()
      start = WidgetFeed.start_of_today(now)

      for i <- 1..4 do
        t = task!(project, %{status: "done", title: "Shipped #{i}"})
        done_at!(t, DateTime.add(start, i, :second))
        if i == 1, do: done_at!(t, DateTime.add(start, 10, :second))
      end

      assert %{shipped: %{count: 4, newest_title: "Shipped 1"}} =
               WidgetFeed.for_user(user, now: now)
    end
  end
end
