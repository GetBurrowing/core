defmodule Platform.Mail.TriageTest do
  @moduledoc """
  `Platform.Mail.Triage` (task 01a1f426 stage 1): which mailboxes a
  reader's triage covers, what is stored, and what never leaves the
  mailbox.

  ## Permission

  The world: org admin A, member B. B owns personal mailbox B-box (granted
  to the triage agent by B). Shared mailbox S is read by A and granted to
  the agent. A owns personal mailbox A2, NOT granted to the agent. Only S
  may produce an item for A:

    * B-box is the "admin confers nothing" case — removing the
      `readable_account_ids` term from `Triage.eligible_accounts_query/3`
      turns the B-box tests red;
    * A2 is the "an agent uses only mail it has been granted" case —
      removing the `agent_granted` term turns the A2 tests red.

  ## Sentinel

  A unique sentinel sits in the body and the subject of an email AND in the
  model's `why`. With Logger at `:debug` (Ecto's query log on), a handler
  on `[:platform, :repo, :query]` (query AND params) and on
  `[:platform, :mail, :triage, :classified]`, the `Inbound.topic()`
  subscription, `audit_events` and `experiment_signals`, the sentinel
  appears nowhere outside the stored item. Positive controls prove each
  channel was live.

  async: false — the stub provider, the Logger level and `:mail_enabled`
  are application-wide.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog
  import Platform.TenancyFixtures
  import Platform.Test.MailPrivacyFixtures
  import Platform.Test.MailTriageFixtures

  alias Platform.Mail.Inbound
  alias Platform.Mail.Triage
  alias Platform.Mail.Triage.{Feedback, Item}
  alias Platform.Test.MailTriageStub, as: Stub

  setup do
    enable_mail!()
    org_id = acme_org_id()
    n = unique()

    a = user!("a") |> member!(org_id, "admin")
    b = user!("b") |> member!(org_id)
    agent = triage_agent!()

    b_box = account!(a, org_id, %{"name" => "B box #{n}"}) |> then(&personal!(a, &1, b))
    grant_agent!(b, b_box, agent)

    shared = account!(a, org_id, %{"name" => "Shared #{n}"}) |> then(&shared!(a, &1, [a]))
    grant_agent!(a, shared, agent)

    a2 = account!(a, org_id, %{"name" => "A2 #{n}"}) |> then(&personal!(a, &1, a))

    :ok = Stub.install!(Stub.json(verdict()))

    %{org_id: org_id, n: n, a: a, b: b, agent: agent, b_box: b_box, shared: shared, a2: a2}
  end

  defp run(user, opts \\ []) do
    now = DateTime.utc_now()

    Triage.run_for_reader(
      user,
      Date.utc_today(),
      Keyword.merge(
        [since: DateTime.add(now, -3600, :second), until: DateTime.add(now, 3600, :second)],
        opts
      )
    )
  end

  defp items_for(user), do: Repo.all(from(i in Item, where: i.user_id == ^user.id))

  defp stub_calls do
    receive do
      {:mail_triage_stub_called, _c, messages, _o} -> [messages | stub_calls()]
    after
      0 -> []
    end
  end

  defp seen(calls), do: inspect(calls, limit: :infinity, printable_limit: :infinity)

  # ── permission ──────────────────────────────────────────────────────────

  describe "permission" do
    setup ctx do
      %{
        in_b: inbound!(ctx.b_box, %{text_body: "B-BOX-#{ctx.n}"}),
        in_s: inbound!(ctx.shared, %{text_body: "SHARED-#{ctx.n}"}),
        in_a2: inbound!(ctx.a2, %{text_body: "A2-#{ctx.n}"})
      }
    end

    test "eligible_account_ids is exactly the readable AND granted mailboxes", ctx do
      assert Triage.eligible_account_ids(ctx.a, ctx.org_id, ctx.agent) == [ctx.shared.id]
      # B reads B-box (owner) and it is granted; S and A2 are not B's.
      assert Triage.eligible_account_ids(ctx.b, ctx.org_id, ctx.agent) == [ctx.b_box.id]
      assert Triage.eligible_account_ids(ctx.a, ctx.org_id, nil) == []
    end

    test "run_for_reader triages only mailboxes the reader reads AND the agent is granted", ctx do
      assert {:ok, %{status: :ok, classified: 1, model_calls: 1}} = run(ctx.a)

      assert [%Item{account_id: account_id, inbound_message_id: inbound_id}] = items_for(ctx.a)
      assert account_id == ctx.shared.id
      assert inbound_id == ctx.in_s.id

      calls = seen(stub_calls())
      assert calls =~ "SHARED-#{ctx.n}"
      refute calls =~ "B-BOX-#{ctx.n}"
      refute calls =~ "A2-#{ctx.n}"
    end

    test "a mailbox the reader reads but the agent is NOT granted: no item, no provider call",
         ctx do
      assert {:error, :not_eligible} = Triage.classify_for_reader(ctx.a, ctx.in_a2)
      assert stub_calls() == []
      assert items_for(ctx.a) == []
    end

    test "org admin status confers nothing on another member's personal mailbox", ctx do
      assert {:error, :not_eligible} = Triage.classify_for_reader(ctx.a, ctx.in_b)
      assert stub_calls() == []
      assert items_for(ctx.a) == []

      # Positive control: B, who reads B-box, is triaged on it.
      assert {:ok, %Item{account_id: account_id}} = Triage.classify_for_reader(ctx.b, ctx.in_b)
      assert account_id == ctx.b_box.id
    end

    test "called_out hides an item at once when the agent's grant is revoked", ctx do
      assert {:ok, %Item{tier: "action"}} = Triage.classify_for_reader(ctx.a, ctx.in_s)
      assert [%Item{}] = Triage.called_out(ctx.a, Date.utc_today())

      {:ok, _} = Platform.Mail.Ownership.revoke(ctx.a, ctx.shared, {:agent, ctx.agent.id})
      assert Triage.called_out(ctx.a, Date.utc_today()) == []
    end

    test "no triage agent: nothing is classified and the run says so", ctx do
      Platform.Roles.clear_override("mail.triage")
      assert {:ok, %{status: :no_triage_agent, classified: 0}} = run(ctx.a)
      assert stub_calls() == []
      assert {:error, :no_triage_agent} = Triage.classify_for_reader(ctx.a, ctx.in_s)
    end
  end

  # ── storage outcomes ────────────────────────────────────────────────────

  describe "outcomes" do
    test "run_for_reader is idempotent per reader and email", ctx do
      inbound!(ctx.shared)
      assert {:ok, %{classified: 1}} = run(ctx.a)
      assert {:ok, %{classified: 0, model_calls: 0}} = run(ctx.a)
      assert length(stub_calls()) == 1
      assert length(items_for(ctx.a)) == 1
    end

    test "a backfilled import is not triaged", ctx do
      inbound!(ctx.shared, %{ingest_source: "backfill"})
      assert {:ok, %{classified: 0}} = run(ctx.a)
      assert stub_calls() == []
    end

    test "the model budget defers the rest to the next run", ctx do
      for _ <- 1..3, do: inbound!(ctx.shared)
      assert {:ok, %{classified: 2, model_calls: 2, deferred: 1}} = run(ctx.a, max_model_calls: 2)
      assert {:ok, %{classified: 1}} = run(ctx.a)
    end

    test "a rejected output stores no model text", ctx do
      leaked = "MODEL-PROSE-#{ctx.n}"
      Stub.reply!(fn _c, _m, _o -> {:ok, %{content: "Sure! #{leaked} is important."}} end)
      inbound = inbound!(ctx.shared)

      log =
        capture_log(fn ->
          assert {:ok, %Item{} = item} = Triage.classify_for_reader(ctx.a, inbound)
          assert item.why == nil
          assert item.tier == "routine"
          assert %{"kind" => "rejected_output"} in item.signals
          refute inspect(item) =~ leaked
        end)

      refute log =~ leaked
      assert log =~ "rejected_output"
    end

    test "a provider error stores nothing, and the next run retries", ctx do
      Stub.reply!(fn _c, _m, _o -> {:error, :timeout} end)
      inbound = inbound!(ctx.shared)

      capture_log(fn ->
        assert {:error, :provider_failed} = Triage.classify_for_reader(ctx.a, inbound)
      end)

      assert items_for(ctx.a) == []

      Stub.reply!(Stub.json(verdict()))
      assert {:ok, %{classified: 1}} = run(ctx.a)
    end

    test "the pre-filter answers bulk mail with no model call", ctx do
      inbound!(ctx.shared, %{raw: raw(["List-Unsubscribe: <mailto:u@list.test>"])})
      inbound!(ctx.shared, %{raw: raw(["Precedence: bulk"])})
      inbound!(ctx.shared, %{from_address: "Shop <no-reply@shop.test>"})

      assert {:ok, %{classified: 3, model_calls: 0}} = run(ctx.a)
      assert stub_calls() == []

      assert ctx.a |> items_for() |> Enum.map(&{&1.classifier, &1.tier}) |> Enum.sort() == [
               {"rule:list_unsubscribe", "promo"},
               {"rule:noreply_sender", "routine"},
               {"rule:precedence_bulk", "promo"}
             ]
    end

    test "a reply we were waiting on is at least action, even with a bulk header", ctx do
      delivery!(ctx.shared, "Counsel <counsel@otherco.test>")
      Stub.reply!(Stub.json(verdict(%{"tier" => "routine", "needs" => "none"})))

      inbound =
        inbound!(ctx.shared, %{
          from_address: "counsel@otherco.test",
          raw: raw(["List-Unsubscribe: <mailto:u@otherco.test>"])
        })

      assert {:ok, %Item{tier: "action"} = item} = Triage.classify_for_reader(ctx.a, inbound)
      assert item.classifier =~ ~r/\Aagent:.+@v1\z/
      assert Enum.any?(item.signals, &(&1["kind"] == "waiting_on"))
      assert [_] = stub_calls()
    end

    test "a waiting-on reply the model calls top stays top", ctx do
      delivery!(ctx.shared, "counsel@otherco.test")
      Stub.reply!(Stub.json(verdict(%{"tier" => "top"})))
      inbound = inbound!(ctx.shared, %{from_address: "counsel@otherco.test"})
      assert {:ok, %Item{tier: "top"}} = Triage.classify_for_reader(ctx.a, inbound)
    end
  end

  # ── feedback ────────────────────────────────────────────────────────────

  describe "feedback" do
    test "two not_important verdicts demote the sender's domain with no model call", ctx do
      first = inbound!(ctx.shared, %{from_address: "news@vendor.test"})
      second = inbound!(ctx.shared, %{from_address: "deals@vendor.test"})
      {:ok, item} = Triage.classify_for_reader(ctx.a, first)
      _ = stub_calls()

      assert {:ok, %Feedback{verdict: "not_important", sender_domain: "vendor.test"}} =
               Triage.record_feedback(ctx.a, item, "not_important")

      assert Repo.get!(Item, item.id).status == "dismissed"
      assert {:ok, _} = Triage.record_feedback(ctx.a, second, "not_important")

      third = inbound!(ctx.shared, %{from_address: "news@vendor.test"})

      assert {:ok, %Item{tier: "routine", classifier: "rule:feedback_not_important"}} =
               Triage.classify_for_reader(ctx.a, third)

      assert stub_calls() == []
    end

    test "a missed verdict promotes the sender to at least action and reaches the model", ctx do
      Stub.reply!(Stub.json(verdict(%{"tier" => "routine", "needs" => "none"})))
      first = inbound!(ctx.shared, %{from_address: "ops@client.test"})
      {:ok, item} = Triage.classify_for_reader(ctx.a, first)
      assert item.tier == "routine"
      _ = stub_calls()

      assert {:ok, %Feedback{verdict: "missed"}} = Triage.record_feedback(ctx.a, item, "missed")
      assert Repo.get!(Item, item.id).tier == "action"

      second =
        inbound!(ctx.shared, %{
          from_address: "ops@client.test",
          raw: raw(["List-Unsubscribe: <mailto:u@client.test>"])
        })

      assert {:ok, %Item{tier: "action"}} = Triage.classify_for_reader(ctx.a, second)
      [[_system, user]] = stub_calls()
      assert user.content =~ ~s("reader_said_earlier_email_needed_them":true)
    end

    test "feedback on an email the reader cannot read is refused and writes nothing", ctx do
      in_b = inbound!(ctx.b_box)
      assert {:error, :not_found} = Triage.record_feedback(ctx.a, in_b, "missed")
      assert {:error, :not_found} = Triage.record_feedback(ctx.a, Ecto.UUID.generate(), "missed")
      assert {:error, :not_found} = Triage.record_feedback(ctx.a, "not-a-uuid", "missed")
      assert {:error, :invalid_verdict} = Triage.record_feedback(ctx.a, in_b, "spam")
      assert Repo.aggregate(Feedback, :count) == 0
    end

    test "feedback on another reader's item is refused", ctx do
      in_b = inbound!(ctx.b_box)
      {:ok, b_item} = Triage.classify_for_reader(ctx.b, in_b)
      assert {:error, :not_found} = Triage.record_feedback(ctx.a, b_item, "not_important")
      assert Repo.get!(Item, b_item.id).status == "open"
    end
  end

  # ── sentinel ────────────────────────────────────────────────────────────

  describe "message bodies never leave the mailbox" do
    setup do
      previous = Logger.level()
      on_exit(fn -> Logger.configure(level: previous) end)

      test_pid = self()
      handler = "mail-triage-sentinel-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach_many(
          handler,
          [[:platform, :repo, :query], [:platform, :mail, :triage, :classified]],
          fn event, measurements, metadata, _ ->
            # `:result` is the rows a read returned to its own caller; the
            # assertion is about what a handler would SHIP, which is the
            # query, its params and the event metadata.
            send(test_pid, {:telemetry_seen, event, measurements, Map.delete(metadata, :result)})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "the sentinel appears in no log, telemetry, PubSub, audit row or signal", ctx do
      sentinel = "SENTINEL-#{Ecto.UUID.generate()}"
      :ok = Inbound.subscribe()
      Stub.reply!(Stub.json(verdict(%{"why" => "Asks about #{sentinel} today."})))

      inbound =
        inbound!(ctx.shared, %{
          subject: "Re: #{sentinel}",
          text_body: "Please confirm #{sentinel} by Friday.",
          raw: raw([], "Please confirm #{sentinel} by Friday.")
        })

      # The fixture's own INSERT is the test writing mail into the mailbox,
      # not the triage leaking it: drop what it emitted before measuring.
      _ = collect_telemetry()

      # Logger at :debug (Ecto's query log on) only around the code under
      # test, so the test's own fixture and assertion queries stay quiet.
      previous = Logger.level()
      Logger.configure(level: :debug)

      log =
        try do
          capture_log([level: :debug], fn ->
            assert {:ok, %{classified: 1}} = run(ctx.a)
            assert [%Item{} = item] = Triage.called_out(ctx.a, Date.utc_today())
            assert {:ok, _} = Triage.record_feedback(ctx.a, item, "not_important")
          end)
        after
          Logger.configure(level: previous)
        end

      # Positive controls: the sentinel really flowed through the model call
      # and into the stored item, and the debug query log was really on.
      assert seen(stub_calls()) =~ sentinel
      assert Repo.get_by!(Item, inbound_message_id: inbound.id).why =~ sentinel
      assert log =~ "mail_triage"
      assert log =~ "[Mail.Triage] classified"

      refute log =~ sentinel

      telemetry = collect_telemetry()
      assert Enum.any?(telemetry, &match?({[:platform, :repo, :query], _, _}, &1))
      assert Enum.any?(telemetry, &match?({[:platform, :mail, :triage, :classified], _, _}, &1))

      for {event, _m, metadata} <- telemetry do
        refute inspect(metadata, limit: :infinity, printable_limit: :infinity) =~ sentinel,
               "sentinel in #{inspect(event)} metadata (query/params)"
      end

      {:messages, mailbox} = Process.info(self(), :messages)
      refute inspect(mailbox, limit: :infinity, printable_limit: :infinity) =~ sentinel

      like = "%" <> sentinel <> "%"

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM audit_events e WHERE row_to_json(e)::text LIKE $1",
                 [like]
               )

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM experiment_signals s WHERE row_to_json(s)::text LIKE $1",
                 [like]
               )
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
