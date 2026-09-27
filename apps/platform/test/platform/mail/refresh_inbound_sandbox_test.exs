defmodule Platform.Mail.RefreshInboundSandboxTest do
  @moduledoc """
  Empirical sandbox-safety check for `Platform.Mail.refresh_inbound/2`
  (task 01a089e5 stage 4).

  `refresh_inbound/2` streams `Platform.Mail.Inbound.poll_now/2` over each
  eligible account via plain `Task.async_stream/3` — one of the three sites
  the stage-1 census flagged `known_gap: true` because it reaches `Repo`
  transitively and had NEVER been exercised by any test (not even under
  `async: false`), so nothing established whether it survives the
  `async: true` manual-mode sandbox.

  This file runs `async: true` on purpose — it exists specifically to prove
  (or disprove) that `Task.async_stream`'s own `$callers` propagation is
  enough to let the spawned closure's `Repo` calls resolve against the
  test's checked-out connection. `Mail.Config.enabled?/0` is `false` by
  default in `config/test.exs`, so `Inbound.poll_now/2` takes its
  in-process `poll_safely/1` branch here (no hop through the separately
  supervised poller `GenServer`, which would be a different, unrelated
  cross-process hazard) — the same shape every other test in this suite
  would hit if it called `refresh_inbound/2` without first flipping
  `:mail_enabled`.
  """
  use Platform.DataCase, async: true

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Mail
  alias Platform.Mail.Imap.FakeClient
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp admin!(org_id) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "refresh-inbound-#{n}@example.com",
        name: "Refresh Inbound #{n}",
        oidc_sub: "oidc-refresh-inbound-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: "admin"})
    |> Repo.insert!()

    user
  end

  defp space! do
    n = System.unique_integer([:positive])
    {:ok, space} = Chat.create_space(%{name: "Mail #{n}", slug: "mail-#{n}", kind: "channel"})
    space
  end

  defp account!(admin, org_id, space) do
    n = System.unique_integer([:positive])
    host = "refresh-imap-#{n}.acme.test"

    attrs = %{
      "name" => "support-#{n}",
      "smtp_tls" => "starttls",
      "username" => "support@acme.test",
      "imap_host" => host,
      "imap_port" => 993,
      "imap_tls" => "tls",
      "read_enabled" => true,
      "inbound_space_id" => space.id
    }

    {:ok, account} = Mail.create_account(admin, org_id, attrs, %{imap: "imap-pass"})
    account
  end

  setup do
    org_id = Tenancy.get_org_by_slug!("soylent").id
    admin = admin!(org_id)
    space = space!()
    %{org_id: org_id, admin: admin, space: space}
  end

  test "refresh_inbound/2 polls eligible accounts through Task.async_stream without an OwnershipError",
       ctx do
    account = account!(ctx.admin, ctx.org_id, ctx.space)
    FakeClient.start_server!(account.imap_host)
    FakeClient.put_folder(account.imap_host, "INBOX")
    FakeClient.deliver(account.imap_host, "INBOX", "From: a@x.test\r\n\r\nhi\r\n")

    assert {:ok, [{polled_account, {:ok, summary}}]} =
             Mail.refresh_inbound(ctx.admin, ctx.org_id)

    assert polled_account.id == account.id
    assert %{ingested: _} = summary
  end

  test "refresh_inbound/2 with several concurrent accounts never raises DBConnection.OwnershipError",
       ctx do
    accounts =
      for _ <- 1..5 do
        account = account!(ctx.admin, ctx.org_id, ctx.space)
        FakeClient.start_server!(account.imap_host)
        FakeClient.put_folder(account.imap_host, "INBOX")
        account
      end

    assert {:ok, results} = Mail.refresh_inbound(ctx.admin, ctx.org_id)
    assert length(results) == length(accounts)

    for {_account, outcome} <- results do
      assert {:ok, %{ingested: _}} = outcome
    end
  end
end
