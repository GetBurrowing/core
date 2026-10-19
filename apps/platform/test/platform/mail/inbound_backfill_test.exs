defmodule Platform.Mail.InboundBackfillTest do
  @moduledoc """
  The one-off quiet backfill (task 01a13ba5-42a7-7000-8f2b-4c63003f3f92
  stage 1): `Platform.Mail.start_backfill/4` and
  `Platform.Mail.Inbound.Backfill`.

  Most tests drive `Platform.Mail.Imap.FakeClient`; the read-only transcript
  test drives the production `WireClient` against
  `Platform.Mail.ScriptedImapServer`. Every backfill here runs with
  `runner: :inline` (in the test process, inside the sandbox) except the one
  test that proves the default runner works under `Platform.TaskSupervisor`.

  ## The seed

  INBOX gets seven messages, delivered in THIS order (UIDs 1..7):

      uid 1: 3 days ago     uid 2: 40 days ago   uid 3: 8 days ago
      uid 4: 14 days ago    uid 5: 50 days ago   uid 6: 20 days ago
      uid 7: 60 days ago

  then one live poll records the cursor at UID 7 and ingests nothing (first
  contact). The order is deliberate: the highest UID is an OLD message, so
  the highest UID a 30-day backfill imports (6) is BELOW the cursor. A
  backfill that wrote the cursor to the max UID it saw would move it
  backwards, which the cursor test sees; with the newest message last, that
  write would be a no-op and the test could not tell.

  async: false — the labeler stub and the experiment fixtures are installed
  through Application env, and the default-runner test needs the shared
  sandbox.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Experiments.Signals
  alias Platform.Experiments.Signals.MailSource
  alias Platform.Mail
  alias Platform.Mail.BackfillRun
  alias Platform.Mail.FolderCursor
  alias Platform.Mail.Imap.FakeClient
  alias Platform.Mail.Imap.WireClient
  alias Platform.Mail.Inbound
  alias Platform.Mail.InboundMessage
  alias Platform.Mail.ScriptedImapServer
  alias Platform.Test.ExperimentsLabelerStub, as: Stub
  alias Platform.Test.ExperimentsMailFixtures
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # A FakeClient wrapper with two hooks, both read from the CALLING process's
  # dictionary (the backfill runs inline in the test process):
  #
  #   * `:backfill_race_raw` — delivered to INBOX inside `uids_since/2`, i.e.
  #     AFTER the backfill read the cursor snapshot and before it searched;
  #   * `:backfill_fail_uid` — `fetch_raw/2` of that UID fails.
  defmodule HookClient do
    @moduledoc false
    @behaviour Platform.Mail.Imap.Client

    alias Platform.Mail.Imap.FakeClient

    @impl true
    defdelegate connect(params), to: FakeClient
    @impl true
    defdelegate list_folders(conn), to: FakeClient
    @impl true
    defdelegate examine(conn, folder), to: FakeClient
    @impl true
    defdelegate uids_after(conn, uid), to: FakeClient
    @impl true
    defdelegate logout(conn), to: FakeClient

    @impl true
    def uids_since(conn, date) do
      case Process.delete(:backfill_race_raw) do
        nil -> :ok
        raw -> FakeClient.deliver(conn.host, "INBOX", raw)
      end

      FakeClient.uids_since(conn, date)
    end

    @impl true
    def fetch_raw(conn, uid) do
      if Process.get(:backfill_fail_uid) == uid,
        do: {:error, :boom},
        else: FakeClient.fetch_raw(conn, uid)
    end
  end

  @to ExperimentsMailFixtures.address()
  @recent_days [3, 8, 14, 20]
  @seed_days [3, 40, 8, 14, 50, 20, 60]

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp user!(org_id, role) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "backfill-#{n}@example.com",
        name: "Backfill #{n}",
        oidc_sub: "oidc-backfill-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
    |> Repo.insert!()

    user
  end

  defp account!(ctx, overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          "name" => "backfill-#{n}",
          "smtp_tls" => "starttls",
          "username" => @to,
          "imap_host" => "imap-bf-#{n}.acme.test",
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

  defp raw(message_id, subject \\ "Re: your application") do
    "From: Recruiter <recruiter@corp.test>\r\nTo: #{@to}\r\n" <>
      "Subject: #{subject}\r\nDate: Tue, 22 Sep 2026 10:00:00 +0000\r\n" <>
      "Message-ID: <#{message_id}>\r\n\r\nThanks, we received it.\r\n"
  end

  defp days_ago(n), do: Date.add(Date.utc_today(), -n)

  defp seed_id(days), do: "bf-#{days}d@corp.test"

  # Seven messages in @seed_days order; returns %{days_ago => uid}.
  defp seed_fake!(host) do
    Map.new(@seed_days, fn days ->
      {days, FakeClient.deliver(host, "INBOX", raw(seed_id(days)), internaldate: days_ago(days))}
    end)
  end

  defp poll!(account, client \\ FakeClient) do
    {:ok, summary} = Inbound.poll(Repo.reload!(account), client: client)
    summary
  end

  defp rows(account) do
    Repo.all(from(m in InboundMessage, where: m.account_id == ^account.id, order_by: m.uid))
  end

  defp cursor(account, folder \\ "INBOX"),
    do: Repo.get_by!(FolderCursor, account_id: account.id, folder: folder)

  defp chat_count, do: Repo.aggregate(Message, :count)

  defp runs(account),
    do: Repo.all(from(r in BackfillRun, where: r.account_id == ^account.id))

  defp backfill!(ctx, opts \\ []) do
    {window, opts} = Keyword.pop(opts, :window, 30)

    assert {:ok, %BackfillRun{} = run} =
             Mail.start_backfill(
               ctx.admin,
               Repo.reload!(ctx.account),
               window,
               Keyword.merge([runner: :inline], opts)
             )

    run
  end

  setup do
    org_id = Tenancy.get_org_by_slug!("initech").id
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{name: "Backfill #{n}", slug: "backfill-#{n}", kind: "channel"})

    %{org_id: org_id, admin: user!(org_id, "admin"), space: space, account: nil}
  end

  # The standard rig: INBOX seeded, one live poll done, cursor at 7.
  defp rig(ctx, overrides \\ %{}) do
    account = account!(ctx, overrides)
    FakeClient.start_server!(account.imap_host)
    FakeClient.put_folder(account.imap_host, "INBOX", uidvalidity: 7)
    uids = seed_fake!(account.imap_host)

    assert %{ingested: 0} = poll!(account)
    assert %FolderCursor{uidvalidity: 7, last_uid: 7} = cursor(account)
    assert rows(account) == []

    Map.merge(ctx, %{account: account, uids: uids, host: account.imap_host})
  end

  # ── window ────────────────────────────────────────────────────────────────

  describe "the window" do
    setup ctx, do: rig(ctx)

    test "a 30-day run imports exactly the 4 of 7 messages inside the window", ctx do
      run = backfill!(ctx)

      assert run.status == "done"
      assert run.total == 4
      assert run.imported == 4
      assert run.already_present == 0
      assert run.folders == ["INBOX"]
      assert run.skipped_folders == []
      assert run.since_date == days_ago(30)
      assert %DateTime{} = run.finished_at

      imported = rows(ctx.account)
      assert length(imported) == 4

      assert imported |> Enum.map(& &1.message_id_key) |> Enum.sort() ==
               @recent_days |> Enum.map(&seed_id/1) |> Enum.sort()

      assert Enum.map(imported, & &1.uid) == Enum.sort(Enum.map(@recent_days, &ctx.uids[&1]))
      assert Enum.all?(imported, &(&1.ingest_source == "backfill"))
    end

    test "a second run imports 0 and reports the 4 as already present", ctx do
      first = backfill!(ctx)
      assert first.imported == 4

      second = backfill!(ctx)
      assert second.id != first.id
      assert second.status == "done"
      assert second.total == 4
      assert second.imported == 0
      assert second.already_present == 4
      assert length(rows(ctx.account)) == 4
    end

    test "a 1-day window imports nothing from this seed", ctx do
      run = backfill!(ctx, window: 1)
      assert run.status == "done"
      assert run.imported == 0
      assert rows(ctx.account) == []
    end

    test "mail the live poller already stored counts as already present", ctx do
      # Stored by the live path first (as if polled), keyed by Message-ID.
      1 = Inbound.ingest(ctx.account, "INBOX", 7, ctx.uids[3], raw(seed_id(3)))
      chat_after_live = chat_count()

      run = backfill!(ctx)
      assert run.imported == 3
      assert run.already_present == 1

      [live] = Enum.filter(rows(ctx.account), &(&1.message_id_key == seed_id(3)))
      assert live.ingest_source == "poll"
      assert chat_count() == chat_after_live
    end
  end

  # ── quiet ─────────────────────────────────────────────────────────────────

  describe "quiet" do
    setup ctx do
      ctx = rig(ctx)
      ExperimentsMailFixtures.scientist!()

      :ok =
        Stub.install!(
          Stub.json(%{
            "label" => "other",
            "subject_id" => nil,
            "confidence" => 0.5,
            "reason" => "stub"
          })
        )

      Map.put(ctx, :experiment, ExperimentsMailFixtures.mail_experiment!(%{org_id: ctx.org_id}))
    end

    test "no chat post, no ingest broadcast, no signal, no labeler call", ctx do
      # The live path WOULD post here: a live, non-archived inbound space.
      account = Repo.reload!(ctx.account)
      assert account.inbound_space_id == ctx.space.id
      assert %Chat.Space{archived_at: nil} = Repo.get!(Chat.Space, ctx.space.id)

      :ok = Inbound.subscribe()
      chat_before = chat_count()

      run = backfill!(ctx)
      assert run.imported == 4

      assert chat_count() == chat_before
      refute_receive {:mail_inbound_ingested, _}, 200

      imported = rows(account)
      assert length(imported) == 4
      assert Enum.all?(imported, &is_nil(&1.chat_message_id))
      assert Enum.all?(imported, &(&1.ingest_source == "backfill"))

      assert MailSource.reconcile() == 0
      refute_received {:labeler_stub_called, _, _, _}
      assert Signals.list(ctx.experiment) == []

      # Positive control: the same experiment DOES pick up live mail to the
      # same address, so the zero above is the exclusion, not a non-match.
      FakeClient.deliver(ctx.host, "INBOX", raw("live-1@corp.test"))
      assert %{ingested: 1} = poll!(account)
      assert chat_count() == chat_before + 1
      assert_receive {:mail_inbound_ingested, %{account_id: account_id}}
      assert account_id == account.id

      assert MailSource.reconcile() == 1
      assert_received {:labeler_stub_called, _, _, _}
      assert [signal] = Signals.list(ctx.experiment)

      assert signal.source_id ==
               Repo.get_by!(InboundMessage, message_id_key: "live-1@corp.test").id
    end
  end

  # ── cursor ────────────────────────────────────────────────────────────────

  describe "the cursor" do
    setup ctx, do: rig(ctx)

    test "is byte-for-byte unchanged by a run; the live poll then still posts", ctx do
      before = cursor(ctx.account)

      run = backfill!(ctx)
      assert run.imported == 4

      after_run = cursor(ctx.account)

      assert Map.take(after_run, [
               :id,
               :folder,
               :uidvalidity,
               :last_uid,
               :inserted_at,
               :updated_at
             ]) ==
               Map.take(before, [:id, :folder, :uidvalidity, :last_uid, :inserted_at, :updated_at])

      assert Repo.aggregate(
               from(c in FolderCursor, where: c.account_id == ^ctx.account.id),
               :count
             ) == 1

      chat_before = chat_count()
      new_uid = FakeClient.deliver(ctx.host, "INBOX", raw("after-bf@corp.test"))
      assert new_uid == 8

      assert %{ingested: 1} = poll!(ctx.account)
      assert chat_count() == chat_before + 1
      assert cursor(ctx.account).last_uid == 8

      live = Repo.get_by!(InboundMessage, message_id_key: "after-bf@corp.test")
      assert live.ingest_source == "poll"
      refute is_nil(live.chat_message_id)
    end
  end

  # ── race ──────────────────────────────────────────────────────────────────

  describe "a message arriving during the run" do
    setup ctx, do: rig(ctx)

    test "is left to the live poller, which posts it once", ctx do
      # Arrives after the snapshot (cursor read) and before the search; its
      # internal date is today, so SINCE matches it.
      Process.put(:backfill_race_raw, raw("race@corp.test"))

      run = backfill!(ctx, client: HookClient)
      refute Process.get(:backfill_race_raw), "the hook never fired"

      assert run.imported == 4
      assert run.total == 4
      refute Repo.get_by(InboundMessage, message_id_key: "race@corp.test")

      chat_before = chat_count()
      assert %{ingested: 1} = poll!(ctx.account)
      assert chat_count() == chat_before + 1

      race = Repo.get_by!(InboundMessage, message_id_key: "race@corp.test")
      assert race.ingest_source == "poll"
      refute is_nil(race.chat_message_id)

      # A second poll posts nothing more.
      assert %{ingested: 0} = poll!(ctx.account)
      assert chat_count() == chat_before + 1
    end
  end

  # ── read-only, on the wire ────────────────────────────────────────────────

  describe "read-only on the wire" do
    test "EXAMINE and UID SEARCH SINCE only; no SELECT/STORE/COPY/MOVE/EXPUNGE; nothing \\Seen",
         ctx do
      server = ScriptedImapServer.start!()

      uids =
        for days <- @seed_days do
          ScriptedImapServer.deliver(server, "INBOX", raw(seed_id(days)),
            internaldate: days_ago(days)
          )
        end

      account =
        account!(ctx, %{
          "imap_host" => "127.0.0.1",
          "imap_port" => ScriptedImapServer.port(server),
          "imap_tls" => "none"
        })

      assert %{ingested: 0} = poll!(account, WireClient)
      ctx = %{ctx | account: account}

      chat_before = chat_count()
      run = backfill!(ctx, client: WireClient)

      assert run.status == "done"
      assert run.imported == 4
      assert chat_count() == chat_before

      commands = ScriptedImapServer.commands(server)

      assert Enum.any?(commands, &String.starts_with?(&1, "EXAMINE "))
      assert Enum.any?(commands, &String.starts_with?(&1, "UID SEARCH SINCE "))

      for command <- commands do
        refute command =~ ~r/\A(UID )?(SELECT|STORE|COPY|MOVE|EXPUNGE)\b/i,
               "mailbox-changing command sent: #{inspect(command)}"
      end

      fetches = Enum.filter(commands, &(&1 =~ ~r/FETCH/i))
      assert length(fetches) == 4
      assert Enum.all?(fetches, &(&1 =~ "(BODY.PEEK[])"))

      for uid <- uids do
        refute "\\Seen" in ScriptedImapServer.flags(server, "INBOX", uid)
      end
    end
  end

  # ── folder skips ──────────────────────────────────────────────────────────

  describe "folders" do
    test "a \\All folder is skipped even when configured; a folder with no cursor is skipped",
         ctx do
      account =
        account!(ctx, %{"read_folders" => ["INBOX", "[Gmail]/All Mail", "Jobs"]})

      host = account.imap_host
      FakeClient.start_server!(host)
      FakeClient.put_folder(host, "INBOX")
      FakeClient.put_folder(host, "[Gmail]/All Mail", flags: ["\\All", "\\HasNoChildren"])

      FakeClient.deliver(host, "INBOX", raw("in@corp.test"), internaldate: days_ago(5))

      FakeClient.deliver(host, "[Gmail]/All Mail", raw("all@corp.test"),
        internaldate: days_ago(5)
      )

      # The live poll reads the configured All Mail and records its cursor.
      assert %{folders: ["INBOX", "[Gmail]/All Mail"], ingested: 0} = poll!(account)
      assert cursor(account, "[Gmail]/All Mail")

      # Jobs appears after the last poll: no cursor yet.
      FakeClient.put_folder(host, "Jobs", flags: ["\\HasNoChildren"])
      FakeClient.deliver(host, "Jobs", raw("jobs@corp.test"), internaldate: days_ago(5))

      calls_before = length(FakeClient.calls(host))
      run = backfill!(%{ctx | account: account})
      backfill_calls = Enum.drop(FakeClient.calls(host), calls_before)

      assert run.status == "done"
      assert run.folders == ["INBOX"]
      assert run.imported == 1

      assert Enum.sort(run.skipped_folders) ==
               Enum.sort(["[Gmail]/All Mail (all-mail)", "Jobs (not-yet-polled)"])

      refute Enum.any?(backfill_calls, &match?({:examine, "[Gmail]/All Mail"}, &1))
      refute Repo.get_by(InboundMessage, message_id_key: "all@corp.test")
      refute Repo.get_by(InboundMessage, message_id_key: "jobs@corp.test")
      refute Repo.get_by(FolderCursor, account_id: account.id, folder: "Jobs")
    end

    test "a folder whose UIDVALIDITY changed since the last poll is skipped", ctx do
      ctx = rig(ctx)
      before = cursor(ctx.account)
      FakeClient.renumber(ctx.host, "INBOX", 99)

      run = backfill!(ctx)

      assert run.status == "done"
      assert run.folders == []
      assert run.skipped_folders == ["INBOX (uidvalidity-changed)"]
      assert run.imported == 0
      assert cursor(ctx.account) == before
    end
  end

  # ── refusals and the lock ─────────────────────────────────────────────────

  describe "start_backfill/4 refusals" do
    setup ctx, do: rig(ctx)

    test "a non-admin member is unauthorized and nothing is written", ctx do
      member = user!(ctx.org_id, "member")

      assert {:error, :unauthorized} =
               Mail.start_backfill(member, ctx.account, 30, runner: :inline)

      assert runs(ctx.account) == []
      assert rows(ctx.account) == []
    end

    test "an admin of another org is unauthorized", ctx do
      other_org_id =
        Platform.TenancyFixtures.tenant_org_id("bf-other-#{System.unique_integer([:positive])}")

      outsider = user!(other_org_id, "admin")

      assert {:error, :unauthorized} =
               Mail.start_backfill(outsider, ctx.account, 30, runner: :inline)

      assert runs(ctx.account) == []
    end

    test "windows outside 1..30 are refused, not clamped", ctx do
      for bad <- [0, 31, -1, 365, "30", 7.5, nil] do
        assert {:error, :invalid_window} =
                 Mail.start_backfill(ctx.admin, ctx.account, bad, runner: :inline),
               "window #{inspect(bad)} was accepted"
      end

      assert runs(ctx.account) == []
      assert rows(ctx.account) == []
    end

    test "an ineligible account is refused", ctx do
      ctx.account |> Ecto.Changeset.change(read_enabled: false) |> Repo.update!()

      assert {:error, :not_eligible} =
               Mail.start_backfill(ctx.admin, ctx.account, 30, runner: :inline)

      assert runs(ctx.account) == []
    end

    test "a second start while one is running is :already_running", ctx do
      running = insert_run!(ctx.account, DateTime.utc_now())

      assert {:error, :already_running} =
               Mail.start_backfill(ctx.admin, ctx.account, 30, runner: :inline)

      assert [only] = runs(ctx.account)
      assert only.id == running.id
      assert only.status == "running"
      assert rows(ctx.account) == []
    end

    test "a finished run does not block a new one", ctx do
      assert backfill!(ctx).status == "done"
      assert backfill!(ctx).status == "done"
      assert length(runs(ctx.account)) == 2
    end

    test "a stale running row is reaped as interrupted, then the new run proceeds", ctx do
      stale = insert_run!(ctx.account, DateTime.add(DateTime.utc_now(), -11 * 60, :second))

      run = backfill!(ctx)
      assert run.status == "done"
      assert run.imported == 4

      reaped = Repo.get!(BackfillRun, stale.id)
      assert reaped.status == "failed"
      assert reaped.error == "interrupted"
      assert %DateTime{} = reaped.finished_at
    end

    test "a running row younger than 10 minutes is not reaped", ctx do
      fresh = insert_run!(ctx.account, DateTime.add(DateTime.utc_now(), -9 * 60, :second))

      assert {:error, :already_running} =
               Mail.start_backfill(ctx.admin, ctx.account, 30, runner: :inline)

      assert Repo.get!(BackfillRun, fresh.id).status == "running"
    end
  end

  defp insert_run!(account, updated_at) do
    Repo.insert!(%BackfillRun{
      account_id: account.id,
      org_id: account.org_id,
      window_days: 30,
      since_date: days_ago(30),
      status: "running",
      started_at: updated_at,
      inserted_at: updated_at,
      updated_at: updated_at
    })
  end

  # ── progress, failure, reads ──────────────────────────────────────────────

  describe "progress and failure" do
    setup ctx, do: rig(ctx)

    test "progress is broadcast with ids only on the account's topic", ctx do
      :ok = Mail.subscribe_backfill(ctx.account.id)
      run = backfill!(ctx)

      assert_receive {:mail_backfill_progress, payload}
      assert payload == %{run_id: run.id, account_id: ctx.account.id}
    end

    test "a fetch error ends the run failed with the counts so far; a re-run finishes", ctx do
      # UIDs in the window, ascending: 1, 3, 4, 6. Fail the third.
      Process.put(:backfill_fail_uid, ctx.uids[14])

      failed = backfill!(ctx, client: HookClient)
      assert failed.status == "failed"
      assert failed.imported == 2
      assert failed.total == 4
      assert failed.error =~ "fetch failed in INBOX"
      assert %DateTime{} = failed.finished_at

      Process.delete(:backfill_fail_uid)
      again = backfill!(ctx, client: HookClient)
      assert again.status == "done"
      assert again.imported == 2
      assert again.already_present == 2
      assert length(rows(ctx.account)) == 4
    end

    test "latest_backfill/2 returns the newest run to an admin and nil to anyone else", ctx do
      assert Mail.latest_backfill(ctx.admin, ctx.account) == nil

      _first = backfill!(ctx)
      second = backfill!(ctx)

      assert %BackfillRun{id: id} = Mail.latest_backfill(ctx.admin, ctx.account)
      assert id == second.id

      member = user!(ctx.org_id, "member")
      assert Mail.latest_backfill(member, ctx.account) == nil
    end

    test "the default runner completes the run under Platform.TaskSupervisor", ctx do
      :ok = Mail.subscribe_backfill(ctx.account.id)

      assert {:ok, %BackfillRun{status: "running", id: id}} =
               Mail.start_backfill(ctx.admin, ctx.account, 30)

      assert_eventually(fn -> Repo.get!(BackfillRun, id).status == "done" end)
      assert_receive {:mail_backfill_progress, %{run_id: ^id}}
      assert Repo.get!(BackfillRun, id).imported == 4
    end
  end
end
