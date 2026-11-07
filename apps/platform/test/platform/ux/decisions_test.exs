defmodule Platform.Ux.DecisionsTest do
  @moduledoc """
  Task 01a1af00 stage 3: the `ux_decision` Inbox kind (`Platform.Ux.Decisions`).
  Emission to the recipient only, the kind's registration and counting,
  the answers, and the answer write path (finding, Inbox row, task log).
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Inbox
  alias Platform.Inbox.Item
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.TenancyFixtures
  alias Platform.Ux.Decisions
  alias Platform.Ux.Finding

  defp u, do: System.unique_integer([:positive])

  defp user! do
    n = u()

    Repo.insert!(%Platform.Accounts.User{
      email: "ux-decision-#{n}@example.com",
      name: "Ux Decision #{n}",
      oidc_sub: "ux-decision-#{n}"
    })
  end

  defp finding!(recipient, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          recipient_user_id: recipient.id,
          question: "Should direct messages get their own tab?",
          kind: "decision",
          evidence: %{
            count: 6,
            spaces: 3,
            quotes: ["can't find my DMs", "where did the DM go"],
            citations: []
          },
          options: [
            %{label: "Add a DMs tab", recommended: true, detail: "Both sizes"},
            %{label: "Pin DMs at the top of the rail", recommended: false}
          ],
          group_key: "dm-findability-#{u()}"
        },
        overrides
      )

    %Finding{} |> Finding.changeset(attrs) |> Repo.insert!()
  end

  defp task_with_log! do
    {:ok, project} = Tasks.create_project(%{name: "UX decision project #{u()}"})

    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "UX task #{u()}", status: "planning"})

    {:ok, space} = ExecutionSpace.find_or_create(task.id)
    {task, space}
  end

  defp rows(user_id) do
    Repo.all(from(i in Item, where: i.user_id == ^user_id and i.kind == "ux_decision"))
  end

  defp log_messages(space) do
    Repo.all(from(m in Message, where: m.space_id == ^space.id, order_by: [asc: m.inserted_at]))
  end

  describe "the kind" do
    test "is a core kind with its own source type, listed on open, never an approval" do
      assert "ux_decision" in Item.core_kinds()
      assert "ux_finding" in Item.core_source_types()
      assert "ux_decision" in Inbox.action_kinds()
      refute "ux_decision" in Inbox.core_action_kinds()
      refute "ux_decision" in Inbox.push_kinds()
    end
  end

  describe "emit_inbox_item/1" do
    test "writes ONE row, to the recipient only, titled by the question" do
      recipient = user!()
      bystander = user!()
      finding = finding!(recipient)

      assert {:ok, %Item{} = item} = Decisions.emit_inbox_item(finding)

      assert [row] = Repo.all(from(i in Item, where: i.source_id == ^finding.id))
      assert row.id == item.id
      assert row.user_id == recipient.id
      assert row.kind == "ux_decision"
      assert row.source_type == "ux_finding"
      assert row.title == "Should direct messages get their own tab?"
      assert row.body == "Seen 6× this week across 3 channels"
      assert row.url == "/inbox/ux/" <> finding.id
      assert rows(bystander.id) == []
    end

    # Stage 4 follow-up: the install owner exists and is NOT the recipient,
    # so a row addressed to `Accounts.install_owner/0` would be caught.
    test "goes to the recipient, never to an install owner who is someone else" do
      owner = TenancyFixtures.root_admin!()
      recipient = user!()
      assert Platform.Accounts.install_owner()
      refute Platform.Accounts.install_owner().id == recipient.id

      assert {:ok, %Item{}} = recipient |> finding!() |> Decisions.emit_inbox_item()

      assert [%{user_id: user_id}] = rows(recipient.id)
      assert user_id == recipient.id
      assert rows(owner.id) == []
      assert rows(Platform.Accounts.install_owner().id) == []
    end

    test "an fyi, or a finding that is no longer open, writes nothing" do
      recipient = user!()
      fyi = finding!(recipient, %{kind: "fyi", options: []})

      answered =
        finding!(recipient) |> Finding.resolve_changeset("answered", "x") |> Repo.update!()

      assert Decisions.emit_inbox_item(fyi) == :skipped
      assert Decisions.emit_inbox_item(answered) == :skipped
      assert rows(recipient.id) == []
    end

    test "is counted on the badge for an internal user and stays listed once opened" do
      recipient = user!()
      {:ok, item} = recipient |> finding!() |> Decisions.emit_inbox_item()

      assert Inbox.reachable_unread_count(recipient.id) == 1

      assert {:ok, opened} = Inbox.open_item(item.id, recipient.id)
      assert opened.read_at
      assert is_nil(opened.dismissed_at)
      assert Inbox.reachable_unread_count(recipient.id) == 0
      assert [%{id: id}] = Repo.all(Inbox.unread_scope(recipient.id))
      assert id == item.id
    end
  end

  describe "evidence_line/1" do
    test "count, then channels when known" do
      assert Decisions.evidence_line(%{"count" => 1, "spaces" => 1}) ==
               "Seen 1× this week across 1 channel"

      assert Decisions.evidence_line(%{"count" => 4}) == "Seen 4× this week"
    end
  end

  describe "answers/1" do
    test "at most three, EXACTLY one primary (Build it, the recommended option)" do
      finding = finding!(user!())
      answers = Decisions.answers(finding)

      assert Enum.map(answers, & &1.label) == ["Build it", "Try the other option", "Not now"]

      assert [%{key: "build", option: %{"label" => "Add a DMs tab"}}] =
               Enum.filter(answers, & &1.primary?)

      assert length(answers) <= 3

      single =
        finding!(user!(), %{options: [%{label: "Add a DMs tab", recommended: true}]})

      assert Enum.map(Decisions.answers(single), & &1.key) == ["build", "not_now"]
    end
  end

  describe "answer/4" do
    test "Build it records the answer, clears the row and posts the outcome to the task" do
      recipient = TenancyFixtures.root_admin!()
      {task, space} = task_with_log!()
      finding = finding!(recipient, %{task_id: task.id})
      {:ok, item} = Decisions.emit_inbox_item(finding)
      before = length(log_messages(space))

      assert {:ok, answered} = Decisions.answer(finding.id, recipient.id, "build", " ship it ")

      assert answered.status == "answered"
      assert answered.answer == "Build it: Add a DMs tab\nNote: ship it"
      assert Repo.get!(Item, item.id).dismissed_at

      [post] = Enum.drop(log_messages(space), before)
      assert post.content =~ "UX decision answered: Should direct messages get their own tab?"
      assert post.content =~ "Build it: Add a DMs tab"
      assert post.metadata["reason"] == "ux_decision_answered"
    end

    test "Not now resolves as dismissed and clears the row" do
      recipient = user!()
      finding = finding!(recipient)
      {:ok, item} = Decisions.emit_inbox_item(finding)

      assert {:ok, %Finding{status: "dismissed", answer: "Not now"}} =
               Decisions.answer(finding.id, recipient.id, "not_now")

      assert Repo.get!(Item, item.id).dismissed_at
    end

    test "only the recipient can answer, once, with an offered answer" do
      recipient = user!()
      finding = finding!(recipient)
      {:ok, item} = Decisions.emit_inbox_item(finding)

      assert Decisions.answer(finding.id, user!().id, "build") == {:error, :not_found}
      assert Decisions.answer("not-a-uuid", recipient.id, "build") == {:error, :not_found}
      assert Decisions.answer(finding.id, recipient.id, "approve") == {:error, :invalid_answer}
      assert Repo.get!(Finding, finding.id).status == "open"
      assert is_nil(Repo.get!(Item, item.id).dismissed_at)

      assert {:ok, _} = Decisions.answer(finding.id, recipient.id, "other")

      assert Repo.get!(Finding, finding.id).answer ==
               "Try the other option: Pin DMs at the top of the rail"

      assert Decisions.answer(finding.id, recipient.id, "build") == {:error, :already_answered}
    end

    test "a finding with no task posts nowhere" do
      recipient = user!()
      finding = finding!(recipient)
      count = Repo.aggregate(Message, :count)

      assert {:ok, _} = Decisions.answer(finding.id, recipient.id, "build")
      assert Repo.aggregate(Message, :count) == count
    end
  end

  describe "the reconciler" do
    test "dismisses a row whose finding was resolved elsewhere, keeps an open one" do
      recipient = user!()
      open = finding!(recipient)
      done = finding!(recipient)
      {:ok, open_item} = Decisions.emit_inbox_item(open)
      {:ok, done_item} = Decisions.emit_inbox_item(done)
      done |> Finding.resolve_changeset("answered", "Build it") |> Repo.update!()

      :ok = Inbox.reconcile_for_user(recipient.id)

      assert is_nil(Repo.get!(Item, open_item.id).dismissed_at)
      assert Repo.get!(Item, done_item.id).dismissed_at
    end
  end

  describe "source_messages/2" do
    test "the cited messages the viewer can read, in citation order, with chat links" do
      viewer = TenancyFixtures.root_admin!()

      {:ok, space} =
        Chat.create_space(%{name: "ux-src", slug: "ux-src-#{u()}", kind: "channel"})

      {:ok, p} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: viewer.id,
          joined_at: DateTime.utc_now()
        })

      msg =
        %Message{}
        |> Message.changeset(%{
          space_id: space.id,
          participant_id: p.id,
          content_type: "text",
          content: "I can't find my DMs",
          author_display_name: "Member"
        })
        |> Repo.insert!()

      finding =
        finding!(viewer, %{
          evidence: %{
            count: 2,
            quotes: [],
            citations: [
              Finding.citation(space.id, msg.id),
              Finding.citation(space.id, Ecto.UUID.generate())
            ]
          }
        })

      assert [m] = Decisions.source_messages(finding, viewer.id)
      assert m.id == msg.id
      assert m.content == "I can't find my DMs"
      assert m.url == "/chat/#{Chat.space_path_segment(space)}?message=#{msg.id}"
    end
  end

  describe "mockup_src/1" do
    test "attachment paths and ids only" do
      id = Ecto.UUID.generate()
      assert Decisions.mockup_src(id) == "/chat/attachments/" <> id
      assert Decisions.mockup_src("/chat/attachments/" <> id) == "/chat/attachments/" <> id
      assert Decisions.mockup_src("canvas:abc") == nil
      assert Decisions.mockup_src("https://example.com/x.png") == nil
      assert Decisions.mockup_src(nil) == nil
    end
  end
end
