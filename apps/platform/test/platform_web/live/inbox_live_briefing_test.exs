defmodule PlatformWeb.InboxLiveBriefingTest do
  @moduledoc """
  Task 01a15ee1 stage 5: the briefing detail on `/inbox/briefing/:date`
  (`PlatformWeb.InboxLive.BriefingComponent`).

  Every click goes through `Briefings.handle/5` / `undo/3`; these tests read
  the result twice, once in the rendered card (section, receipt copy,
  toast) and once in the row it wrote (`memory_briefings.receipts`, the
  insight's state, the page, the task).
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Platform.InsightFixtures
  import Platform.TenancyFixtures, only: [acme_org_id: 0]

  alias Platform.Mail
  alias Platform.Memory.Briefing
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights.Actions
  alias Platform.Memory.Insights.BriefingCard
  alias Platform.Memory.Insights.Outside
  alias Platform.Org.Wiki
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task
  alias PlatformWeb.Components.BriefingRow

  defp n, do: System.unique_integer([:positive])
  defp auth(conn, user), do: init_test_session(conn, current_user_id: user.id)
  defp key(insight), do: BriefingCard.node_key(insight.id)
  defp today, do: BriefingRow.today(nil)
  defp path, do: "/inbox/briefing/" <> Date.to_iso8601(today())

  # The day's briefing row holding `insights`, plus its Inbox row.
  defp briefing!(user, insights) do
    briefing =
      Repo.insert!(%Briefing{
        user_id: user.id,
        digest_date: today(),
        items: Map.new(insights, &{key(&1), &1.id})
      })

    {:ok, _item, :created} =
      Platform.Inbox.upsert_briefing_item(briefing, %{total: length(insights), calls: 0})

    briefing
  end

  defp open!(conn, user) do
    {:ok, lv, _html} = live(auth(conn, user), path())
    lv
  end

  defp text(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> Floki.parse_fragment!()
    # Separate text nodes: adjacent buttons are apart on screen (flex gap)
    # but have no whitespace between them in the markup.
    |> Floki.text(sep: " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp card(insight), do: "#briefing-item-" <> key(insight)

  defp section_of(lv, insight) do
    html = render(lv)

    [section] =
      html
      |> Floki.parse_document!()
      |> Floki.find(card(insight))
      |> Floki.attribute("data-section")

    section
  end

  defp receipt(lv, insight), do: text(lv, card(insight) <> " [data-role=briefing-receipt]")

  defp toast(lv), do: text(lv, "[data-role=inbox-toast] [data-role=toast-message]")

  defp click(lv, insight, role),
    do: lv |> element(card(insight) <> " [data-role=#{role}]") |> render_click()

  defp question!(user),
    do: insight!(addressee: user, action_type: "question", body: "Which host?")

  defp page!(content) do
    key = "org/page/inbox-brief-#{n()}.md"
    {:ok, _page} = Wiki.upsert_page(key, %{content: content})
    key
  end

  defp page_edit!(user, key) do
    insight!(
      addressee: user,
      action_type: "page_edit",
      body: "The deploy host moved.",
      action: %{"target" => key, "hunks" => [%{"old" => "host-a", "new" => "host-b"}]}
    )
  end

  defp two_projects! do
    {:ok, a} = Tasks.create_project(%{name: "inbox-brief-a-#{n()}", org_id: acme_org_id()})
    {:ok, b} = Tasks.create_project(%{name: "inbox-brief-b-#{n()}", org_id: acme_org_id()})
    {a, b}
  end

  defp task!(user),
    do:
      insight!(addressee: user, action_type: "task", body: "Rotate the key #{n()}.", action: %{})

  setup do
    %{user: person!()}
  end

  # ── Sections ──────────────────────────────────────────────────────────

  describe "sections" do
    test "each section renders in order with its count; an empty one is hidden",
         %{conn: conn, user: user} do
      q = question!(user)
      fyi = insight!(addressee: user, body: "Public Sans is live. It was falling back to serif.")
      briefing!(user, [q, fyi])

      lv = open!(conn, user)

      assert text(lv, "[data-role=briefing-title]") == "Today's briefing"

      assert text(lv, "[data-role=briefing-meta]") ==
               Calendar.strftime(today(), "%a, %b %-d") <>
                 " · prepared from yesterday's journals and chat"

      assert text(lv, "[data-role=briefing-progress]") == "0 of 2 handled"

      headings =
        lv
        |> render()
        |> Floki.parse_document!()
        |> Floki.find("[data-role=briefing-section-heading]")
        |> Enum.map(&(&1 |> Floki.text() |> String.trim()))

      assert headings == ["Needs your call · 1", "For your information · 1"]
      refute has_element?(lv, "[data-role=briefing-section][data-section=done]")

      assert section_of(lv, q) == "needs_call"
      assert section_of(lv, fyi) == "fyi"
      assert text(lv, card(fyi) <> " [data-role=briefing-card-title]") == "Public Sans is live."
      assert text(lv, card(fyi) <> " [data-role=briefing-kind-tag]") == "FYI"
      assert text(lv, card(q) <> " [data-role=briefing-kind-tag]") == "Question"
      assert has_element?(lv, card(q) <> " summary", "Why am I seeing this?")
      refute has_element?(lv, "[data-role=briefing-all-caught-up]")
    end

    test "all handled reads clear for today, and the all-caught-up line shows",
         %{conn: conn, user: user} do
      fyi = insight!(addressee: user)
      briefing!(user, [fyi])
      lv = open!(conn, user)

      click(lv, fyi, "briefing-got-it")

      assert text(lv, "[data-role=briefing-progress]") ==
               "1 of 1 handled · you're clear for today"

      assert text(lv, "[data-role=briefing-all-caught-up]") ==
               "All caught up. Tomorrow's briefing arrives at 7:00."

      refute has_element?(lv, "[data-role=briefing-section][data-section=fyi]")
    end

    test "the settings note reads the live settings; admins also get Install settings",
         %{conn: conn, user: user} do
      briefing!(user, [insight!(addressee: user)])
      lv = open!(conn, user)

      note = text(lv, "[data-role=briefing-settings-note]")

      assert note =~
               "Briefings arrive in your Inbox each morning. Items you don't handle expire after 7 days."

      assert note =~ "Briefing settings · deliver at 7:00 · include page edits ✗ · tasks ✓"
      assert has_element?(lv, "[data-role=briefing-settings-link][href='/memory/insights']")
      refute has_element?(lv, "[data-role=briefing-install-settings-link]")

      admin = person!("admin")
      briefing!(admin, [insight!(addressee: admin)])
      lv = open!(conn, admin)

      assert has_element?(
               lv,
               "[data-role=briefing-install-settings-link][href='/admin/insights']"
             )
    end

    test "a second user's GET of the date shows nothing of the first user's",
         %{conn: conn, user: user} do
      q = question!(user)
      briefing!(user, [q])
      other = person!()

      {:ok, lv, html} = live(auth(conn, other), path())
      refute has_element?(lv, "[data-role=briefing-detail]")
      refute has_element?(lv, "[data-role=briefing-card]")
      refute html =~ "Which host?"
    end
  end

  # ── Verbs: the card moves to Done with its receipt ────────────────────

  describe "verbs" do
    test "answer: the card moves to Done; a blank answer only changes the placeholder",
         %{conn: conn, user: user} do
      q = question!(user)
      briefing!(user, [q])
      lv = open!(conn, user)

      lv
      |> form(card(q) <> " form[data-role=briefing-answer-form]", %{answer: " "})
      |> render_submit()

      assert section_of(lv, q) == "needs_call"

      assert has_element?(
               lv,
               card(q) <> " textarea[placeholder='Type an answer first']"
             )

      lv
      |> form(card(q) <> " form[data-role=briefing-answer-form]", %{answer: "host-b"})
      |> render_submit()

      assert section_of(lv, q) == "done"
      assert receipt(lv, q) =~ "✓ Answered · saved to org memory View Undo answer"
      assert toast(lv) == "Answer sent"

      # ONE toast: the briefing variant, not also the bulk-clear one.
      assert lv
             |> render()
             |> Floki.parse_document!()
             |> Floki.find("[data-role=inbox-toast]")
             |> length() == 1

      assert has_element?(
               lv,
               "[data-role=inbox-toast][data-variant=briefing] [data-role=toast-undo]"
             )

      assert %Insight{state: "done"} = Repo.get!(Insight, q.id)
    end

    test "reroute: Sent to <name>, with an Undo", %{conn: conn, user: user} do
      q = question!(user)
      target = person!()
      briefing!(user, [q])
      lv = open!(conn, user)

      click(lv, q, "briefing-reroute")
      assert has_element?(lv, card(q) <> " [data-role=briefing-reroute-form]", "Send it to")

      lv
      |> form(card(q) <> " [data-role=briefing-reroute-form]", %{addressee: target.id})
      |> render_submit()

      assert section_of(lv, q) == "done"
      assert receipt(lv, q) =~ "Sent to #{target.name} · it'll be in their briefing"
      assert toast(lv) == "Rerouted to #{target.name}"
      assert Repo.get!(Insight, q.id).addressee_user_id == target.id
    end

    test "got_it, dismiss and not_useful", %{conn: conn, user: user} do
      seen = insight!(addressee: user)
      gone = insight!(addressee: user)
      meh = insight!(addressee: user)
      briefing!(user, [seen, gone, meh])
      lv = open!(conn, user)

      click(lv, seen, "briefing-got-it")
      assert receipt(lv, seen) =~ "✓ Seen"
      assert toast(lv) == "Marked as seen"

      click(lv, gone, "briefing-dismiss")
      assert receipt(lv, gone) =~ "Dismissed"
      assert toast(lv) == "Dismissed"

      click(lv, meh, "briefing-not-useful")

      assert has_element?(
               lv,
               card(meh) <> " [data-role=briefing-reject-form]",
               "What made this not useful? (teaches dreaming)"
             )

      lv
      |> form(card(meh) <> " [data-role=briefing-reject-form]", %{reason: "already known"})
      |> render_submit()

      assert receipt(lv, meh) =~ "Marked not useful · dreaming will learn from it"
      assert toast(lv) == "Thanks, dreaming will learn from that"
      assert text(lv, "[data-role=briefing-progress]") =~ "3 of 3 handled"
    end

    test "apply and edit first write the page; the receipt names the version",
         %{conn: conn, user: user} do
      page_a = page!("Deploys go to host-a.")
      page_b = page!("Deploys go to host-a.")
      edit = page_edit!(user, page_a)
      mine = page_edit!(user, page_b)
      briefing!(user, [edit, mine])
      lv = open!(conn, user)

      assert has_element?(lv, card(edit) <> " [data-role=briefing-diff-path]", page_a)
      assert has_element?(lv, card(edit) <> " [data-role=briefing-diff-old]", "host-a")

      click(lv, edit, "briefing-apply")
      version = Wiki.get_page(page_a).version
      assert Wiki.get_page(page_a).content == "Deploys go to host-b."
      assert receipt(lv, edit) =~ "✓ Applied · #{page_a} v#{version} Open page Revert"
      assert toast(lv) == "Edit applied to #{page_a}"

      click(lv, mine, "briefing-edit-first")

      assert has_element?(
               lv,
               card(mine) <> " [data-role=briefing-apply-mine]",
               "Apply my version"
             )

      lv
      |> form(card(mine) <> " [data-role=briefing-diff]", %{
        hunks: %{"0" => %{"old" => "host-a", "new" => "host-c"}}
      })
      |> render_submit()

      assert Wiki.get_page(page_b).content == "Deploys go to host-c."
      assert toast(lv) == "Your version applied"
      assert section_of(lv, mine) == "done"
    end

    test "file stays disabled until a project is picked, then files into it",
         %{conn: conn, user: user} do
      {_a, b} = two_projects!()
      task = task!(user)
      briefing!(user, [task])
      lv = open!(conn, user)

      assert has_element?(
               lv,
               card(task) <> " [data-role=briefing-project-hint]",
               "this insight didn't name one, pick it here"
             )

      assert has_element?(lv, card(task) <> " [data-role=briefing-file][disabled]")

      assert has_element?(
               lv,
               card(task) <> " [data-role=briefing-file-disabled-reason]",
               "Pick a project to file this."
             )

      assert has_element?(lv, card(task) <> " option[value='']", "Choose a project…")

      lv
      |> form(card(task) <> " [data-role=briefing-file-form]", %{project_id: b.id})
      |> render_change()

      refute has_element?(lv, card(task) <> " [data-role=briefing-file][disabled]")
      refute has_element?(lv, card(task) <> " [data-role=briefing-file-disabled-reason]")

      lv
      |> form(card(task) <> " [data-role=briefing-file-form]", %{
        project_id: b.id,
        title: "Rotate the build key"
      })
      |> render_submit()

      assert [filed] = Repo.all(from(t in Task, where: t.project_id == ^b.id))
      assert filed.title == "Rotate the build key"

      assert receipt(lv, task) =~
               "✓ Task filed in #{b.name} Open task Delete Move to another project"

      assert toast(lv) == "Task filed in #{b.name}"
    end
  end

  describe "the no-project picker keeps a typed title (stage 6)" do
    test "type a title, then choose a project: the task is filed with the typed title",
         %{conn: conn, user: user} do
      {_a, b} = two_projects!()
      task = task!(user)
      briefing!(user, [task])
      lv = open!(conn, user)
      form = card(task) <> " [data-role=briefing-file-form]"

      # Typing fires the form's phx-change with the project still unchosen.
      lv |> form(form, %{title: "My typed title", project_id: ""}) |> render_change()
      # Choosing the project: the re-render must not paint the default back.
      lv |> form(form, %{project_id: b.id}) |> render_change()

      assert has_element?(
               lv,
               card(task) <> " input[name=title][value='My typed title']"
             )

      # Submit without restating the title: what is filed is what the form holds.
      lv |> form(form, %{project_id: b.id}) |> render_submit()

      assert [filed] = Repo.all(from(t in Task, where: t.project_id == ^b.id))
      assert filed.title == "My typed title"
    end
  end

  # ── Undo: the toast and the receipt ───────────────────────────────────

  describe "undo" do
    test "the toast's Undo restores the item", %{conn: conn, user: user} do
      fyi = insight!(addressee: user)
      briefing!(user, [fyi])
      lv = open!(conn, user)

      click(lv, fyi, "briefing-dismiss")
      assert section_of(lv, fyi) == "done"

      lv |> element("[data-role=inbox-toast] [data-role=toast-undo]") |> render_click()

      assert section_of(lv, fyi) == "fyi"
      refute has_element?(lv, "[data-role=inbox-toast]")
      assert %Insight{state: "open"} = Repo.get!(Insight, fyi.id)
    end

    test "the receipt keeps its inverse after the toast is gone", %{conn: conn, user: user} do
      fyi = insight!(addressee: user)
      briefing!(user, [fyi])
      lv = open!(conn, user)

      click(lv, fyi, "briefing-got-it")
      lv |> element("[data-role=inbox-toast]") |> render_hook("toast_pause", %{})
      send(lv.pid, {:clear_toast, toast_state(lv).nonce})
      lv |> element("[data-role=inbox-toast]") |> render_hook("toast_resume", %{})
      send(lv.pid, {:clear_toast, toast_state(lv).nonce})
      refute has_element?(lv, "[data-role=inbox-toast]")

      lv
      |> element(card(fyi) <> " [data-role=briefing-inverse][data-action=undo]", "Restore")
      |> render_click()

      assert section_of(lv, fyi) == "fyi"
      assert %Insight{state: "open"} = Repo.get!(Insight, fyi.id)
    end

    test "a filed task's Delete is the inverse; Move and Move back move it",
         %{conn: conn, user: user} do
      {a, b} = two_projects!()
      task = task!(user)
      briefing!(user, [task])
      lv = open!(conn, user)

      lv
      |> form(card(task) <> " [data-role=briefing-file-form]", %{project_id: a.id})
      |> render_submit()

      [filed] = Repo.all(from(t in Task, where: t.project_id == ^a.id))

      lv
      |> element(card(task) <> " [data-role=briefing-inverse][data-action=move]")
      |> render_click()

      lv
      |> form(card(task) <> " [data-role=briefing-move-form]", %{project_id: b.id})
      |> render_submit()

      assert Repo.get!(Task, filed.id).project_id == b.id
      assert toast(lv) == "Task moved to #{b.name}"
      assert receipt(lv, task) =~ "✓ Task filed in #{b.name}"

      lv
      |> element(card(task) <> " [data-role=briefing-inverse][data-action=undo]", "Move back")
      |> render_click()

      assert Repo.get!(Task, filed.id).project_id == a.id

      lv
      |> element(card(task) <> " [data-role=briefing-inverse][data-action=undo]", "Delete")
      |> render_click()

      assert %Task{deleted_at: %DateTime{}} = Repo.get!(Task, filed.id)
      assert section_of(lv, task) == "needs_call"
    end

    test "Delete on a task filed unattended has no Undo in its toast", %{conn: conn, user: user} do
      {a, _b} = two_projects!()
      dreamer = dreaming_agent!()

      runtime =
        Platform.RuntimeProfileFixtures.runtime!(
          Platform.TenancyFixtures.root_admin!().id,
          ["task"],
          %{agent_id: dreamer.id}
        )

      Repo.update_all(from(ag in Platform.Agents.Agent, where: ag.id == ^dreamer.id),
        set: [runtime_id: runtime.id]
      )

      task =
        insight!(
          addressee: user,
          action_type: "task",
          body: "Silence the disk warning.",
          action: %{"project_id" => a.id},
          authored_by: dreamer.id
        )

      assert {:ok, %Insight{state: "done"}} = Actions.apply_unattended(task, [])
      briefing!(user, [task])
      lv = open!(conn, user)

      assert receipt(lv, task) =~
               "✓ Task filed in #{a.name} Open task Delete Move to another project"

      # Delete's contrast ruling: the label is body text; only the trash
      # icon (non-text, 3:1) is error-coloured. text-error as text is
      # 3.74:1 light / 4.42:1 dark, under 4.5:1.
      [delete] =
        lv
        |> render()
        |> Floki.parse_document!()
        |> Floki.find(card(task) <> " [data-role=briefing-inverse][data-action=delete]")

      refute "text-error" in (delete |> Floki.attribute("class") |> hd() |> String.split())

      assert delete |> Floki.find("[data-role=briefing-inverse-label]") |> Floki.text() ==
               "Delete"

      refute delete
             |> Floki.find("[data-role=briefing-inverse-label]")
             |> Floki.attribute("class")
             |> Enum.any?(&String.contains?(&1, "text-error"))

      assert ["hero-trash size-4 shrink-0 text-error"] =
               delete
               |> Floki.find("[data-role=briefing-inverse-icon]")
               |> Floki.attribute("class")

      lv
      |> element(card(task) <> " [data-role=briefing-inverse][data-action=delete]")
      |> render_click()

      assert toast(lv) == "Task deleted"
      refute has_element?(lv, "[data-role=inbox-toast] [data-role=toast-undo]")
      assert receipt(lv, task) =~ "✓ Task deleted"
      refute has_element?(lv, card(task) <> " [data-role=briefing-inverse]")
    end
  end

  # ── Errors and the outside card ───────────────────────────────────────

  describe "errors and outside messages" do
    test "a failed action keeps the card where it is and says so", %{conn: conn, user: user} do
      fyi = insight!(addressee: user)
      briefing!(user, [fyi])
      lv = open!(conn, user)

      # Opening the detail marks its Inbox row read, which broadcasts to this
      # LiveView; let that repaint land first (a render is a sync call, so
      # every message queued before it is handled before it returns).
      _ = render(lv)
      assert has_element?(lv, card(fyi) <> " [data-role=briefing-got-it]")

      # Closed behind the page's back, with no broadcast to repaint it: the
      # card is still on screen and Got it is now refused (`:not_open`).
      {1, _} =
        Repo.update_all(from(i in Insight, where: i.id == ^fyi.id), set: [state: "dismissed"])

      click(lv, fyi, "briefing-got-it")

      assert has_element?(
               lv,
               card(fyi) <> " [data-role=briefing-card-error]",
               "Couldn't mark this as seen. Try again."
             )

      assert has_element?(lv, card(fyi) <> "[data-section=fyi]")
      refute has_element?(lv, "[data-role=inbox-toast]")
      assert Repo.get_by!(Briefing, user_id: user.id).receipts == %{}
    end

    test "the outside card names the address, links to the draft, and has no Send",
         %{conn: conn} do
      admin = person!("admin")
      mail_on!()
      account!(acme_org_id())
      agent = dreaming_agent!()

      outside =
        insight!(
          action_type: "question",
          tier: "needs_call",
          body: "Hello Ana\nCan we move the review?",
          action: %{"addressee" => "ana-#{n()}@client.example"}
        )

      {:ok, draft_id} = Outside.draft(outside, agent)
      outside = Repo.get!(Insight, outside.id)
      briefing!(admin, [outside])
      lv = open!(conn, admin)

      assert text(lv, card(outside) <> " [data-role=briefing-kind-tag]") == "Email draft"

      assert text(lv, card(outside) <> " [data-role=briefing-outside-to]") ==
               "To: #{outside.action["addressee"]} (outside your org)"

      assert has_element?(
               lv,
               card(outside) <> " [data-role=briefing-outside-status]",
               "Draft, not sent"
             )

      assert has_element?(
               lv,
               card(outside) <>
                 " a[data-role=briefing-open-draft][href='/email/drafts/#{draft_id}']",
               "Open draft"
             )

      sends =
        lv
        |> render()
        |> Floki.parse_document!()
        |> Floki.find("button, a, input[type=submit]")
        |> Enum.filter(&(&1 |> Floki.text() |> String.trim() == "Send"))

      assert sends == []
    end

    test "with nothing drafted, the outside card says email wasn't set up yet", %{conn: conn} do
      admin = person!("admin")

      outside =
        insight!(
          action_type: "question",
          tier: "needs_call",
          action: %{"addressee" => "ana-#{n()}@client.example"}
        )

      briefing!(admin, [outside])
      lv = open!(conn, admin)

      assert has_element?(
               lv,
               card(outside) <> " [data-role=briefing-outside-mail-off]",
               "Email wasn't set up yet, so nothing was drafted or sent."
             )

      refute has_element?(lv, card(outside) <> " [data-role=briefing-open-draft]")
    end
  end

  # ── Toast pause ────────────────────────────────────────────────────────

  describe "the toast" do
    test "pauses while hovered or focused and resumes with a fresh timer",
         %{conn: conn, user: user} do
      fyi = insight!(addressee: user)
      briefing!(user, [fyi])
      lv = open!(conn, user)

      click(lv, fyi, "briefing-got-it")
      first = toast_state(lv)
      assert first.variant == :briefing

      lv |> element("[data-role=inbox-toast]") |> render_hook("toast_pause", %{})
      assert toast_state(lv).paused == true
      assert has_element?(lv, "[data-role=inbox-toast][data-paused=true]")

      # The 5 s timer firing while paused does not clear it.
      send(lv.pid, {:clear_toast, first.nonce})
      assert has_element?(lv, "[data-role=inbox-toast]")

      lv |> element("[data-role=inbox-toast]") |> render_hook("toast_resume", %{})
      resumed = toast_state(lv)
      refute resumed[:paused]
      assert resumed.nonce != first.nonce

      # The old timer is stale now; the new one clears it.
      send(lv.pid, {:clear_toast, first.nonce})
      assert has_element?(lv, "[data-role=inbox-toast]")
      send(lv.pid, {:clear_toast, resumed.nonce})
      refute has_element?(lv, "[data-role=inbox-toast]")
    end
  end

  defp toast_state(lv) do
    _ = render(lv)
    :sys.get_state(lv.pid).socket.assigns.toast
  end

  defp mail_on! do
    previous = Application.fetch_env(:platform, :mail_enabled)
    Application.put_env(:platform, :mail_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:platform, :mail_enabled, value)
        :error -> Application.delete_env(:platform, :mail_enabled)
      end
    end)
  end

  defp account!(org_id) do
    admin = person!("admin")
    name = "inboxbrief#{n()}"

    {:ok, account} =
      Mail.create_account(admin, org_id, %{
        "name" => name,
        "smtp_host" => "smtp.#{name}.test",
        "smtp_port" => 2525,
        "smtp_tls" => "none",
        "username" => "#{name}-relay"
      })

    account
  end
end
