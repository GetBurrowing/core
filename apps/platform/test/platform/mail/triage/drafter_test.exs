defmodule Platform.Mail.Triage.DrafterTest do
  @moduledoc """
  `Platform.Mail.Triage.Drafter` (task 01a1f426 stage 4): a draft reply or
  a plan for a called-out email, drafts only.

  The world: reader R (a plain member) owns personal mailbox P (a sender,
  granted to the triage agent) and P3 (granted, no sender). R also reads
  shared mailbox S2, NOT granted to the agent. Org admin A and member B:
  B owns personal mailbox B-box, granted to the agent and NOT readable by
  A (admin confers nothing).

  The two permission tests are the mutation probe's target: bypassing the
  drafter's eligibility check (`{:eligible, true} <- {:eligible, true}` in
  `draft/3`) turns both red, while the zero-drafts assertion that comes
  first in "a mailbox the reader reads but the agent is not granted" still
  holds, because `Drafts.create/4`'s agent scope refuses the account.

  async: false — the stub provider, the call trace, the Logger level and
  `:mail_enabled` are application-wide.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog
  import Platform.TenancyFixtures
  import Platform.Test.MailPrivacyFixtures
  import Platform.Test.MailTriageFixtures

  alias Platform.Mail
  alias Platform.Mail.{Delivery, Draft, Drafts, Inbound}
  alias Platform.Mail.Triage.{BriefingSection, Drafter, Item}
  alias Platform.Test.MailTriageStub, as: Stub

  @reply %{"kind" => "reply", "subject" => "Re: your note", "body" => "Thanks, confirmed."}
  @plan %{
    "kind" => "plan",
    "summary" => "Prepare the proposal they asked for.",
    "steps" => ["Collect the scope", "Draft the timeline", "Review pricing"]
  }

  setup do
    enable_mail!()
    org_id = acme_org_id()
    n = unique()

    a = user!("a") |> member!(org_id, "admin")
    b = user!("b") |> member!(org_id)
    r = user!("r") |> member!(org_id)
    agent = triage_agent!()

    p = account!(a, org_id, %{"name" => "Pbox #{n}"}) |> then(&personal!(a, &1, r))

    {:ok, _} =
      Mail.put_sender(a, p, %{key: "ops", address: "box@example.test", display_name: "R"})

    grant_agent!(r, p, agent)

    p3 = account!(a, org_id, %{"name" => "P3box #{n}"}) |> then(&personal!(a, &1, r))
    grant_agent!(r, p3, agent)

    s2 = account!(a, org_id, %{"name" => "S2box #{n}"}) |> then(&shared!(a, &1, [r]))

    {:ok, _} =
      Mail.put_sender(a, s2, %{key: "ops", address: "s2@example.test", display_name: "S"})

    b_box = account!(a, org_id, %{"name" => "Bbox #{n}"}) |> then(&personal!(a, &1, b))

    {:ok, _} =
      Mail.put_sender(a, b_box, %{key: "ops", address: "b@example.test", display_name: "B"})

    grant_agent!(b, b_box, agent)

    :ok = Stub.install!(by_prompt(@reply))

    %{org_id: org_id, n: n, a: a, b: b, r: r, agent: agent, p: p, p3: p3, s2: s2, b_box: b_box}
  end

  # The stub answers the drafter's prompt with `draft_reply` and anything
  # else (the classifier) with a called-out verdict.
  defp by_prompt(draft_reply, verdict_overrides \\ %{"tier" => "top"}) do
    fn _c, [%{content: system} | _], _o ->
      if system =~ "You prepare the first piece of work",
        do: {:ok, %{content: Jason.encode!(draft_reply)}},
        else: {:ok, %{content: Jason.encode!(verdict(verdict_overrides))}}
    end
  end

  defp item!(user, inbound, attrs \\ %{}) do
    %Item{}
    |> Item.create_changeset(
      Map.merge(
        %{
          org_id: inbound.org_id,
          account_id: inbound.account_id,
          inbound_message_id: inbound.id,
          user_id: user.id,
          tier: "top",
          needs: "reply",
          why: "They asked a question.",
          classifier: "agent:test@v1"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp stub_calls do
    receive do
      {:mail_triage_stub_called, _c, messages, _o} -> [messages | stub_calls()]
    after
      0 -> []
    end
  end

  defp seen(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)
  defp drafts, do: Repo.all(Draft)
  defp run(user), do: Drafter.run_for_reader(user, Date.utc_today())

  # ── drafts only ──────────────────────────────────────────────────────────

  @send_path [
    {Platform.Mail.Dispatch, :dispatch, 3},
    {Platform.Mail.Dispatch, :enqueue, 3},
    {Platform.Mail.Deliverer, :deliver, 1}
  ]

  # A dedicated trace session (OTP 27+ `:trace`), so no other tracer on
  # the node can swallow or steal these events; a separate collector
  # process forwards each call to the test.
  defp trace_send_path! do
    test_pid = self()

    collector =
      spawn(fn ->
        Stream.repeatedly(fn ->
          receive do
            msg -> send(test_pid, msg)
          end
        end)
        |> Stream.run()
      end)

    session = :trace.session_create(:mail_triage_drafter_send_path, collector, [])

    for {m, _f, _a} = mfa <- @send_path do
      Code.ensure_loaded!(m)
      1 = :trace.function(session, mfa, true, [:local])
    end

    :trace.process(session, :all, true, [:call])

    on_exit(fn ->
      :trace.session_destroy(session)
      Process.exit(collector, :kill)
    end)
  end

  defp send_path_calls do
    receive do
      {:trace, _pid, :call, {m, f, args}} -> [{m, f, length(args)} | send_path_calls()]
    after
      100 -> []
    end
  end

  describe "drafts only" do
    test "five called-out emails: drafts and plans, and the send path is never called", ctx do
      inbounds = for i <- 1..5, do: inbound!(ctx.p, %{text_body: "Question #{i}?"})

      for {inbound, i} <- Enum.with_index(inbounds),
          do: item!(ctx.r, inbound, %{needs: Enum.at(~w(reply reply decision reply plan), i)})

      Stub.reply!(fn _c, [_system, %{content: user}], _o ->
        if user =~ "Question 5?",
          do: {:ok, %{content: Jason.encode!(@plan)}},
          else: {:ok, %{content: Jason.encode!(@reply)}}
      end)

      deliveries = Repo.aggregate(Delivery, :count)
      trace_send_path!()

      assert {:ok, %{replies: 4, plans: 1, failed: 0, capped: 0}} = run(ctx.r)

      assert send_path_calls() == []
      assert Repo.aggregate(Delivery, :count) == deliveries
      refute_received {:mail_test_adapter, _email, _config}

      created = drafts()
      assert length(created) == 4
      assert Enum.all?(created, &(&1.status == "draft"))

      assert Enum.all?(
               created,
               &(&1.created_by_type == "agent" and &1.created_by_id == ctx.agent.id)
             )

      assert Enum.all?(
               created,
               &(&1.on_behalf_of_user_id == ctx.r.id and &1.account_id == ctx.p.id)
             )

      assert Enum.all?(created, &(&1.sender_key == "ops"))

      items = Repo.all(from(i in Item, where: i.user_id == ^ctx.r.id))
      assert Enum.all?(items, &(&1.drafted_at != nil))

      for item <- items, item.draft_id do
        draft = Repo.get!(Draft, item.draft_id)
        inbound = Enum.find(inbounds, &(&1.id == item.inbound_message_id))
        assert draft.in_reply_to_inbound_id == inbound.id
        assert draft.to_addresses == [inbound.from_address]
        assert draft.subject == "Re: " <> inbound.subject
        assert item.draft_original_body == draft.body
        assert draft.body == "Thanks, confirmed."
      end

      # Positive control: the trace is live, so the empty list above means
      # the drafter called none of the three.
      _ = Platform.Mail.Deliverer.deliver(Ecto.UUID.generate())
      assert {Platform.Mail.Deliverer, :deliver, 1} in send_path_calls()
    end

    test "a plan stores its summary and steps, and creates no draft and no task", ctx do
      Stub.reply!(Stub.json(@plan))
      tasks = Repo.aggregate(Platform.Tasks.Task, :count)
      item = item!(ctx.r, inbound!(ctx.p), %{needs: "plan"})

      assert {:ok, :plan, stored} = Drafter.draft(ctx.r, item, agent: ctx.agent)
      assert stored.plan_summary == "Prepare the proposal they asked for."
      assert stored.plan_steps == ["Collect the scope", "Draft the timeline", "Review pricing"]
      assert stored.draft_id == nil
      assert drafts() == []
      assert Repo.aggregate(Platform.Tasks.Task, :count) == tasks
    end

    test "a second run takes nothing it already took", ctx do
      item!(ctx.r, inbound!(ctx.p))
      assert {:ok, %{replies: 1}} = run(ctx.r)
      _ = stub_calls()

      assert {:ok, %{replies: 0, plans: 0}} = run(ctx.r)
      assert stub_calls() == []
      assert length(drafts()) == 1
    end

    test "only top and action items that need a reply, decision or plan", ctx do
      routine = item!(ctx.r, inbound!(ctx.p), %{tier: "routine"})
      nothing = item!(ctx.r, inbound!(ctx.p), %{tier: "action", needs: "none"})

      assert {:skipped, :not_draftable} = Drafter.draft(ctx.r, routine, agent: ctx.agent)
      assert {:skipped, :not_draftable} = Drafter.draft(ctx.r, nothing, agent: ctx.agent)
      assert stub_calls() == []
    end

    test "at most the daily cap per reader per day", ctx do
      Stub.reply!(Stub.json(@plan))
      for _ <- 1..(Drafter.daily_cap() + 1), do: item!(ctx.r, inbound!(ctx.p), %{needs: "plan"})

      assert {:ok, %{plans: 15, capped: 1}} = run(ctx.r)
      assert length(stub_calls()) == Drafter.daily_cap()

      assert Repo.aggregate(
               from(i in Item, where: i.user_id == ^ctx.r.id and is_nil(i.drafted_at)),
               :count
             ) ==
               1
    end
  end

  # ── closed output ────────────────────────────────────────────────────────

  describe "the closed output" do
    test "parse accepts exactly the two shapes" do
      assert {:ok, %{kind: "reply", body: "Hi"}} =
               Drafter.parse(Jason.encode!(%{@reply | "body" => " Hi "}))

      assert {:ok, %{kind: "plan", steps: [_, _, _]}} = Drafter.parse(Jason.encode!(@plan))

      assert {:ok, %{kind: "reply"}} =
               Drafter.parse("```json\n" <> Jason.encode!(@reply) <> "\n```")

      for bad <- [
            Map.put(@reply, "extra", 1),
            Map.delete(@reply, "subject"),
            %{@reply | "body" => "  "},
            %{@reply | "kind" => "send"},
            %{@plan | "steps" => Enum.map(1..9, &"step #{&1}")},
            %{@plan | "steps" => []},
            %{@plan | "steps" => ["ok", 3]},
            %{@plan | "summary" => ""}
          ] do
        assert {:rejected, defect} = Drafter.parse(Jason.encode!(bad))
        assert is_binary(defect)
      end

      assert {:rejected, _} = Drafter.parse("Sure! Here is a draft: ...")
      assert {:rejected, _} = Drafter.parse("[1, 2]")
    end

    test "rejected output stores no model text and is not paid for again", ctx do
      Stub.reply!(Stub.json(Map.put(@reply, "extra", "MODEL-TEXT-#{ctx.n}")))
      item = item!(ctx.r, inbound!(ctx.p))

      log =
        capture_log(fn ->
          assert {:error, :rejected_output} = Drafter.draft(ctx.r, item, agent: ctx.agent)
        end)

      refute log =~ "MODEL-TEXT-#{ctx.n}"
      stored = Repo.get!(Item, item.id)
      assert stored.drafted_at

      assert stored.draft_id == nil and stored.draft_original_body == nil and
               stored.plan_steps == nil

      refute seen(stored) =~ "MODEL-TEXT"
      assert drafts() == []
    end

    test "a provider failure stores nothing and gives the item back", ctx do
      Stub.reply!(fn _c, _m, _o -> {:error, :boom} end)
      item = item!(ctx.r, inbound!(ctx.p))

      capture_log(fn ->
        assert {:error, :provider_failed} = Drafter.draft(ctx.r, item, agent: ctx.agent)
      end)

      stored = Repo.get!(Item, item.id)
      assert stored.drafted_at == nil
      assert Drafter.draftable?(stored)
      assert drafts() == []
    end

    test "no sender on the mailbox: no draft and no provider call", ctx do
      item = item!(ctx.r, inbound!(ctx.p3))
      assert {:skipped, :no_sender} = Drafter.draft(ctx.r, item, agent: ctx.agent)
      assert stub_calls() == []
      assert drafts() == []
    end
  end

  # ── mailbox permissions ──────────────────────────────────────────────────

  describe "mailbox permissions" do
    test "a mailbox the reader reads but the agent is not granted: no draft and no provider call",
         ctx do
      item = item!(ctx.r, inbound!(ctx.s2, %{text_body: "S2-#{ctx.n}"}))

      result = Drafter.draft(ctx.r, item, agent: ctx.agent)
      assert drafts() == []
      assert result == {:skipped, :not_eligible}
      assert stub_calls() == []

      assert {:ok, %{replies: 0, plans: 0}} = run(ctx.r)
      assert stub_calls() == []
      assert drafts() == []
    end

    test "a mailbox granted to the agent that the reader cannot read: no draft and no provider call",
         ctx do
      # A is an org admin: admin status confers nothing.
      item =
        item!(ctx.a, inbound!(ctx.b_box, %{text_body: "BBOX-#{ctx.n}"}), %{needs: "decision"})

      result = Drafter.draft(ctx.a, item, agent: ctx.agent)
      assert drafts() == []
      assert result == {:skipped, :not_eligible}
      assert stub_calls() == []

      assert {:ok, %{replies: 0, plans: 0}} = run(ctx.a)
      assert stub_calls() == []
    end

    test "Drafts.create's agent scope refuses both mailboxes on its own", ctx do
      base = %{sender_key: "ops", to_addresses: ["x@outside.test"], body: "b"}

      assert {:error, :account_not_found} =
               Drafts.create(
                 {:agent, ctx.agent.id},
                 ctx.org_id,
                 Map.merge(base, %{account_id: ctx.s2.id, on_behalf_of_user_id: ctx.r.id})
               )

      assert {:error, :on_behalf_cannot_read_account} =
               Drafts.create(
                 {:agent, ctx.agent.id},
                 ctx.org_id,
                 Map.merge(base, %{account_id: ctx.b_box.id, on_behalf_of_user_id: ctx.a.id})
               )
    end

    test "another reader's item is never drafted for this reader", ctx do
      item = item!(ctx.b, inbound!(ctx.b_box))
      assert {:skipped, :not_eligible} = Drafter.draft(ctx.r, item, agent: ctx.agent)
      assert stub_calls() == []
    end
  end

  # ── what the model sees ──────────────────────────────────────────────────

  describe "the prompt" do
    test "thread history from THIS mailbox only, every email wrapped", ctx do
      sender = "counsel-#{ctx.n}@otherco.test"

      _earlier =
        inbound!(ctx.p, %{
          from_address: sender,
          text_body: "EARLIER-P-#{ctx.n}",
          received_at: DateTime.add(DateTime.utc_now(), -7200, :second)
        })

      _elsewhere =
        inbound!(ctx.s2, %{
          from_address: sender,
          text_body: "ELSEWHERE-#{ctx.n}",
          received_at: DateTime.add(DateTime.utc_now(), -7200, :second)
        })

      _ = delivery!(ctx.p, sender)
      _ = delivery!(ctx.s2, sender)
      inbound = inbound!(ctx.p, %{from_address: "Counsel <#{sender}>", text_body: "NOW-#{ctx.n}"})

      history = Drafter.thread_history(inbound, sender)
      assert [%{direction: :outbound}, %{direction: :inbound, body: "EARLIER-P-" <> _}] = history

      ctx_map = %{
        waiting_on: nil,
        person: nil,
        task_titles: [%{id: Ecto.UUID.generate(), title: "Contract for otherco"}],
        meeting_titles: [%{id: Ecto.UUID.generate(), title: "Contract review"}]
      }

      [%{role: "system", content: system}, %{role: "user", content: user}] =
        Drafter.build_messages(inbound, ctx_map, history)

      assert system =~ "DATA"
      assert user =~ "EARLIER-P-#{ctx.n}"
      assert user =~ "NOW-#{ctx.n}"
      refute user =~ "ELSEWHERE-#{ctx.n}"
      assert user =~ "Contract for otherco"
      assert user =~ "Contract review"
      # three emails (two earlier, one now), each inside its own wrap
      assert length(String.split(user, "EXTERNAL_UNTRUSTED_CONTENT")) - 1 >= 6
    end
  end

  # ── the hooks ────────────────────────────────────────────────────────────

  describe "runs from the briefing and from the subscriber" do
    test "the briefing's prepare/2 drafts what it called out", ctx do
      _inbound = inbound!(ctx.p, %{text_body: "Can you confirm?"})
      assert BriefingSection.prepare(ctx.r.id, Date.utc_today()) >= 1
      assert [%Draft{status: "draft", on_behalf_of_user_id: r_id}] = drafts()
      assert r_id == ctx.r.id
    end

    test "a newly ingested email is drafted after classification", ctx do
      inbound = inbound!(ctx.p, %{text_body: "Can you confirm?"})
      :ok = Platform.Mail.Triage.on_inbound(inbound.id, agent: ctx.agent)
      assert [%Draft{in_reply_to_inbound_id: id}] = drafts()
      assert id == inbound.id
    end
  end

  # ── the draft copy goes with the draft (auditor's must) ──────────────────

  describe "draft_original_body" do
    setup ctx do
      item = item!(ctx.r, inbound!(ctx.p))
      {:ok, :reply, item} = Drafter.draft(ctx.r, item, agent: ctx.agent)
      %{item: item}
    end

    test "is cleared when the draft is discarded; draft_id stays", ctx do
      assert ctx.item.draft_original_body
      {:ok, _} = Drafts.discard({:user, ctx.r.id}, ctx.item.draft_id)

      stored = Repo.get!(Item, ctx.item.id)
      assert stored.draft_original_body == nil
      assert stored.draft_id == ctx.item.draft_id
      refute Drafter.draftable?(stored)
    end

    test "is cleared, with draft_id, when the draft is deleted", ctx do
      Repo.delete!(Repo.get!(Draft, ctx.item.draft_id))

      stored = Repo.get!(Item, ctx.item.id)
      assert stored.draft_original_body == nil
      assert stored.draft_id == nil
      refute Drafter.draftable?(stored)
    end

    test "is kept while the draft is only edited", ctx do
      {:ok, _} = Drafts.update({:user, ctx.r.id}, ctx.item.draft_id, %{body: "edited"})
      assert Repo.get!(Item, ctx.item.id).draft_original_body == "Thanks, confirmed."
    end
  end

  # ── sentinel ─────────────────────────────────────────────────────────────

  describe "message bodies never leave the mailbox" do
    setup do
      previous = Logger.level()
      on_exit(fn -> Logger.configure(level: previous) end)

      test_pid = self()
      handler = "mail-triage-drafter-sentinel-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach_many(
          handler,
          [
            [:platform, :repo, :query],
            [:platform, :mail, :triage, :classified],
            [:platform, :mail, :triage, :drafted]
          ],
          fn event, measurements, metadata, _ ->
            # `:result` is the rows a read returned to its own caller; what a
            # handler would ship is the query, its params and the metadata.
            send(test_pid, {:telemetry_seen, event, measurements, Map.delete(metadata, :result)})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "the sentinel is only in the draft body and draft_original_body", ctx do
      sentinel = "SENTINEL-#{Ecto.UUID.generate()}"
      sender = "who-#{String.downcase(Ecto.UUID.generate())}@outside.test"
      :ok = Inbound.subscribe()
      Stub.reply!(by_prompt(%{@reply | "body" => "Confirmed: #{sentinel}."}))

      # A delivery to the sender makes the waiting-on and thread reads run
      # with the address as a query parameter.
      _ = delivery!(ctx.p, sender)

      inbound =
        inbound!(ctx.p, %{
          from_address: sender,
          text_body: "Please confirm #{sentinel} by Friday.",
          raw: raw([], "Please confirm #{sentinel} by Friday.")
        })

      _ = collect_telemetry()

      previous = Logger.level()
      Logger.configure(level: :debug)

      log =
        try do
          capture_log([level: :debug], fn ->
            assert BriefingSection.prepare(ctx.r.id, Date.utc_today()) >= 1
          end)
        after
          Logger.configure(level: previous)
        end

      # Positive controls: the sentinel reached the model, the draft and the
      # stored copy; the debug query log and the telemetry were live.
      calls = stub_calls()
      assert seen(calls) =~ sentinel
      assert seen(calls) =~ sender
      assert [%Draft{} = draft] = drafts()
      assert draft.body =~ sentinel
      assert draft.to_addresses == [sender]
      item = Repo.get_by!(Item, inbound_message_id: inbound.id, user_id: ctx.r.id)
      assert item.draft_original_body =~ sentinel
      assert log =~ "mail_triage"
      assert log =~ "[Mail.Triage.Drafter] drafted"

      refute log =~ sentinel
      refute log =~ sender

      telemetry = collect_telemetry()
      assert Enum.any?(telemetry, &match?({[:platform, :repo, :query], _, _}, &1))
      assert Enum.any?(telemetry, &match?({[:platform, :mail, :triage, :drafted], _, _}, &1))

      for {event, _m, metadata} <- telemetry, leak <- [sentinel, sender] do
        refute seen(metadata) =~ leak, "#{leak} in #{inspect(event)} metadata (query/params)"
      end

      {:messages, mailbox} = Process.info(self(), :messages)
      refute seen(mailbox) =~ sentinel

      like = "%" <> sentinel <> "%"

      for sql <- [
            "SELECT count(*) FROM audit_events e WHERE row_to_json(e)::text LIKE $1",
            "SELECT count(*) FROM experiment_signals s WHERE row_to_json(s)::text LIKE $1",
            "SELECT count(*) FROM mail_deliveries d WHERE row_to_json(d)::text LIKE $1",
            "SELECT count(*) FROM mail_drafts d WHERE (row_to_json(d)::jsonb - 'body')::text LIKE $1",
            "SELECT count(*) FROM mail_triage_items i WHERE (row_to_json(i)::jsonb - 'draft_original_body')::text LIKE $1"
          ] do
        assert %{rows: [[0]]} = Repo.query!(sql, [like]), sql
      end

      # ...and the two places it may be really do hold it.
      assert %{rows: [[1]]} =
               Repo.query!("SELECT count(*) FROM mail_drafts WHERE body LIKE $1", [like])

      assert %{rows: [[1]]} =
               Repo.query!(
                 "SELECT count(*) FROM mail_triage_items WHERE draft_original_body LIKE $1",
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
