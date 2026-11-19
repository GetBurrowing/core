defmodule Platform.Mail.Triage.SubscriberTest do
  @moduledoc """
  Between-briefing notification (task 01a1f426 stage 3):
  `Platform.Mail.Triage.Subscriber` and `Platform.Mail.Triage.on_inbound/2`
  / `notify_top/2`.

  The world: reader R (a plain member) owns personal mailbox P, granted to
  the triage agent. R also owns P2, NOT granted to the agent. Shared mailbox
  S is granted to the agent and read by R and by member M until M's grant
  is revoked. Org admin A reads none of them.

  Push is recorded by a `:notifications_module` double (`Recorder`, as in
  `Platform.Tasks.SponsorAssignedInboxTest`), because the real
  `fan_out_to_user/3` short-circuits in :test.

  The "not granted" test is the mutation probe's target: removing the
  `agent_granted` term from `Triage.eligible_accounts_query/3` turns
  "a mailbox not granted to the triage agent: nothing, and no provider
  call" red. The subscriber has no grant check of its own.

  async: false — the stub provider, the Recorder, the Logger level and
  `:mail_enabled` are application-wide.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog
  import Platform.TenancyFixtures
  import Platform.Test.MailPrivacyFixtures
  import Platform.Test.MailTriageFixtures

  alias Platform.Inbox
  alias Platform.Mail.{Delivery, Inbound, Ownership, Triage}
  alias Platform.Mail.Triage.{Item, Subscriber}
  alias Platform.Memory.Insights.Disseminator
  alias Platform.Test.MailTriageStub, as: Stub

  defmodule Recorder do
    @moduledoc "Records `fan_out_to_user/3` as `{:notif, user_id, payload}` to the test pid."
    def install(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)
    def uninstall, do: :persistent_term.erase({__MODULE__, :owner})

    def fan_out_to_user(user_id, payload, _opts \\ []) do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        nil -> :ok
        owner -> send(owner, {:notif, user_id, payload})
      end

      :ok
    end
  end

  setup do
    enable_mail!()
    Application.put_env(:platform, :notifications_module, Recorder)
    Recorder.install(self())

    on_exit(fn ->
      Application.delete_env(:platform, :notifications_module)
      Recorder.uninstall()
    end)

    org_id = acme_org_id()
    n = unique()

    a = user!("a") |> member!(org_id, "admin")
    r = user!("r") |> member!(org_id)
    m = user!("m") |> member!(org_id)
    agent = triage_agent!()

    p = account!(a, org_id, %{"name" => "Pbox #{n}"}) |> then(&personal!(a, &1, r))
    grant_agent!(r, p, agent)

    p2 = account!(a, org_id, %{"name" => "P2box #{n}"}) |> then(&personal!(a, &1, r))

    s = account!(a, org_id, %{"name" => "Sbox #{n}"}) |> then(&shared!(a, &1, [r, m]))
    grant_agent!(a, s, agent)

    :ok = Stub.install!(Stub.json(verdict(%{"tier" => "top"})))

    %{org_id: org_id, n: n, a: a, r: r, m: m, agent: agent, p: p, p2: p2, s: s}
  end

  # A reply from counsel, whom `account` wrote to three days ago.
  defp waiting_reply!(account, attrs \\ %{}) do
    delivery!(account, "counsel@otherco.test")
    inbound!(account, Map.merge(%{from_address: "Counsel <counsel@otherco.test>"}, attrs))
  end

  defp broadcast!(inbound) do
    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      Inbound.topic(),
      {:mail_inbound_ingested,
       %{id: inbound.id, account_id: inbound.account_id, org_id: inbound.org_id}}
    )
  end

  defp rows_for(user) do
    Repo.all(from(i in Inbox.Item, where: i.user_id == ^user.id and i.kind == "mail_priority"))
  end

  defp items_for(user), do: Repo.all(from(i in Item, where: i.user_id == ^user.id))

  defp stub_calls do
    receive do
      {:mail_triage_stub_called, _c, messages, _o} -> [messages | stub_calls()]
    after
      0 -> []
    end
  end

  defp notifs do
    receive do
      {:notif, user_id, payload} -> [{user_id, payload} | notifs()]
    after
      0 -> []
    end
  end

  defp deliveries_count, do: Repo.aggregate(Delivery, :count)

  # ── the subscriber ──────────────────────────────────────────────────────

  describe "a top-tier email between briefings" do
    test "a waiting-on reply arriving: exactly one Inbox row and one push, to the owner", ctx do
      start_supervised!(Subscriber)

      inbound = waiting_reply!(ctx.p)
      # After the fixture's own "we wrote to them" delivery.
      before = deliveries_count()
      broadcast!(inbound)

      assert_receive {:notif, user_id, payload}, 3_000
      assert user_id == ctx.r.id
      assert payload.title == "An email needs you"
      assert payload.body == "In #{ctx.p.name}. Open the briefing to see why."
      assert payload.url == Inbox.briefing_url(Triage.briefing_today())

      assert_eventually(fn -> length(rows_for(ctx.r)) == 1 end)
      [row] = rows_for(ctx.r)
      assert row.source_type == "mail_triage_item"
      assert row.title == "An email needs you"
      assert row.url == payload.url

      [item] = items_for(ctx.r)
      assert row.source_id == item.id
      assert item.tier == "top"
      assert %DateTime{} = item.notified_at

      # Drafts only: the subscriber sent nothing.
      assert deliveries_count() == before
      refute_received {:mail_test_adapter, _, _}
      assert notifs() == []
    end

    test "a second identical event pushes nothing (notified_at)", ctx do
      inbound = waiting_reply!(ctx.p)
      assert :ok = Triage.on_inbound(inbound.id)
      assert [{_, _}] = notifs()

      assert :ok = Triage.on_inbound(inbound.id)
      start_supervised!(Subscriber)
      broadcast!(inbound)
      # The reconcile and the event both reach the row; neither notifies.
      Process.sleep(300)

      assert notifs() == []
      assert length(rows_for(ctx.r)) == 1
      assert length(items_for(ctx.r)) == 1
    end

    test "the start-up reconcile notifies a top email that has no item yet", ctx do
      waiting_reply!(ctx.p)
      start_supervised!(Subscriber)

      assert_receive {:notif, user_id, _payload}, 3_000
      assert user_id == ctx.r.id
      assert_eventually(fn -> length(rows_for(ctx.r)) == 1 end)
    end

    test "a backfilled import produces nothing", ctx do
      inbound = waiting_reply!(ctx.p, %{ingest_source: "backfill"})
      assert :ok = Triage.on_inbound(inbound.id)

      start_supervised!(Subscriber)
      broadcast!(inbound)
      Process.sleep(300)

      assert items_for(ctx.r) == []
      assert rows_for(ctx.r) == []
      assert notifs() == []
      assert stub_calls() == []
    end

    test "a shared-mailbox member whose grant was revoked gets nothing", ctx do
      {:ok, _} = Ownership.revoke(ctx.a, ctx.s, {:user, ctx.m.id})
      inbound = waiting_reply!(ctx.s)

      assert :ok = Triage.on_inbound(inbound.id)

      assert [{user_id, _}] = notifs()
      assert user_id == ctx.r.id
      assert items_for(ctx.m) == []
      assert rows_for(ctx.m) == []
      # Admin status confers nothing.
      assert items_for(ctx.a) == []
      assert rows_for(ctx.a) == []
    end

    test "a mailbox not granted to the triage agent: nothing, and no provider call", ctx do
      inbound = waiting_reply!(ctx.p2, %{text_body: "P2-ONLY-#{ctx.n}"})

      assert :ok = Triage.on_inbound(inbound.id)

      assert items_for(ctx.r) == []
      assert rows_for(ctx.r) == []
      assert notifs() == []
      refute inspect(stub_calls(), limit: :infinity) =~ "P2-ONLY-#{ctx.n}"
    end

    test "an action-tier email waits for the briefing: no row, no push", ctx do
      Stub.reply!(Stub.json(verdict(%{"tier" => "action"})))
      inbound = waiting_reply!(ctx.p)
      assert :ok = Triage.on_inbound(inbound.id)

      assert [%Item{tier: "action", notified_at: nil}] = items_for(ctx.r)
      assert rows_for(ctx.r) == []
      assert notifs() == []
    end

    test "at most 3 pushes per reader per day; the rest get the Inbox row only", ctx do
      for _ <- 1..4 do
        inbound = waiting_reply!(ctx.p)
        assert :ok = Triage.on_inbound(inbound.id)
      end

      assert length(notifs()) == Triage.push_cap_per_day()
      assert length(rows_for(ctx.r)) == 4
      assert ctx.r |> items_for() |> Enum.all?(&match?(%DateTime{}, &1.notified_at))
    end

    test "a reader who allows only direct mentions gets the row and no push", ctx do
      {:ok, _} = Platform.Accounts.put_notification_level(ctx.r, "direct")
      inbound = waiting_reply!(ctx.p)

      assert :ok = Triage.on_inbound(inbound.id)
      assert notifs() == []
      assert length(rows_for(ctx.r)) == 1
    end
  end

  # ── sentinel ────────────────────────────────────────────────────────────

  describe "the next briefing after an item classified on arrival" do
    test "a reader whose only new item was classified on arrival still gets it in the briefing",
         ctx do
      inbound = waiting_reply!(ctx.p)
      assert :ok = Triage.on_inbound(inbound.id)
      [item] = items_for(ctx.r)
      assert item.tier == "top"
      assert %DateTime{} = item.notified_at
      assert [{_, _}] = notifs()

      now = DateTime.utc_now()
      date = Triage.briefing_date(now)
      assert Triage.briefing_date(item.inserted_at) == date
      refute Triage.briefing_delivered?(ctx.r.id, date)

      # The next briefing run finds nothing NEW to classify for this reader
      # (the item already exists), and must still deliver it.
      {:ok, _} = Disseminator.run(now: now, notifications_module: Recorder)

      assert Triage.briefing_delivered?(ctx.r.id, date)
      briefing = Platform.Memory.Insights.Briefings.for_user_on(ctx.r.id, date)
      assert %Platform.Memory.Briefing{} = briefing

      assert [_] =
               Repo.all(
                 from(i in Inbox.Item,
                   where:
                     i.user_id == ^ctx.r.id and i.kind == "briefing" and
                       i.source_id == ^briefing.id
                 )
               )

      assert Enum.map(Triage.section_view(ctx.r, date).called_out, & &1.id) == [item.id]
      assert Enum.any?(notifs(), fn {user_id, _} -> user_id == ctx.r.id end)

      # Delivered once: a second run pushes this reader nothing.
      {:ok, _} = Disseminator.run(now: now, notifications_module: Recorder)
      refute Enum.any?(notifs(), fn {user_id, _} -> user_id == ctx.r.id end)
    end
  end

  describe "the notification carries no mail content" do
    setup do
      previous = Logger.level()
      on_exit(fn -> Logger.configure(level: previous) end)

      test_pid = self()
      handler = "mail-triage-notify-sentinel-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach_many(
          handler,
          [
            [:platform, :repo, :query],
            [:platform, :mail, :triage, :classified],
            [:platform, :mail, :triage, :item]
          ],
          fn event, measurements, metadata, _ ->
            send(test_pid, {:telemetry_seen, event, measurements, Map.delete(metadata, :result)})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "no subject, body, why or sender in the payload, the row, logs, telemetry or PubSub",
         ctx do
      sentinel = "sentinel-#{Ecto.UUID.generate()}"
      sender = "counsel@otherco.test"
      Stub.reply!(Stub.json(verdict(%{"tier" => "top", "why" => "Asks about #{sentinel}."})))

      inbound =
        waiting_reply!(ctx.p, %{
          subject: "Re: #{sentinel}",
          text_body: "Please confirm #{sentinel} by Friday.",
          raw: raw([], "Please confirm #{sentinel} by Friday.")
        })

      :ok = Inbox.subscribe(ctx.r.id)
      before = deliveries_count()
      _ = collect_telemetry()

      previous = Logger.level()
      Logger.configure(level: :debug)

      log =
        try do
          capture_log([level: :debug], fn ->
            assert :ok = Triage.on_inbound(inbound.id)
          end)
        after
          Logger.configure(level: previous)
        end

      # Positive controls: the sentinel reached the provider and the stored
      # item; the debug query log, the Inbox broadcast, the push and the
      # outcome telemetry were all live.
      assert inspect(stub_calls(), limit: :infinity, printable_limit: :infinity) =~ sentinel
      assert Repo.get_by!(Item, inbound_message_id: inbound.id).why =~ sentinel
      assert log =~ "mail_triage_items"
      assert log =~ "[Mail.Triage] notified"
      assert [{_, payload}] = notifs()
      inbox_broadcasts = inbox_broadcasts()
      assert [{:inbox_item_added, %Inbox.Item{kind: "mail_priority"}}] = inbox_broadcasts

      dump = &inspect(&1, limit: :infinity, printable_limit: :infinity)

      for leak <- [sentinel, sender] do
        refute dump.(payload) =~ leak, "push payload carries #{leak}"
        refute dump.(inbox_broadcasts) =~ leak, "Inbox broadcast carries #{leak}"
      end

      refute log =~ sentinel

      # The sender's address does reach Ecto's :debug query log as a bound
      # param of stage 1's context reads (waiting-on, thread); every line
      # this module writes itself is ids and codes only.
      for line <- String.split(log, "\n"), line =~ "[Mail.Triage]" do
        refute line =~ sender
      end

      [row] = rows_for(ctx.r)

      for leak <- [sentinel, sender, "Re:"] do
        refute dump.(Map.take(row, [:title, :body, :url])) =~ leak, "Inbox row carries #{leak}"
      end

      telemetry = collect_telemetry()
      assert Enum.any?(telemetry, &match?({[:platform, :repo, :query], _, _}, &1))
      assert Enum.any?(telemetry, &match?({[:platform, :mail, :triage, :item], _, _}, &1))

      for {event, _m, metadata} <- telemetry do
        refute dump.(metadata) =~ sentinel, "sentinel in #{inspect(event)} metadata"
      end

      for {[:platform, :mail, :triage, :item], _m, metadata} <- telemetry do
        assert Map.keys(metadata) |> Enum.sort() == [:org_id, :outcome, :tier]
        refute dump.(metadata) =~ sender
      end

      {:messages, mailbox} = Process.info(self(), :messages)
      refute dump.(mailbox) =~ sentinel
      refute dump.(mailbox) =~ sender

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM inbox_items i WHERE row_to_json(i)::text LIKE $1",
                 ["%" <> sentinel <> "%"]
               )

      # Drafts only.
      assert deliveries_count() == before
      refute_received {:mail_test_adapter, _, _}
    end
  end

  defp inbox_broadcasts do
    receive do
      {:inbox_item_added, _} = msg -> [msg | inbox_broadcasts()]
    after
      0 -> []
    end
  end

  defp collect_telemetry do
    receive do
      {:telemetry_seen, event, m, metadata} -> [{event, m, metadata} | collect_telemetry()]
    after
      0 -> []
    end
  end
end
