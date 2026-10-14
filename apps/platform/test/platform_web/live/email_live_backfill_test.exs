defmodule PlatformWeb.EmailLiveBackfillTest do
  @moduledoc """
  The "Import older mail" row in the Email account editor (task
  01a13ba5-42a7-7000-8f2b-4c63003f3f92 stage 3).

  The row is shown only to org admins on an account that reads mail
  (absent, never disabled, otherwise); its state is the latest
  `Platform.Mail.BackfillRun` row, so a reload shows the same run; Import
  runs `Platform.Mail.start_backfill/4` with the DEFAULT runner (under
  `Platform.TaskSupervisor`, the production path) against
  `Platform.Mail.Imap.FakeClient`, the test-config IMAP client. The import is
  quiet: no chat message, no `"mail:inbound"` broadcast.

  ## The seed

  INBOX gets six messages: four 3-20 days old and two 40-50 days old. One
  live poll then records the cursor at the max UID and ingests nothing
  (first contact), so a 30-day import reads exactly the four.

  async: false — flips `:mail_enabled` in application env, and the
  supervised import needs the shared sandbox.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Platform.AsyncAssertions

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Mail
  alias Platform.Mail.BackfillRun
  alias Platform.Mail.FolderCursor
  alias Platform.Mail.Imap.FakeClient
  alias Platform.Mail.Inbound
  alias Platform.Mail.InboundMessage
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @recent_days [3, 8, 14, 20]
  @seed_days [3, 40, 8, 14, 50, 20]
  @wait 5_000

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp user!(org_id, role) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "lv-backfill-#{n}@example.com",
        name: "LV Backfill #{n}",
        oidc_sub: "oidc-lv-backfill-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
    |> Repo.insert!()

    user
  end

  defp login(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp account!(ctx, overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          "name" => "lv-bf-#{n}",
          "smtp_tls" => "starttls",
          "username" => "reader-#{n}@acme.test",
          "imap_host" => "imap-lv-bf-#{n}.acme.test",
          "imap_port" => 993,
          "imap_tls" => "tls",
          "read_enabled" => true,
          "inbound_space_id" => ctx.space.id
        },
        overrides
      )

    {:ok, account} = Mail.create_account(ctx.admin, ctx.org_id, attrs, %{imap: "imap-pass"})
    account
  end

  defp raw(days) do
    "From: Recruiter <recruiter@corp.test>\r\nTo: reader@acme.test\r\n" <>
      "Subject: Older mail #{days}d\r\nDate: #{rfc2822(days_ago(days))}\r\n" <>
      "Message-ID: <lv-bf-#{days}d-#{System.unique_integer([:positive])}@corp.test>" <>
      "\r\n\r\nThanks, we received it.\r\n"
  end

  defp days_ago(n), do: Date.add(Date.utc_today(), -n)

  # Distinct Date headers, so the Inbox order (received_at desc) is total.
  defp rfc2822(%Date{} = date),
    do: Calendar.strftime(DateTime.new!(date, ~T[09:00:00]), "%a, %d %b %Y %H:%M:%S +0000")

  # INBOX seeded, one live poll done, cursor at the max UID, nothing stored.
  defp seed!(account) do
    FakeClient.start_server!(account.imap_host)
    FakeClient.put_folder(account.imap_host, "INBOX", uidvalidity: 3)

    for days <- @seed_days,
        do:
          FakeClient.deliver(account.imap_host, "INBOX", raw(days), internaldate: days_ago(days))

    assert {:ok, %{ingested: 0}} = Inbound.poll(Repo.reload!(account), client: FakeClient)
    assert %FolderCursor{last_uid: 6} = cursor(account)
    assert rows(account) == []
    account
  end

  defp cursor(account),
    do: Repo.get_by!(FolderCursor, account_id: account.id, folder: "INBOX")

  defp rows(account),
    do: Repo.all(from(m in InboundMessage, where: m.account_id == ^account.id, order_by: m.uid))

  defp runs(account),
    do: Repo.all(from(r in BackfillRun, where: r.account_id == ^account.id))

  defp chat_count, do: Repo.aggregate(Message, :count)

  defp row_selector, do: ~s([data-role="mail-backfill-row"])

  defp state_of(view) do
    case Regex.run(~r/data-role="mail-backfill-row"[^>]*data-state="(\w+)"/, render(view)) do
      [_, state] -> state
      nil -> nil
    end
  end

  # The row's visible text, tags dropped and whitespace collapsed.
  defp row_text(view) do
    view
    |> element(row_selector())
    |> render()
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/\s+/, " ")
  end

  defp editor(conn, user, account),
    do: live(login(conn, user), "/email/accounts/#{account.id}")

  defp click_import(view, days \\ "30") do
    view
    |> form("#mail-backfill-form", %{"window_days" => days})
    |> render_submit()
  end

  defp await_state(view, state) do
    assert_eventually(fn -> state_of(view) == state end, @wait)
  end

  defp day(%Date{} = date), do: Calendar.strftime(date, "%-d %b")

  defp running_run!(account, attrs) do
    %{
      account_id: account.id,
      org_id: account.org_id,
      window_days: 30,
      since_date: days_ago(30),
      started_at: DateTime.utc_now()
    }
    |> BackfillRun.start_changeset()
    |> Repo.insert!()
    |> BackfillRun.progress_changeset(attrs)
    |> Repo.update!()
  end

  setup do
    previous = Application.fetch_env(:platform, :mail_enabled)
    Application.put_env(:platform, :mail_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:platform, :mail_enabled, value)
        :error -> Application.delete_env(:platform, :mail_enabled)
      end
    end)

    org_id = Tenancy.get_org_by_slug!("soylent").id
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{name: "LV Backfill #{n}", slug: "lv-backfill-#{n}", kind: "channel"})

    %{
      org_id: org_id,
      admin: user!(org_id, "admin"),
      member: user!(org_id, "member"),
      space: space
    }
  end

  # ── Who sees the row ────────────────────────────────────────────────────

  describe "visibility" do
    test "a member never sees the row, and a crafted Import starts nothing",
         %{conn: conn} = ctx do
      account = ctx |> account!() |> seed!()

      {:ok, view, html} = editor(conn, ctx.member, account)
      refute html =~ ~s(data-role="mail-backfill-row")
      refute has_element?(view, row_selector())

      html =
        render_hook(view, "start_backfill", %{
          "account_id" => account.id,
          "window_days" => "30"
        })

      assert html =~ "Only org admins can import mail."
      assert runs(account) == []
      assert rows(account) == []
    end

    test "positive control: an admin on the same account sees the row", %{conn: conn} = ctx do
      account = ctx |> account!() |> seed!()

      {:ok, view, _html} = editor(conn, ctx.admin, account)
      assert has_element?(view, ~s([data-role="mail-backfill-row"][data-state="idle"]))
    end

    test "an account that does not read mail has no row, not a disabled one",
         %{conn: conn} = ctx do
      account = account!(ctx, %{"read_enabled" => false})

      {:ok, view, html} = editor(conn, ctx.admin, account)
      assert html =~ ~s(data-role="mail-account-form")
      refute has_element?(view, row_selector())
      refute html =~ "Import older mail"
    end
  end

  # ── Idle ────────────────────────────────────────────────────────────────

  describe "idle" do
    test "offers 7 / 14 / 30 days (30 selected), the folders, the quiet line and an outline Import",
         %{conn: conn} = ctx do
      account = ctx |> account!(%{"read_folders" => ["INBOX", "Work"]}) |> seed!()

      {:ok, view, _html} = editor(conn, ctx.admin, account)
      assert state_of(view) == "idle"

      html = view |> element(row_selector()) |> render()

      options =
        Regex.scan(~r/<option[^>]*value="(\d+)"([^>]*)>/, html)
        |> Enum.map(fn [_, value, rest] -> {value, rest =~ "selected"} end)

      assert options == [{"7", false}, {"14", false}, {"30", true}]

      text = row_text(view)
      assert text =~ "Import older mail"
      assert text =~ "Adds messages to the Inbox and agent context. Nothing is posted to chat."
      assert text =~ "Folders INBOX, Work"
      refute has_element?(view, ~s([data-role="mail-backfill-no-channel"]))

      button = view |> element(~s([data-role="mail-backfill-start"])) |> render()
      assert button =~ "btn-outline"
      refute button =~ "btn-primary"
      assert button =~ "Import"
    end

    test "with no inbound channel, the row says agents will not see the mail",
         %{conn: conn} = ctx do
      account = ctx |> account!(%{"inbound_space_id" => nil}) |> seed!()

      {:ok, view, _html} = editor(conn, ctx.admin, account)

      assert view |> element(~s([data-role="mail-backfill-no-channel"])) |> render() =~
               "Agents see imported mail only when this account posts to a channel."

      assert row_text(view) =~
               "Folders All folders except Sent, Drafts, Trash, Junk/Spam, Archive, Starred and All Mail"
    end

    test "a window outside the fixed set is refused before anything runs", %{conn: conn} = ctx do
      account = ctx |> account!() |> seed!()
      {:ok, view, _html} = editor(conn, ctx.admin, account)

      html =
        render_hook(view, "start_backfill", %{"account_id" => account.id, "window_days" => "31"})

      assert html =~ "Choose 7, 14 or 30 days."
      assert runs(account) == []
    end
  end

  # ── Running, done, the quiet rule ───────────────────────────────────────

  describe "an import" do
    test "Import runs, the row goes running then done with imported and already-present counts",
         %{conn: conn} = ctx do
      account = ctx |> account!() |> seed!()
      {:ok, view, _html} = editor(conn, ctx.admin, account)

      html = click_import(view)
      assert html =~ ~s(data-state="running")
      assert html =~ "You can leave this page."

      await_state(view, "done")
      [run] = runs(account)
      assert run.status == "done"
      assert run.imported == 4

      text = row_text(view)
      assert text =~ "Imported 4 messages since #{day(days_ago(30))}."
      assert text =~ "0 were already here."
      assert text =~ "Last run #{Calendar.strftime(run.finished_at, "%-d %b, %H:%M")}"
      assert has_element?(view, ~s([data-role="mail-backfill-open-inbox"]))
      assert view |> element(~s([data-role="mail-backfill-start"])) |> render() =~ "Import again"

      # A re-run imports nothing and says so, rather than reading as broken.
      click_import(view)

      assert_eventually(
        fn -> state_of(view) == "done" and row_text(view) =~ "4 were already here." end,
        @wait
      )

      assert row_text(view) =~ "Imported 0 messages since"
      assert length(runs(account)) == 2
      assert length(rows(account)) == 4
    end

    test "the quiet rule: Import with an inbound channel set posts nothing and broadcasts nothing",
         %{conn: conn} = ctx do
      account = ctx |> account!() |> seed!()
      assert account.inbound_space_id == ctx.space.id
      cursor_before = cursor(account)

      {:ok, view, _html} = editor(conn, ctx.admin, account)
      :ok = Inbound.subscribe()
      before = chat_count()

      click_import(view)
      await_state(view, "done")

      assert chat_count() == before
      refute_receive {:mail_inbound_ingested, _}, 200

      stored = rows(account)
      assert length(stored) == 4
      assert Enum.all?(stored, &(&1.ingest_source == "backfill" and is_nil(&1.chat_message_id)))
      assert cursor(account) == cursor_before
    end

    test "a second Import while one runs is refused by the run, not by the page",
         %{conn: conn} = ctx do
      account = ctx |> account!() |> seed!()
      running_run!(account, %{total: 10, imported: 1})

      {:ok, view, _html} = editor(conn, ctx.admin, account)
      assert state_of(view) == "running"
      refute has_element?(view, "#mail-backfill-form")

      html =
        render_hook(view, "start_backfill", %{"account_id" => account.id, "window_days" => "30"})

      assert html =~ "An import is already running for this account."
      assert length(runs(account)) == 1
    end
  end

  describe "progress from the DB" do
    test "a reload while running shows running from the row, and a finished run reloads the inbox",
         %{conn: conn} = ctx do
      account = ctx |> account!() |> seed!()
      run = running_run!(account, %{total: 1_900, imported: 410, already_present: 2})

      {:ok, view, _html} = editor(conn, ctx.admin, account)
      assert state_of(view) == "running"
      text = row_text(view)
      assert text =~ "Importing since #{day(run.since_date)}"
      assert text =~ "412 of ~1,900"
      assert has_element?(view, ~s(progress.progress-info[value="412"][max="1900"]))

      # A second device: a fresh mount reads the same row.
      {:ok, other, _html} = editor(conn, ctx.admin, account)
      assert state_of(other) == "running"

      # The run finishes elsewhere; the broadcast carries IDs only.
      run
      |> BackfillRun.progress_changeset(%{
        status: "done",
        imported: 1_874,
        already_present: 26,
        finished_at: DateTime.utc_now()
      })
      |> Repo.update!()

      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        Inbound.Backfill.topic(account.id),
        {:mail_backfill_progress, %{run_id: run.id, account_id: account.id}}
      )

      await_state(view, "done")
      assert row_text(view) =~ "Imported 1,874 messages since #{day(run.since_date)}."
      assert row_text(view) =~ "26 were already here."
    end

    test "a failed run renders its reason on the error slot and offers Try again",
         %{conn: conn} = ctx do
      # No fake IMAP server for this host: the import's connect fails.
      account = account!(ctx)
      {:ok, view, _html} = editor(conn, ctx.admin, account)

      click_import(view)
      await_state(view, "failed")

      error = view |> element(~s([data-role="mail-backfill-error"])) |> render()
      assert error =~ "text-error"

      assert row_text(view) =~
               "Import stopped after 0 messages: could not connect to the mail server. Nothing was lost."

      assert view |> element(~s([data-role="mail-backfill-start"])) |> render() =~ "Try again"
    end
  end

  # ── Inbox ───────────────────────────────────────────────────────────────

  describe "inbox" do
    # The class attributes of every tag in a row: its visual structure,
    # independent of the sender, subject and time it shows.
    defp skeleton(html), do: Regex.scan(~r/class="([^"]*)"/, html)

    test "imported mail lists in date order beside live mail with no badge",
         %{conn: conn} = ctx do
      account = ctx |> account!() |> seed!()

      {:ok, view, _html} = editor(conn, ctx.admin, account)
      click_import(view)
      await_state(view, "done")

      # One live message after the import: the poller posts and stores it.
      FakeClient.deliver(account.imap_host, "INBOX", raw(0))
      assert {:ok, %{ingested: 1}} = Inbound.poll(Repo.reload!(account), client: FakeClient)

      stored = rows(account)
      [live] = Enum.filter(stored, &(&1.ingest_source == "poll"))
      imported = Enum.filter(stored, &(&1.ingest_source == "backfill"))
      assert length(imported) == length(@recent_days)

      {:ok, inbox, html} = live(login(conn, ctx.admin), "/email")

      order =
        Regex.scan(~r/data-role="mail-inbox-row"[^>]*data-message-id="([^"]+)"/, html)
        |> Enum.map(fn [_, id] -> id end)
        |> Enum.filter(&(&1 in Enum.map(stored, fn m -> m.id end)))

      expected =
        stored
        |> Enum.sort_by(& &1.received_at, {:desc, DateTime})
        |> Enum.map(& &1.id)

      assert order == expected

      live_row = inbox |> element(~s([data-message-id="#{live.id}"])) |> render()

      for message <- imported do
        row = inbox |> element(~s([data-message-id="#{message.id}"])) |> render()
        assert skeleton(row) == skeleton(live_row)
        refute row =~ "badge"
        refute row =~ ~r/import|backfill/i
      end
    end
  end
end
