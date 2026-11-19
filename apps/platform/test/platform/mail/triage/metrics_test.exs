defmodule Platform.Mail.Triage.MetricsTest do
  @moduledoc """
  The acted-on metric (task 01a1f426 stage 3) and the few-edit metric of
  triage drafts (stage 5): `Platform.Mail.Triage.Metrics`.
  An item is acted when the reader replies from that mailbox (through the
  real `Platform.Mail.Dispatch`, recorded by `Platform.Mail.TestAdapter`),
  or marks it Done. Rate arithmetic is checked with a denominator that is
  not 1, 2 or a divisor-friendly 10.

  async: false — `:mail_enabled`, the stub provider and the telemetry
  handler are application-wide.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query

  require Logger

  import Platform.TenancyFixtures
  import Platform.Test.MailPrivacyFixtures
  import Platform.Test.MailTriageFixtures

  alias Platform.Mail
  alias Platform.Mail.{Dispatch, Draft, Drafts, InboundMessage}
  alias Platform.Mail.Triage
  alias Platform.Mail.Triage.{Item, Metrics}
  alias Platform.Test.MailTriageStub, as: Stub

  setup do
    enable_mail!()
    org_id = acme_org_id()
    n = unique()

    admin = user!("admin") |> member!(org_id, "admin")
    r = user!("r") |> member!(org_id)
    agent = agent!("triage")

    box =
      account!(admin, org_id, %{"name" => "Rbox #{n}", "internal_only" => false})
      |> then(&personal!(admin, &1, r))

    flag_agent!(r, box, agent)

    {:ok, _} =
      Mail.put_sender(admin, box, %{"key" => "me", "address" => "r-#{n}@example.test"})

    :ok = Stub.install!(Stub.json(verdict(%{"tier" => "action"})))

    test_pid = self()
    handler = "mail-triage-metrics-#{n}"

    :ok =
      :telemetry.attach(
        handler,
        [:platform, :mail, :triage, :item],
        fn _e, m, meta, _ -> send(test_pid, {:triage_item, m, meta}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    %{org_id: org_id, n: n, r: r, box: box, agent: agent, admin: admin}
  end

  defp called_out!(ctx, from) do
    inbound = inbound!(ctx.box, %{from_address: from})
    {:ok, %Item{} = item} = Triage.classify_for_reader(ctx.r, inbound)
    item
  end

  defp reply!(ctx, to) do
    draft =
      %Draft{}
      |> Draft.changeset(%{
        org_id: ctx.org_id,
        account_id: ctx.box.id,
        sender_key: "me",
        to_addresses: [to],
        subject: "Re: hello",
        body: "Thanks.",
        created_by_type: "user",
        created_by_id: ctx.r.id
      })
      |> Repo.insert!()

    {:ok, delivery} = Dispatch.dispatch(draft.id, {:user, ctx.r.id})
    assert_received {:mail_test_adapter, _email, _config}
    delivery
  end

  defp since, do: DateTime.add(DateTime.utc_now(), -3600, :second)

  test "acted via a reply: an accepted send to the sender marks the item", ctx do
    item = called_out!(ctx, "Counsel <counsel@otherco.test>")
    other = called_out!(ctx, "someone@else.test")

    delivery = reply!(ctx, "COUNSEL@otherco.test")
    assert delivery.status == "accepted"

    acted = Repo.get!(Item, item.id)
    assert acted.status == "acted"
    assert acted.acted_how == "reply"
    assert %DateTime{} = acted.acted_at
    assert Repo.get!(Item, other.id).status == "open"

    assert_received {:triage_item, %{count: 1}, meta}
    assert meta == %{tier: "action", outcome: "acted_reply", org_id: ctx.org_id}

    assert %{called_out: 2, acted: 1, acted_rate: 0.5} = Metrics.for_user(ctx.r, since())
  end

  test "a send by someone else, or to another address, acts on nothing", ctx do
    item = called_out!(ctx, "counsel@otherco.test")
    reply!(ctx, "nobody@otherco.test")
    assert Repo.get!(Item, item.id).status == "open"

    # A delivery recorded by an agent or the system is not the reader's act.
    assert Metrics.on_delivery_accepted(%Mail.Delivery{
             status: "accepted",
             actor_type: "system",
             account_id: ctx.box.id,
             recipients: ["counsel@otherco.test"]
           }) == 0

    assert Repo.get!(Item, item.id).status == "open"
  end

  test "acted via Done", ctx do
    item = called_out!(ctx, "ops@client.test")
    assert {:ok, %Item{status: "acted", acted_how: "manual"}} = Triage.mark_done(ctx.r, item)

    assert_received {:triage_item, %{count: 1},
                     %{outcome: "acted_manual", tier: "action", org_id: org_id}}

    assert org_id == ctx.org_id
    assert %{called_out: 1, acted: 1, acted_rate: 1.0} = Metrics.for_user(ctx.r, since())
  end

  test "rate arithmetic with a non-trivial denominator", ctx do
    # 7 called out (5 action + 2 top), 2 routine that never count.
    items = for i <- 1..5, do: called_out!(ctx, "a#{i}@client.test")
    Stub.reply!(Stub.json(verdict(%{"tier" => "top"})))
    items = items ++ for(i <- 1..2, do: called_out!(ctx, "t#{i}@client.test"))
    Stub.reply!(Stub.json(verdict(%{"tier" => "routine", "needs" => "none"})))
    routine = for i <- 1..2, do: called_out!(ctx, "r#{i}@client.test")

    [a1, _a2, a3, _a4, _a5, t1, _t2] = items

    {:ok, _} = Triage.mark_done(ctx.r, a1)
    {:ok, _} = Triage.mark_done(ctx.r, t1)
    reply!(ctx, "a2@client.test")
    {:ok, _} = Triage.record_feedback(ctx.r, a3, "not_important")
    {:ok, _} = Triage.record_feedback(ctx.r, hd(routine), "missed")

    # The missed verdict raised that routine item to action: 8 called out.
    counts = Metrics.for_user(ctx.r, since())

    assert counts.called_out == 8
    assert counts.acted == 3
    assert counts.dismissed == 1
    assert counts.missed_reports == 1
    assert_in_delta counts.acted_rate, 3 / 8, 1.0e-9
    assert %{drafts_created: 0, drafts_sent: 0, few_edit_sent: 0} = counts

    org = Metrics.summary(ctx.org_id, since())
    assert org.called_out >= 8 and org.acted >= 3

    # Nothing before `since` is counted.
    future = DateTime.add(DateTime.utc_now(), 3600, :second)
    assert %{called_out: 0, acted_rate: +0.0} = Metrics.for_user(ctx.r, future)
  end

  # ── Triage drafts sent (task 01a1f426 stage 5) ──────────────────────────

  # A called-out email with a triage draft, written the way the drafter
  # writes one: an agent draft on behalf of the reader, in reply to the
  # email, its original body kept on the item.
  defp triage_draft!(ctx, body, inbound_attrs \\ %{}) do
    from = "counsel-#{unique()}@otherco.test"
    inbound = inbound!(ctx.box, Map.merge(%{from_address: from}, inbound_attrs))
    {:ok, %Item{} = item} = Triage.classify_for_reader(ctx.r, inbound)

    {:ok, draft} =
      Drafts.create(
        {:agent, ctx.agent.id},
        ctx.org_id,
        %{
          account_id: ctx.box.id,
          sender_key: "me",
          to_addresses: [from],
          subject: "Re: contract",
          body: body,
          on_behalf_of_user_id: ctx.r.id,
          in_reply_to_inbound_id: inbound.id
        },
        log: false,
        telemetry_event: nil
      )

    item =
      item
      |> Item.drafter_changeset(%{
        draft_id: draft.id,
        draft_original_body: body,
        drafted_at: DateTime.utc_now()
      })
      |> Repo.update!()

    {item, draft, inbound}
  end

  defp send_as_reader!(ctx, draft, new_body \\ nil) do
    if new_body do
      {:ok, _} = Drafts.update({:user, ctx.r.id}, draft.id, %{body: new_body})
    end

    {:ok, delivery} = Dispatch.dispatch(draft.id, {:user, ctx.r.id})
    assert delivery.status == "accepted"
    assert_received {:mail_test_adapter, _email, _config}
    delivery
  end

  defp attach_draft_sent! do
    test_pid = self()
    handler = "mail-triage-draft-sent-#{unique()}"

    :ok =
      :telemetry.attach(
        handler,
        [:platform, :mail, :triage, :draft_sent],
        fn _e, m, meta, _ -> send(test_pid, {:draft_sent, m, meta}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @ten "one two three four five six seven eight nine ten"

  describe "edit_ratio/2" do
    test "word-level Levenshtein over the longer word count" do
      assert Metrics.edit_ratio(@ten, @ten) == 0.0
      assert Metrics.edit_ratio("", "") == 0.0
      assert Metrics.edit_ratio(nil, nil) == 0.0
      assert Metrics.edit_ratio("a b c", "") == 1.0
      # Whitespace and line breaks are not edits.
      assert Metrics.edit_ratio("a b\n\nc", "  a  b c ") == 0.0
      # One substitution in four words.
      assert Metrics.edit_ratio("a b c d", "a x c d") == 0.25
      # One insertion: 1 edit over the longer (5) count.
      assert Metrics.edit_ratio("a b c d", "a b c d e") == 0.2
      # Transposed neighbours are two substitutions.
      assert Metrics.edit_ratio("a b c d", "b a c d") == 0.5
      # Exactly 2 of 10 words changed is exactly 0.2.
      assert Metrics.edit_ratio(@ten, "one two THREE four five six SEVEN eight nine ten") == 0.2
      assert Metrics.edit_ratio("x y", "p q r s t") == 1.0
    end
  end

  describe "a sent triage draft" do
    test "sent unedited: acted as draft_sent, ratio 0, original body cleared, telemetry ids only",
         ctx do
      attach_draft_sent!()
      {item, draft, _inbound} = triage_draft!(ctx, "Thanks, clauses 7.2 and 9.1 are fine.")

      delivery = send_as_reader!(ctx, draft)

      stored = Repo.get!(Item, item.id)
      assert stored.status == "acted"
      assert stored.acted_how == "draft_sent"
      assert %DateTime{} = stored.acted_at
      assert stored.edit_ratio == 0.0
      assert stored.draft_original_body == nil
      assert stored.draft_id == draft.id

      assert_received {:draft_sent, %{edit_ratio: +0.0} = measurements, meta}
      assert Map.keys(measurements) == [:edit_ratio]

      assert meta == %{
               item_id: item.id,
               draft_id: draft.id,
               delivery_id: delivery.id,
               org_id: ctx.org_id
             }

      assert_received {:triage_item, %{count: 1}, %{outcome: "draft_sent", tier: "action"}}
      refute_received {:triage_item, _, %{outcome: "acted_reply"}}

      assert %{drafts_created: 1, drafts_sent: 1, few_edit_sent: 1, acted: 1} =
               Metrics.for_user(ctx.r, since())
    end

    test "a heavy rewrite records a ratio above 0.2 and is not few-edit", ctx do
      {item, draft, _} = triage_draft!(ctx, "Thanks, clauses 7.2 and 9.1 are fine.")

      send_as_reader!(
        ctx,
        draft,
        "Before we agree I need legal to look at 9.1 again; can we talk on Monday?"
      )

      stored = Repo.get!(Item, item.id)
      assert stored.acted_how == "draft_sent"
      assert stored.edit_ratio > 0.2
      assert stored.draft_original_body == nil

      assert %{drafts_sent: 1, few_edit_sent: 0} = Metrics.for_user(ctx.r, since())
    end

    test "a discarded triage draft is not acted and its original body is gone", ctx do
      {item, draft, _} = triage_draft!(ctx, "Thanks, confirmed.")

      {:ok, _} = Drafts.discard({:user, ctx.r.id}, draft.id)

      stored = Repo.get!(Item, item.id)
      assert stored.status == "open"
      assert stored.acted_how == nil
      assert stored.edit_ratio == nil
      assert stored.draft_original_body == nil

      assert %{drafts_created: 1, drafts_sent: 0, few_edit_sent: 0, acted: 0} =
               Metrics.for_user(ctx.r, since())
    end

    test "summary arithmetic: unedited, exactly 0.2, rewritten, discarded and unsent drafts",
         ctx do
      {_, unedited, _} = triage_draft!(ctx, @ten)
      {_, boundary, _} = triage_draft!(ctx, @ten)
      {_, rewritten, _} = triage_draft!(ctx, @ten)
      {_, discarded, _} = triage_draft!(ctx, @ten)
      {_unsent, _, _} = triage_draft!(ctx, @ten)

      send_as_reader!(ctx, unedited)

      # Exactly 2 of 10 words changed: the threshold is inclusive.
      send_as_reader!(ctx, boundary, "one two THREE four five six SEVEN eight nine ten")
      send_as_reader!(ctx, rewritten, "Something else entirely, not this at all.")
      {:ok, _} = Drafts.discard({:user, ctx.r.id}, discarded.id)

      boundary_item = Repo.get_by!(Item, draft_id: boundary.id)
      assert boundary_item.edit_ratio == 0.2

      counts = Metrics.for_user(ctx.r, since())
      assert counts.called_out == 5
      assert counts.drafts_created == 5
      assert counts.drafts_sent == 3
      assert counts.few_edit_sent == 2
      assert counts.acted == 3
      assert_in_delta counts.acted_rate, 3 / 5, 1.0e-9

      org = Metrics.summary(ctx.org_id, since())
      assert org.drafts_sent >= 3 and org.few_edit_sent >= 2
    end
  end

  # ── Sentinels: the Deliverer's parent read and the metrics hook ─────────

  describe "message bodies never leave the mailbox" do
    setup do
      test_pid = self()
      handler = "mail-triage-metrics-sentinel-#{unique()}"

      :ok =
        :telemetry.attach_many(
          handler,
          [
            [:platform, :repo, :query],
            [:platform, :mail, :triage, :item],
            [:platform, :mail, :triage, :draft_sent]
          ],
          fn event, measurements, metadata, _ ->
            # The WHOLE metadata: query, params AND `:result` (the rows).
            send(test_pid, {:telemetry_seen, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    defp captured(fun) do
      _ = collect_telemetry()
      previous = Logger.level()
      Logger.configure(level: :debug)

      log =
        try do
          capture_log([level: :debug], fun)
        after
          Logger.configure(level: previous)
        end

      {log, collect_telemetry()}
    end

    defp leaks?(telemetry, marker) do
      Enum.any?(telemetry, fn {_e, m, meta} ->
        inspect({m, meta}, limit: :infinity, printable_limit: :infinity) =~ marker
      end)
    end

    # Moore's must-fix (stage 5): `Platform.Mail.Deliverer` threads a reply
    # by reading the parent email's Message-ID and References only. The
    # parent's body must not be a result row, a param or a log line.
    test "sending a triage reply never reads the parent email's body into telemetry or the log",
         ctx do
      marker = "PARENT-BODY-#{Ecto.UUID.generate()}"

      {_item, draft, inbound} =
        triage_draft!(ctx, "Thanks, confirmed.", %{
          message_id_header: "<parent-#{ctx.n}@otherco.test>",
          text_body: "Please confirm #{marker}.",
          raw:
            "Message-ID: <parent-#{ctx.n}@otherco.test>\r\n" <>
              "References: <root-#{ctx.n}@otherco.test>\r\n" <>
              "Subject: Clauses\r\n\r\nPlease confirm #{marker}.\r\n" <>
              "References: <not-a-header-#{ctx.n}@otherco.test>\r\n"
        })

      {log, telemetry} =
        captured(fn ->
          {:ok, delivery} = Dispatch.dispatch(draft.id, {:user, ctx.r.id})
          assert delivery.status == "accepted"
        end)

      # The reply threaded, with the parent's References (and only the
      # header block's), so the parent WAS consulted.
      assert_received {:mail_test_adapter, email, _config}
      assert email.headers["In-Reply-To"] == "<parent-#{ctx.n}@otherco.test>"

      assert email.headers["References"] ==
               "<root-#{ctx.n}@otherco.test> <parent-#{ctx.n}@otherco.test>"

      # The capture was live: the send's own queries were seen and logged.
      assert Enum.any?(telemetry, &match?({[:platform, :repo, :query], _, _}, &1))
      assert log =~ "mail_deliveries"

      refute log =~ marker
      refute leaks?(telemetry, marker), "parent body in repo telemetry (params or result rows)"

      # Control: a plain read of the parent's raw puts the marker in the
      # result rows the handler sees, so the refutes above can fail.
      {_log, control} =
        captured(fn ->
          Repo.one(from(m in InboundMessage, where: m.id == ^inbound.id, select: m.raw))
        end)

      assert leaks?(control, marker)
    end

    test "the metrics hook keeps the draft text out of the log, telemetry and PubSub", ctx do
      marker = "DRAFT-TEXT-#{Ecto.UUID.generate()}"
      {item, draft, _} = triage_draft!(ctx, "Confirmed: #{marker} and the rest.")
      :ok = Platform.Inbox.subscribe(ctx.r.id)
      :ok = Platform.Mail.Inbound.subscribe()

      delivery = %Platform.Mail.Delivery{
        id: Ecto.UUID.generate(),
        org_id: ctx.org_id,
        account_id: ctx.box.id,
        draft_id: draft.id,
        recipients: draft.to_addresses,
        body: "Confirmed: #{marker} and the rest!",
        status: "accepted",
        actor_type: "user",
        actor_id: ctx.r.id,
        accepted_at: DateTime.utc_now()
      }

      {log, telemetry} = captured(fn -> assert Metrics.on_delivery_accepted(delivery) == 1 end)

      # Positive controls: the hook ran, read and wrote the item, and logged.
      stored = Repo.get!(Item, item.id)
      assert stored.acted_how == "draft_sent"
      assert stored.edit_ratio > 0.0 and stored.edit_ratio <= 0.2
      assert stored.draft_original_body == nil
      assert log =~ "[Mail.Triage] draft_sent"
      assert Enum.any?(telemetry, &match?({[:platform, :mail, :triage, :draft_sent], _, _}, &1))

      refute log =~ marker
      refute leaks?(telemetry, marker), "draft text in telemetry (params or result rows)"

      {:messages, mailbox} = Process.info(self(), :messages)
      refute inspect(mailbox, limit: :infinity, printable_limit: :infinity) =~ marker
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
