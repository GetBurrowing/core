defmodule Platform.Mail.TriageTest do
  @moduledoc """
  `Platform.Mail.Triage` (task 01a1f426 stage 1): which mailboxes a
  reader's triage covers, what is stored, and what never leaves the
  mailbox.

  ## Permission

  The world: org admin A, member B. B owns personal mailbox B-box (its
  flag-important agent set by B). Shared mailbox S is read by A and has the
  same flag agent. A owns personal mailbox A2, with NO flag agent (Off).
  Only S may produce an item for A:

    * B-box is the "admin confers nothing" case — removing the
      `readable_account_ids` term from `Triage.eligible_accounts_query/2`
      turns the B-box tests red;
    * A2 is the "Off triages nothing" case — removing the flag_important
      term turns the A2 tests red.

  ## Per-mailbox agent (task 01a1f5cc stage 2)

  Each mailbox is classified by its own flag agent; an access grant alone,
  an inactive agent, or a `mail.triage` Roles assignee triages nothing.

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

  alias Platform.Mail.{Inbound, Ownership}
  alias Platform.Mail.Triage
  alias Platform.Mail.Triage.{Classifier, Feedback, Item}
  alias Platform.Test.MailTriageStub, as: Stub

  setup do
    enable_mail!()
    org_id = acme_org_id()
    n = unique()

    a = user!("a") |> member!(org_id, "admin")
    b = user!("b") |> member!(org_id)
    agent = agent!("triage")

    b_box = account!(a, org_id, %{"name" => "B box #{n}"}) |> then(&personal!(a, &1, b))
    flag_agent!(b, b_box, agent)

    shared = account!(a, org_id, %{"name" => "Shared #{n}"}) |> then(&shared!(a, &1, [a]))
    flag_agent!(a, shared, agent)

    a2 = account!(a, org_id, %{"name" => "A2 #{n}"}) |> then(&personal!(a, &1, a))

    :ok = Stub.install!(Stub.json(verdict()))

    %{org_id: org_id, n: n, a: a, b: b, agent: agent, b_box: b_box, shared: shared, a2: a2}
  end

  defp run(user, opts \\ []) do
    now = DateTime.utc_now()

    Triage.run_for_reader(
      user,
      Triage.briefing_today(),
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

    test "eligible_account_ids is exactly the readable AND flagged mailboxes", ctx do
      assert Triage.eligible_account_ids(ctx.a, ctx.org_id) == [ctx.shared.id]
      # B reads B-box (owner) and it is flagged; S and A2 are not B's.
      assert Triage.eligible_account_ids(ctx.b, ctx.org_id) == [ctx.b_box.id]

      {:ok, _} = Ownership.set_flag_important_agent(ctx.a, ctx.shared, nil)
      assert Triage.eligible_account_ids(ctx.a, ctx.org_id) == []
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

    test "a mailbox the reader reads with no flag agent: no item, no provider call", ctx do
      assert {:error, :no_triage_agent} = Triage.classify_for_reader(ctx.a, ctx.in_a2)
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

    test "called_out hides an item at once when the mailbox is set to Off", ctx do
      assert {:ok, %Item{tier: "action"}} = Triage.classify_for_reader(ctx.a, ctx.in_s)
      assert [%Item{}] = Triage.called_out(ctx.a, Triage.briefing_today())

      {:ok, _} = Ownership.set_flag_important_agent(ctx.a, ctx.shared, nil)
      assert Triage.called_out(ctx.a, Triage.briefing_today()) == []
    end

    test "no flag agent on any readable mailbox: nothing is classified and the run says so",
         ctx do
      {:ok, _} = Ownership.set_flag_important_agent(ctx.a, ctx.shared, nil)
      assert {:ok, %{status: :no_triage_agent, classified: 0}} = run(ctx.a)
      assert stub_calls() == []
      assert {:error, :no_triage_agent} = Triage.classify_for_reader(ctx.a, ctx.in_s)
    end
  end

  # ── per-mailbox agent (task 01a1f5cc stage 2) ──────────────────────────

  describe "per-mailbox flag agent" do
    test "a mailbox set to Off gets no item, even when an agent holds an access grant on it",
         ctx do
      # A2 was flagged by the agent and produced an item; the owner then
      # turns it Off. The agent ALSO holds an ordinary access grant on A2.
      grant_agent!(ctx.a, ctx.a2, ctx.agent)
      flag_agent!(ctx.a, ctx.a2, ctx.agent)
      earlier = inbound!(ctx.a2)
      assert {:ok, %Item{id: earlier_id}} = Triage.classify_for_reader(ctx.a, earlier)
      _ = stub_calls()

      {:ok, _} = Ownership.set_flag_important_agent(ctx.a, ctx.a2, nil)
      # The access grant survives Off, so the agent may still READ A2.
      assert ctx.a2.id in Ownership.agent_granted_account_ids(ctx.agent.id, ctx.org_id)

      refute ctx.a2.id in Triage.eligible_account_ids(ctx.a, ctx.org_id)
      refute Enum.any?(Triage.called_out(ctx.a, Triage.briefing_today()), &(&1.id == earlier_id))
      refute Triage.eligible?(ctx.a, earlier)

      later = inbound!(ctx.a2)
      assert {:error, :no_triage_agent} = Triage.classify_for_reader(ctx.a, later)
      :ok = Triage.on_inbound(later.id)
      assert {:ok, %{status: :ok, classified: 0, failed: 0}} = run(ctx.a)

      assert stub_calls() == []
      refute Enum.any?(items_for(ctx.a), &(&1.inbound_message_id == later.id))

      view = Triage.section_view(ctx.a, Triage.briefing_today())
      refute Map.has_key?(view.agents_by_account, ctx.a2.id)
      assert ctx.a2.id in Enum.map(view.ungranted, & &1.id)
    end

    test "after switching X to Y the next inbound is classified by Y", ctx do
      y = agent!("y")

      first = inbound!(ctx.shared)
      :ok = Triage.on_inbound(first.id)
      x_label = Classifier.classifier_label(ctx.agent)
      assert %Item{classifier: ^x_label} = Repo.get_by!(Item, inbound_message_id: first.id)

      flag_agent!(ctx.a, ctx.shared, y)
      assert %{id: y_id} = Triage.agent_for_account(ctx.shared.id)
      assert y_id == y.id

      second = inbound!(ctx.shared)
      :ok = Triage.on_inbound(second.id)
      y_label = Classifier.classifier_label(y)
      assert y_label != x_label
      assert %Item{classifier: ^y_label} = Repo.get_by!(Item, inbound_message_id: second.id)

      view = Triage.section_view(ctx.a, Triage.briefing_today())
      assert view.agents_by_account[ctx.shared.id] == %{id: y.id, name: y.name}
    end

    test "an inactive flag agent triages nothing", ctx do
      in_s = inbound!(ctx.shared)

      {1, _} =
        from(ag in Platform.Agents.Agent, where: ag.id == ^ctx.agent.id)
        |> Repo.update_all(set: [status: "paused"])

      assert Triage.agent_for_account(ctx.shared.id) == nil
      assert Triage.eligible_account_ids(ctx.a, ctx.org_id) == []
      assert {:error, :no_triage_agent} = Triage.classify_for_reader(ctx.a, in_s)
      :ok = Triage.on_inbound(in_s.id)
      assert Triage.reconcile() == 0
      assert {:ok, %{status: :no_triage_agent, classified: 0}} = run(ctx.a)
      assert stub_calls() == []
      assert items_for(ctx.a) == []

      view = Triage.section_view(ctx.a, Triage.briefing_today())
      assert view.agent == nil
      assert view.agents_by_account == %{}
      assert ctx.shared.id in Enum.map(view.ungranted, & &1.id)
    end

    test "the mail.triage role assignee is ignored", ctx do
      # The role's agent holds an ordinary access grant on A2, and S is Off:
      # the only way anything could be triaged for A is the Roles fallback.
      z = agent!("role")
      {:ok, _} = Platform.Roles.set_override("mail.triage", z.id)
      grant_agent!(ctx.a, ctx.a2, z)
      {:ok, _} = Ownership.set_flag_important_agent(ctx.a, ctx.shared, nil)

      in_a2 = inbound!(ctx.a2)
      in_s = inbound!(ctx.shared)

      assert Triage.agent_for_account(ctx.a2.id) == nil
      assert {:error, :no_triage_agent} = Triage.classify_for_reader(ctx.a, in_a2)
      assert {:error, :no_triage_agent} = Triage.classify_for_reader(ctx.a, in_s)
      :ok = Triage.on_inbound(in_a2.id)
      assert {:ok, %{status: :no_triage_agent, classified: 0}} = run(ctx.a)
      assert stub_calls() == []
      assert items_for(ctx.a) == []
      assert Triage.section_view(ctx.a, Triage.briefing_today()).agent == nil
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

    test "ONE not_important tap makes the next email from that domain routine, not called out",
         ctx do
      Stub.reply!(Stub.json(verdict(%{"tier" => "action"})))
      first = inbound!(ctx.shared, %{from_address: "billing@vendor.test"})
      assert {:ok, %Item{tier: "action"} = item} = Triage.classify_for_reader(ctx.a, first)
      _ = stub_calls()

      assert {:ok, %Feedback{verdict: "not_important"}} =
               Triage.record_feedback(ctx.a, item, "not_important")

      # The model would call it action again; the ceiling never asks it.
      Stub.reply!(Stub.json(verdict(%{"tier" => "action"})))
      next = inbound!(ctx.shared, %{from_address: "accounts@vendor.test"})

      assert {:ok, %Item{tier: "routine", classifier: "rule:feedback_not_important"} = demoted} =
               Triage.classify_for_reader(ctx.a, next)

      assert Enum.any?(demoted.signals, &(&1["kind"] == "feedback_not_important"))
      assert stub_calls() == []
      refute Enum.any?(Triage.called_out(ctx.a, Triage.briefing_today()), &(&1.id == demoted.id))
    end

    # Auditor's must (task 01a1f426): a freemail domain is not one sender,
    # so a verdict on it is matched by address, not by domain.
    test "one not_important tap on a freemail sender demotes that address only", ctx do
      Stub.reply!(Stub.json(verdict(%{"tier" => "action"})))
      first = inbound!(ctx.shared, %{from_address: "News <news@gmail.com>"})
      assert {:ok, %Item{tier: "action"} = item} = Triage.classify_for_reader(ctx.a, first)
      _ = stub_calls()

      assert {:ok, %Feedback{sender_address: "news@gmail.com", sender_domain: "gmail.com"}} =
               Triage.record_feedback(ctx.a, item, "not_important")

      # Another gmail.com sender is not demoted by that tap.
      Stub.reply!(Stub.json(verdict(%{"tier" => "action"})))
      client = inbound!(ctx.shared, %{from_address: "client@gmail.com"})

      assert {:ok, %Item{tier: "action", classifier: "agent:" <> _} = called} =
               Triage.classify_for_reader(ctx.a, client)

      refute Enum.any?(called.signals, &(&1["kind"] == "feedback_not_important"))
      assert Enum.any?(Triage.called_out(ctx.a, Triage.briefing_today()), &(&1.id == called.id))
      [[_system, user]] = stub_calls()
      assert user.content =~ ~s("reader_said_sender_not_important":false)

      # The same tap still demotes the next email from news@gmail.com.
      Stub.reply!(Stub.json(verdict(%{"tier" => "action"})))
      again = inbound!(ctx.shared, %{from_address: "news@gmail.com"})

      assert {:ok, %Item{tier: "routine", classifier: "rule:feedback_not_important"}} =
               Triage.classify_for_reader(ctx.a, again)

      assert stub_calls() == []
    end

    test "after one not_important tap, a reply we are waiting on from that domain is still called out",
         ctx do
      first = inbound!(ctx.shared, %{from_address: "billing@vendor.test"})
      {:ok, item} = Triage.classify_for_reader(ctx.a, first)
      _ = stub_calls()
      assert {:ok, _} = Triage.record_feedback(ctx.a, item, "not_important")

      # We wrote to counsel@ and have heard nothing from that address since.
      delivery!(ctx.shared, "counsel@vendor.test")
      Stub.reply!(Stub.json(verdict(%{"tier" => "routine", "needs" => "none"})))
      reply = inbound!(ctx.shared, %{from_address: "counsel@vendor.test"})

      assert {:ok, %Item{tier: "action"} = surfaced} = Triage.classify_for_reader(ctx.a, reply)
      assert Enum.any?(surfaced.signals, &(&1["kind"] == "waiting_on"))
      assert Enum.any?(surfaced.signals, &(&1["kind"] == "feedback_not_important"))
      assert Enum.any?(Triage.called_out(ctx.a, Triage.briefing_today()), &(&1.id == surfaced.id))

      [[_system, user]] = stub_calls()
      assert user.content =~ ~s("reader_said_sender_not_important":true)
      assert user.content =~ ~s("waiting_on_their_reply":true)
    end

    test "not_important followed by missed calls the next email out", ctx do
      Stub.reply!(Stub.json(verdict(%{"tier" => "routine", "needs" => "none"})))
      first = inbound!(ctx.shared, %{from_address: "billing@vendor.test"})
      {:ok, item} = Triage.classify_for_reader(ctx.a, first)
      _ = stub_calls()

      assert {:ok, _} = Triage.record_feedback(ctx.a, item, "not_important")
      second = inbound!(ctx.shared, %{from_address: "billing@vendor.test"})

      assert {:ok, %Item{tier: "routine"} = second_item} =
               Triage.classify_for_reader(ctx.a, second)

      assert {:ok, %Feedback{verdict: "missed"}} =
               Triage.record_feedback(ctx.a, second_item, "missed")

      Stub.reply!(Stub.json(verdict(%{"tier" => "routine", "needs" => "none"})))
      third = inbound!(ctx.shared, %{from_address: "billing@vendor.test"})

      assert {:ok, %Item{tier: "action", classifier: "agent:" <> _} = third_item} =
               Triage.classify_for_reader(ctx.a, third)

      assert Enum.any?(
               Triage.called_out(ctx.a, Triage.briefing_today()),
               &(&1.id == third_item.id)
             )

      [[_system, user]] = stub_calls()
      assert user.content =~ ~s("reader_said_sender_not_important":false)
      assert user.content =~ ~s("reader_said_earlier_email_needed_them":true)
    end

    test "one reader's not_important leaves another reader of the same mailbox unaffected", ctx do
      {:ok, _} = Platform.Mail.Ownership.grant(ctx.a, ctx.shared, {:user, ctx.b.id})
      assert ctx.shared.id in Triage.eligible_account_ids(ctx.b, ctx.org_id)

      Stub.reply!(Stub.json(verdict(%{"tier" => "action"})))
      first = inbound!(ctx.shared, %{from_address: "billing@vendor.test"})
      {:ok, a_item} = Triage.classify_for_reader(ctx.a, first)
      _ = stub_calls()
      assert {:ok, _} = Triage.record_feedback(ctx.a, a_item, "not_important")

      Stub.reply!(Stub.json(verdict(%{"tier" => "action"})))
      next = inbound!(ctx.shared, %{from_address: "accounts@vendor.test"})

      assert {:ok, %Item{tier: "action", classifier: "agent:" <> _} = b_item} =
               Triage.classify_for_reader(ctx.b, next)

      refute Enum.any?(b_item.signals, &(&1["kind"] == "feedback_not_important"))
      assert Enum.any?(Triage.called_out(ctx.b, Triage.briefing_today()), &(&1.id == b_item.id))
      [[_system, user]] = stub_calls()
      assert user.content =~ ~s("reader_said_sender_not_important":false)

      # Positive control: the same email IS demoted for the reader who tapped.
      assert {:ok, %Item{tier: "routine", classifier: "rule:feedback_not_important"}} =
               Triage.classify_for_reader(ctx.a, next)
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

      # A second email in A2 (Off for now): the per-account path below
      # turns A2 on for agent Y and triages it through `on_inbound/2`.
      y = agent!("y")

      a2_inbound =
        inbound!(ctx.a2, %{
          from_address: "other-#{ctx.n}@elsewhere.test",
          subject: "Fwd: #{sentinel}",
          text_body: "Also #{sentinel} again.",
          raw: raw([], "Also #{sentinel} again.")
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
            assert [%Item{} = item] = Triage.called_out(ctx.a, Triage.briefing_today())
            assert {:ok, _} = Triage.record_feedback(ctx.a, item, "not_important")
            # The set_flag_important_agent write and the per-account path.
            assert {:ok, _} = Ownership.set_flag_important_agent(ctx.a, ctx.a2, y.id)
            assert :ok = Triage.on_inbound(a2_inbound.id)
          end)
        after
          Logger.configure(level: previous)
        end

      # Positive controls: the sentinel really flowed through the model call
      # and into the stored item, and the debug query log was really on.
      assert seen(stub_calls()) =~ sentinel
      assert Repo.get_by!(Item, inbound_message_id: inbound.id).why =~ sentinel
      y_label = Classifier.classifier_label(y)
      a2_item = Repo.get_by!(Item, inbound_message_id: a2_inbound.id)
      assert a2_item.why =~ sentinel
      assert a2_item.classifier == y_label
      # Every triage read of an item or an inbound row is quiet (stage 5),
      # so the proof that the debug query log was on is any query line.
      assert log =~ "QUERY OK"
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
