defmodule Platform.Installs.HandoverMailTest do
  @moduledoc """
  Task 01a18f0c stage 4: the requester gets exactly ONE hand-over email when
  their install is ready, through the existing audited mail path, and the
  credential it carries never reaches a log.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Platform.InstallsFixtures

  alias Platform.Accounts.User
  alias Platform.Installs
  alias Platform.Installs.HandoverMail
  alias Platform.Installs.Install
  alias Platform.Installs.Runner
  alias Platform.Installs.Sweeper
  alias Platform.Mail
  alias Platform.Mail.Delivery
  alias Platform.Mail.Draft
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @email "pat@acme-handover.test"

  setup do
    use_fake_backend()

    previous = Application.fetch_env(:platform, :mail_enabled)
    Application.put_env(:platform, :mail_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:platform, :mail_enabled, value)
        :error -> Application.delete_env(:platform, :mail_enabled)
      end
    end)

    org_id = Tenancy.get_org_by_slug!("initech").id
    {mail_admin, account} = account!(org_id)
    put_installs_env(mail_sender: sender_config(org_id, account))

    %{org_id: org_id, account: account, mail_admin: mail_admin}
  end

  defp sender_config(org_id, account),
    do: %{org_id: org_id, account_id: account.id, sender_key: "noreply"}

  defp account!(org_id) do
    n = System.unique_integer([:positive])

    admin =
      %User{}
      |> User.changeset(%{
        email: "handover-mail-#{n}@example.com",
        name: "Handover Mail #{n}",
        oidc_sub: "oidc-handover-mail-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: admin.id, org_id: org_id, role: "admin"})
    |> Repo.insert!()

    {:ok, account} =
      Mail.create_account(
        admin,
        org_id,
        %{
          "name" => "installs-#{n}",
          "smtp_host" => "smtp.installs-#{n}.test",
          "smtp_port" => 2525,
          "smtp_tls" => "none",
          "username" => "installs-relay",
          "internal_only" => false
        },
        %{smtp: "installs-password"}
      )

    {:ok, _} =
      Mail.put_sender(admin, account, %{"key" => "noreply", "address" => "noreply@example.com"})

    {admin, account}
  end

  # A ready install that came from a request, made the way the product
  # makes one: request/1, provision_request/2, a run to ready. The runner's
  # own ready branch sends the email, so `run: false` stops short of it.
  defp ready_request!(email \\ @email) do
    {:ok, :created} =
      Installs.request(%{"name" => "Pat Baker", "email" => email, "business" => "Acme Bakery"})

    row = Repo.one!(from(i in Install, where: i.owner_email == ^email), log: false)
    {:ok, install} = Installs.provision_request(admin!(), row.id)
    install
  end

  defp make_ready!(install) do
    Installs.update!(Installs.get(install.id), %{status: "ready", ready_at: DateTime.utc_now()})
  end

  defp drafts,
    do: Repo.all(from(d in Draft, where: d.responsibility == "installs.ready_handover"))

  defp deliveries,
    do: Repo.all(from(d in Delivery, where: d.responsibility == "installs.ready_handover"))

  defp token_from(body) do
    [_, token] = Regex.run(~r|/install-status/([A-Za-z0-9_-]+)|, body)
    token
  end

  test "a ready requested install gets one queued email with the hand-over page link" do
    install = ready_request!() |> make_ready!()

    assert {:ok, :queued} = HandoverMail.deliver_ready(install.id)

    assert [draft] = drafts()
    assert [delivery] = deliveries()
    assert delivery.status == "queued"
    assert delivery.draft_id == draft.id
    assert draft.to_addresses == [@email]
    assert delivery.recipients == [@email]
    assert draft.subject == "Your Burrow is ready"
    assert draft.body =~ "Hi Pat Baker,"
    assert draft.body =~ "https://#{install.primary_host}"
    assert draft.body =~ "/install-status/"
    assert draft.body =~ "Connect your AI"
    assert draft.body =~ "Burrow, from Kobo"
    refute draft.body =~ ~r/minute|hour|today/i

    install = Installs.get(install.id)
    assert install.handover_email_delivery_id == delivery.id
    assert install.handover_email_claimed_at

    # The emailed token is the install's capability now.
    assert Installs.get_by_token(token_from(draft.body)).id == install.id
  end

  test "repeated and concurrent calls still send exactly one" do
    install = ready_request!() |> make_ready!()

    results =
      [
        Task.async(fn -> HandoverMail.deliver_ready(install.id) end),
        Task.async(fn -> HandoverMail.deliver_ready(install.id) end)
      ]
      |> Enum.map(&Task.await/1)

    assert Enum.sort(results) == [{:ok, :already_claimed}, {:ok, :queued}]

    for _ <- 1..3, do: assert({:ok, :already_claimed} = HandoverMail.deliver_ready(install.id))

    assert length(drafts()) == 1
    assert length(deliveries()) == 1
  end

  test "the runner's ready branch sends it, and a later sweeper tick sends nothing more" do
    install = ready_request!()

    assert Runner.run(install.id) == :ready
    assert [_] = deliveries()

    assert HandoverMail.deliver_pending() == 0
    pid = start_supervised!({Sweeper, interval_ms: :timer.hours(1)})
    _ = :sys.get_state(pid)

    assert length(drafts()) == 1
    assert length(deliveries()) == 1
  end

  test "an install made by create/2 (no request) sends nothing" do
    {install, _token} = create_install!(%{"owner_email" => "direct@acme-handover.test"})
    assert Runner.run(install.id) == :ready

    assert {:ok, :already_claimed} = HandoverMail.deliver_ready(install.id)
    assert drafts() == []
    assert deliveries() == []
    assert Installs.get(install.id).handover_email_claimed_at == nil
  end

  test "an install that is not ready yet is not claimed" do
    install = ready_request!()
    assert {:ok, :already_claimed} = HandoverMail.deliver_ready(install.id)
    assert Installs.get(install.id).handover_email_claimed_at == nil
    assert deliveries() == []
  end

  test "mail disabled or no sender: nothing is written, the claim is released, a later sweep sends",
       %{org_id: org_id, account: account} do
    install = ready_request!() |> make_ready!()
    hash = Installs.get(install.id).status_token_hash

    put_installs_env(mail_sender: %{org_id: org_id, account_id: nil, sender_key: "noreply"})

    log =
      capture_log(fn ->
        assert {:error, :not_configured} = HandoverMail.deliver_ready(install.id)
      end)

    assert log =~ "[installs] hand-over email for #{install.id} not sent: not_configured"

    Application.put_env(:platform, :mail_enabled, false)
    put_installs_env(mail_sender: sender_config(org_id, account))
    assert {:error, :not_configured} = HandoverMail.deliver_ready(install.id)

    assert drafts() == []
    assert deliveries() == []
    install = Installs.get(install.id)
    assert install.handover_email_claimed_at == nil
    # Nothing sent, so no new token was minted either.
    assert install.status_token_hash == hash

    Application.put_env(:platform, :mail_enabled, true)
    assert HandoverMail.deliver_pending() == 1
    assert length(deliveries()) == 1
  end

  test "a policy refusal is recorded once and not retried",
       %{account: account, mail_admin: mail_admin} do
    install = ready_request!() |> make_ready!()

    # An internal-only account refuses an outside recipient.
    {:ok, internal} =
      Mail.update_account(mail_admin, account, %{"internal_only" => true})

    assert internal.internal_only

    assert {:ok, :refused} = HandoverMail.deliver_ready(install.id)
    assert [%{status: "refused"} = delivery] = deliveries()
    assert Installs.get(install.id).handover_email_delivery_id == delivery.id
    assert HandoverMail.deliver_pending() == 0
    assert length(deliveries()) == 1
  end

  test "neither the token nor the hand-over URL reaches the log, with query logging at :debug" do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    log =
      capture_log([level: :debug], fn ->
        install = ready_request!()
        assert Runner.run(install.id) == :ready
        _ = HandoverMail.deliver_pending()
        _ = HandoverMail.deliver_ready(install.id)
      end)

    [draft] = drafts()
    token = token_from(draft.body)

    # Positive control: debug query lines and the outcome line were captured.
    assert log =~ "QUERY OK"
    assert log =~ "[installs] hand-over email for"
    refute log =~ token
    refute log =~ "install-status/"
    refute log =~ "Connect your AI"
  end

  test "create_system/3 and enqueue/3 without log: false still query-log as before",
       %{org_id: org_id, account: account} do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    marker = "logged-body-#{System.unique_integer([:positive])}"

    log =
      capture_log([level: :debug], fn ->
        {:ok, draft} =
          Mail.Drafts.create_system(org_id, %{
            account_id: account.id,
            sender_key: "noreply",
            to_addresses: ["someone@example.com"],
            subject: "s",
            body: marker
          })

        {:ok, _} = Mail.Dispatch.enqueue(draft.id, :system)
      end)

    assert log =~ marker
  end
end
