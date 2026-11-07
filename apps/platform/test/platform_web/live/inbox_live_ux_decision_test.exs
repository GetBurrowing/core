defmodule PlatformWeb.InboxLiveUxDecisionTest do
  @moduledoc """
  Task 01a1af00 stage 3: the UX role's question in the Inbox (design canvas
  01a1b684-c1dd). The row (desktop and phone), the open item on
  `/inbox/ux/:finding_id`, and answering from it.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Inbox.Item
  alias Platform.Repo
  alias Platform.Ux.Decisions
  alias Platform.Ux.Finding

  defp u, do: System.unique_integer([:positive])
  defp auth(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp user! do
    n = u()

    Repo.insert!(%Platform.Accounts.User{
      email: "ux-lv-#{n}@example.com",
      name: "Ux Lv #{n}",
      oidc_sub: "ux-lv-#{n}"
    })
  end

  defp finding!(recipient, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          recipient_user_id: recipient.id,
          question: "Make DMs a top-level tab on mobile?",
          kind: "decision",
          evidence: %{count: 6, spaces: 3, quotes: ["can't find my DMs"], citations: []},
          options: [
            %{label: "A DMs tab", recommended: true, detail: "Both sizes"},
            %{label: "Pin DMs in the rail", recommended: false}
          ],
          group_key: "dm-#{u()}"
        },
        overrides
      )

    finding = %Finding{} |> Finding.changeset(attrs) |> Repo.insert!()
    {:ok, item} = Decisions.emit_inbox_item(finding)
    {finding, item}
  end

  describe "the row" do
    test "UX chip, the question as the title, the evidence line; no severity badge", %{conn: conn} do
      user = user!()
      {finding, item} = finding!(user)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      row = "#inbox-ux-list [data-role=inbox-ux-row][data-item-id='#{item.id}']"
      assert has_element?(lv, row <> " [data-role=ux-chip].bg-info", "UX")
      refute has_element?(lv, row <> " [data-role=ux-chip].bg-primary")
      assert has_element?(lv, row <> " [data-role=inbox-ux-question]", finding.question)
      refute has_element?(lv, row <> " [data-role=inbox-ux-question].truncate")

      assert has_element?(
               lv,
               row <> " [data-role=inbox-ux-evidence].truncate",
               "Seen 6× this week across 3 channels"
             )

      assert has_element?(lv, row <> " [data-role=inbox-ux-evidence]", "can't find my DMs")
      refute has_element?(lv, row <> " [data-role*=severity]")
      assert has_element?(lv, row <> " a[href='/inbox/ux/#{finding.id}']")
    end

    test "the phone list renders the same slots in its row", %{conn: conn} do
      user = user!()
      {finding, item} = finding!(user)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      row = "#inbox-rows [data-role=inbox-row][data-item-id='#{item.id}']"
      assert has_element?(lv, row <> " [data-role=ux-chip]", "UX")
      assert has_element?(lv, row <> " [data-role=inbox-row-author]", finding.question)
      assert has_element?(lv, row <> " [data-role=inbox-row-body].truncate", "Seen 6×")
    end

    test "X dismisses the row and leaves the finding open", %{conn: conn} do
      user = user!()
      {finding, item} = finding!(user)
      {:ok, lv, _html} = live(auth(conn, user), "/inbox")

      lv |> element("[data-role=inbox-ux-dismiss][phx-value-id='#{item.id}']") |> render_click()

      refute has_element?(lv, "[data-role=inbox-ux-row]")
      assert Repo.get!(Item, item.id).dismissed_at
      assert Repo.get!(Finding, finding.id).status == "open"
    end
  end

  describe "the open item" do
    test "question, collapsed evidence, answers with exactly one primary", %{conn: conn} do
      user = user!()
      {finding, item} = finding!(user)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox/ux/#{finding.id}")

      assert has_element?(lv, "[data-role=ux-decision-question]", finding.question)

      assert has_element?(
               lv,
               "[data-role=ux-decision-evidence]",
               "Seen 6× this week across 3 channels"
             )

      assert has_element?(lv, "[data-role=ux-decision-show-messages][aria-expanded=false]")
      assert has_element?(lv, "[data-role=ux-decision-messages].hidden")

      assert has_element?(lv, "[data-role=ux-decision-answer][data-answer=build]", "Build it")

      assert has_element?(
               lv,
               "[data-role=ux-decision-answer][data-answer=other]",
               "Try the other option"
             )

      assert has_element?(lv, "[data-role=ux-decision-answer][data-answer=not_now]", "Not now")
      assert has_element?(lv, "[data-role=ux-decision-answer][data-answer=build].btn-primary")
      refute has_element?(lv, "[data-role=ux-decision-answer][data-answer=other].btn-primary")
      refute has_element?(lv, "[data-role=ux-decision-answer][data-answer=not_now].btn-primary")
      assert has_element?(lv, "[data-role=ux-decision-recommended]", "Recommended")
      refute has_element?(lv, "[data-role=ux-decision-answers]", "Approve")
      refute has_element?(lv, "[data-role=ux-decision-answers]", "Reject")
      assert has_element?(lv, "[data-role=ux-decision-note] textarea")

      # Opening is reading: the row stays listed, read.
      item = Repo.get!(Item, item.id)
      assert item.read_at
      assert is_nil(item.dismissed_at)
    end

    test "show the messages expands the readable source messages with links", %{conn: conn} do
      user = Platform.TenancyFixtures.root_admin!()

      {:ok, space} =
        Platform.Chat.create_space(%{name: "ux-src", slug: "ux-src-#{u()}", kind: "channel"})

      {:ok, p} =
        Platform.Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          joined_at: DateTime.utc_now()
        })

      msg =
        %Platform.Chat.Message{}
        |> Platform.Chat.Message.changeset(%{
          space_id: space.id,
          participant_id: p.id,
          content_type: "text",
          content: "where are my direct messages",
          author_display_name: "Member"
        })
        |> Repo.insert!()

      {finding, _item} =
        finding!(user, %{
          evidence: %{count: 1, quotes: [], citations: [Finding.citation(space.id, msg.id)]}
        })

      {:ok, lv, _html} = live(auth(conn, user), "/inbox/ux/#{finding.id}")
      lv |> element("[data-role=ux-decision-show-messages]") |> render_click()

      assert has_element?(lv, "[data-role=ux-decision-show-messages][aria-expanded=true]")
      assert has_element?(lv, "[data-role=ux-decision-message]", "where are my direct messages")

      assert has_element?(
               lv,
               "[data-role=ux-decision-message-link][href='/chat/#{Platform.Chat.space_path_segment(space)}?message=#{msg.id}']"
             )
    end

    test "the mockup: before and after on a base-200 mat, each opening the image viewer",
         %{conn: conn} do
      user = user!()
      before_id = Ecto.UUID.generate()
      after_id = Ecto.UUID.generate()
      {finding, _item} = finding!(user, %{mockup_refs: %{before: before_id, after: after_id}})

      {:ok, lv, _html} = live(auth(conn, user), "/inbox/ux/#{finding.id}")

      assert has_element?(lv, "[data-role=ux-decision-mockup].bg-base-200")

      for {side, id} <- [{"before", before_id}, {"after", after_id}] do
        assert has_element?(
                 lv,
                 "[data-role=ux-decision-mockup-image][data-side=#{side}] a[data-image-viewer][href='/chat/attachments/#{id}']"
               )
      end
    end

    test "Build it answers, clears the row and returns to the list", %{conn: conn} do
      user = user!()
      {finding, item} = finding!(user)

      {:ok, lv, _html} = live(auth(conn, user), "/inbox/ux/#{finding.id}")

      lv
      |> form("[data-role=ux-decision-note]", %{ux_answer: %{note: "go"}})
      |> render_change()

      lv |> element("[data-role=ux-decision-answer][data-answer=build]") |> render_click()

      assert_patch(lv, "/inbox")

      assert %Finding{status: "answered", answer: "Build it: A DMs tab\nNote: go"} =
               Repo.get!(Finding, finding.id)

      assert Repo.get!(Item, item.id).dismissed_at
      refute has_element?(lv, "[data-role=inbox-ux-row]")
      assert has_element?(lv, "[data-role=inbox-toast]", "Answer sent to the task.")
    end

    test "another person's question is not found, and cannot be answered", %{conn: conn} do
      owner = user!()
      {finding, _item} = finding!(owner)

      {:ok, lv, _html} = live(auth(conn, user!()), "/inbox/ux/#{finding.id}")

      assert has_element?(lv, "[data-role=ux-decision-not-found]")
      refute has_element?(lv, "[data-role=ux-decision-answer]")
      assert Repo.get!(Finding, finding.id).status == "open"
    end
  end
end
