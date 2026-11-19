defmodule Platform.Mail.Triage.MetricsTest do
  @moduledoc """
  The acted-on metric (task 01a1f426 stage 3): `Platform.Mail.Triage.Metrics`.
  An item is acted when the reader replies from that mailbox (through the
  real `Platform.Mail.Dispatch`, recorded by `Platform.Mail.TestAdapter`),
  or marks it Done. Rate arithmetic is checked with a denominator that is
  not 1, 2 or a divisor-friendly 10.

  async: false — `:mail_enabled`, the stub provider and the telemetry
  handler are application-wide.
  """
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures
  import Platform.Test.MailPrivacyFixtures
  import Platform.Test.MailTriageFixtures

  alias Platform.Mail
  alias Platform.Mail.{Dispatch, Draft}
  alias Platform.Mail.Triage
  alias Platform.Mail.Triage.{Item, Metrics}
  alias Platform.Test.MailTriageStub, as: Stub

  setup do
    enable_mail!()
    org_id = acme_org_id()
    n = unique()

    admin = user!("admin") |> member!(org_id, "admin")
    r = user!("r") |> member!(org_id)
    agent = triage_agent!()

    box =
      account!(admin, org_id, %{"name" => "Rbox #{n}", "internal_only" => false})
      |> then(&personal!(admin, &1, r))

    grant_agent!(r, box, agent)

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

    %{org_id: org_id, n: n, r: r, box: box, agent: agent}
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
end
