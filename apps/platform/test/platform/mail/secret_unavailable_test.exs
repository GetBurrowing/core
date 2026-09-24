defmodule Platform.Mail.SecretUnavailableTest do
  @moduledoc """
  A mail credential that no longer decrypts must stop the send or the poll
  (task 01a0cf21 stage 7).

  The defect this pins: a dev boot without `VAULT_MASTER_KEY` mints a new key,
  so every stored credential stops decrypting. `Platform.Vault.get_unique/2`
  then answers `{:ok, :error}` (Cloak's AES-GCM returns `:error` for a failed
  tag check and the vault wraps it), `Platform.Mail.fetch_secret/2` passed
  that through as success, and the Deliverer sent without SMTP AUTH while the
  IMAP client was handed `:error` as the password.

  The simulation corrupts one byte of the stored ciphertext, which fails the
  AES-GCM tag check exactly as a changed key does; the first test proves the
  vault really answers `{:ok, :error}` for it, so the others are not passing
  against a different failure.

  async: false — flips `:mail_enabled`.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Mail
  alias Platform.Mail.Delivery
  alias Platform.Mail.Imap.FakeClient
  alias Platform.Mail.Imap.WireClient
  alias Platform.Mail.Inbound
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  setup do
    previous = Application.fetch_env(:platform, :mail_enabled)
    Application.put_env(:platform, :mail_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:platform, :mail_enabled, value)
        :error -> Application.delete_env(:platform, :mail_enabled)
      end
    end)

    org_id = Tenancy.get_org_by_slug!("soylent").id
    n = System.unique_integer([:positive])

    admin =
      %User{}
      |> User.changeset(%{
        email: "secret-#{n}@example.com",
        name: "Secret #{n}",
        oidc_sub: "oidc-secret-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: admin.id, org_id: org_id, role: "admin"})
    |> Repo.insert!()

    {:ok, space} =
      Platform.Chat.create_space(%{name: "Secret #{n}", slug: "secret-#{n}", kind: "channel"})

    {:ok, account} =
      Mail.create_account(
        admin,
        org_id,
        %{
          "name" => "secret-#{n}",
          "smtp_host" => "smtp.secret-#{n}.test",
          "smtp_port" => 2525,
          "smtp_tls" => "none",
          "username" => "relay-user",
          "imap_host" => "imap.secret-#{n}.test",
          "imap_port" => 993,
          "imap_tls" => "tls",
          "read_enabled" => true,
          "inbound_space_id" => space.id
        },
        %{smtp: "smtp-pass", imap: "imap-pass"}
      )

    {:ok, _} =
      Mail.put_sender(admin, account, %{"key" => "ops", "address" => "ops@example.test"})

    %{admin: admin, account: account}
  end

  defp corrupt_secret!(account, kind) do
    slug = Mail.secret_slug(account.id, kind)
    query = from(c in "vault_credentials", where: c.slug == ^slug)
    [stored] = Repo.all(select(query, [c], c.encrypted_data))

    # Flip the LAST byte: the envelope (cipher tag, IV, AES-GCM tag) still
    # parses, so the cipher is found and the tag check is what fails.
    size = byte_size(stored) - 1
    <<head::binary-size(size), last>> = stored

    {1, _} =
      Repo.update_all(query, set: [encrypted_data: <<head::binary, Bitwise.bxor(last, 1)>>])
  end

  test "positive control: a corrupted credential is {:ok, :error} at the vault", ctx do
    corrupt_secret!(ctx.account, :smtp)

    scope = Mail.secret_scope(ctx.account)

    assert {:ok, :error} =
             Platform.Vault.get_unique(Mail.secret_slug(ctx.account.id, :smtp),
               scope: scope,
               accessor: scope
             )
  end

  test "fetch_secret refuses an undecryptable value", ctx do
    assert {:ok, "smtp-pass"} = Mail.fetch_secret(ctx.account, :smtp)
    corrupt_secret!(ctx.account, :smtp)
    assert {:error, :secret_unavailable} = Mail.fetch_secret(ctx.account, :smtp)
    assert {:ok, "imap-pass"} = Mail.fetch_secret(ctx.account, :imap)
  end

  test "Send test fails closed: nothing reaches the adapter, the delivery names why", ctx do
    corrupt_secret!(ctx.account, :smtp)

    assert {:error, {:failed, error, %Delivery{} = delivery}} =
             Mail.send_test(ctx.admin, ctx.account, "ops")

    refute_received {:mail_test_adapter, _email, _config}
    assert error =~ "secret_unavailable"
    assert Repo.get!(Delivery, delivery.id).status == "failed"

    assert {:error, "Failed: " <> _} =
             PlatformWeb.EmailLive.test_result({:error, {:failed, error, delivery}})
  end

  test "a poll fails closed: the IMAP client is never called", ctx do
    host = ctx.account.imap_host
    FakeClient.start_server!(host)
    FakeClient.put_folder(host, "INBOX")
    corrupt_secret!(ctx.account, :imap)

    assert {:error, :secret_unavailable} =
             Inbound.poll(Repo.reload!(ctx.account), client: FakeClient)

    assert FakeClient.calls(host) == []
  end

  test "the wire client refuses a non-string or empty password without connecting" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    for password <- [:error, nil, ""] do
      assert {:error, :credential_unavailable} =
               WireClient.connect(%{
                 host: "127.0.0.1",
                 port: port,
                 tls: "none",
                 username: "u",
                 password: password
               })
    end

    assert {:error, :timeout} = :gen_tcp.accept(listen, 200)
    :gen_tcp.close(listen)
  end
end
