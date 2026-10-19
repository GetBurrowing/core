defmodule Platform.Experiments.MailSubscriberTest do
  @moduledoc """
  The Experiments side of the Mail → Experiments seam (task 01a0d415
  stage 3): `Platform.Experiments.Signals.MailSubscriber` turns
  `Mail.Inbound`'s ID-only ingest event into one signal, and
  `MailSource.reconcile/0` recovers a row ingested while it was down.

  async: false — the subscriber is a named process, the sandbox runs in
  shared mode so its Task children see this test's rows, and the stub
  provider is installed through Application env.
  """

  use Platform.DataCase, async: false

  import Platform.Test.ExperimentsMailFixtures

  alias Platform.Experiments.Signals
  alias Platform.Experiments.Signals.MailSource
  alias Platform.Experiments.Signals.MailSubscriber
  alias Platform.Test.ExperimentsLabelerStub, as: Stub
  alias Platform.Tenancy

  @verdict %{
    "label" => "screen",
    "subject_id" => nil,
    "confidence" => 0.7,
    "reason" => "Asks to schedule a screening call."
  }

  setup do
    org = Tenancy.get_org_by_slug!("initech").id
    scientist!()
    :ok = Stub.install!(Stub.json(@verdict))
    %{org: org, account: account!(org)}
  end

  test "the application does not start the subscriber in test" do
    refute Process.whereis(MailSubscriber)
  end

  test "a broadcast yields exactly one signal row", ctx do
    experiment = mail_experiment!(%{org_id: ctx.org})
    start_supervised!(MailSubscriber)

    {1, inbound} = ingest!(ctx.account)

    assert_eventually(fn -> length(Signals.list(experiment)) == 1 end)
    assert_receive {:labeler_stub_called, _, _, _}

    # Settle, then prove no second row arrived. (A second labeler CALL is
    # possible if the start-up reconcile races the broadcast; the idempotency
    # index is what keeps that to one row, and one row is the contract.)
    Process.sleep(100)
    assert [signal] = Signals.list(experiment)
    assert signal.source_id == inbound.id
    assert signal.label == "screen"
  end

  test "reconcile picks up a row ingested while the subscriber was down; twice is one row",
       ctx do
    experiment = mail_experiment!(%{org_id: ctx.org})

    # No subscriber is running: this broadcast is lost.
    {1, inbound} = ingest!(ctx.account)
    assert Signals.list(experiment) == []

    assert MailSource.reconcile() == 1
    assert MailSource.reconcile() == 0

    assert [signal] = Signals.list(experiment)
    assert signal.source_id == inbound.id
  end

  test "starting the subscriber reconciles missed rows", ctx do
    experiment = mail_experiment!(%{org_id: ctx.org})
    {1, _inbound} = ingest!(ctx.account)
    assert Signals.list(experiment) == []

    start_supervised!(MailSubscriber)

    assert_eventually(fn -> length(Signals.list(experiment)) == 1 end)
  end
end
