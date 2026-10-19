# Live GreenMail proof for the Email module (task 01a0cf21 stage 7).
#
# COMPILED ONLY WHEN `GREENMAIL_HOST` IS SET. CI does not set it, so CI does
# not run this file — not skipped, not excluded: the module does not exist
# there. The CI-run protocol coverage is `wire_client_test.exs` (GreenMail's
# recorded bytes over a loopback socket) and
# `test/platform/mail/smtp_receipt_test.exs`.
#
# Run it on test-host against a real container:
#
#   podman run -d --name greenmail-<id> --network dev \
#     -e GREENMAIL_OPTS='-Dgreenmail.setup.test.all -Dgreenmail.hostname=0.0.0.0 -Dgreenmail.auth.disabled' \
#     docker.io/greenmail/standalone:2.1.14
#   GREENMAIL_HOST=greenmail-<id> mix test test/platform/mail/imap/greenmail_live_test.exs
#
# GREENMAIL_IMAP_PORT (3143) and GREENMAIL_SMTP_PORT (3025) override the ports.
if System.get_env("GREENMAIL_HOST") do
  defmodule Platform.Mail.Imap.GreenMailLiveTest do
    @moduledoc """
    The real `Platform.Mail.Imap.WireClient` through `Platform.Mail.Inbound.poll/2`
    and the real `Swoosh.Adapters.SMTP` through "Send test", against a live
    GreenMail 2.1.14. See the file header for how to run it.
    """
    use Platform.DataCase, async: false

    import Ecto.Query
    import ExUnit.CaptureLog

    alias Platform.Accounts.User
    alias Platform.Chat
    alias Platform.Mail
    alias Platform.Mail.Imap.WireClient
    alias Platform.Mail.Inbound
    alias Platform.Mail.InboundMessage
    alias Platform.Tenancy
    alias Platform.Tenancy.OrgMembership

    @host System.get_env("GREENMAIL_HOST")
    @imap_port String.to_integer(System.get_env("GREENMAIL_IMAP_PORT", "3143"))
    @smtp_port String.to_integer(System.get_env("GREENMAIL_SMTP_PORT", "3025"))

    # ── raw IMAP, for seeding and for reading flags (NOT the client under test)

    defp imap!(user) do
      {:ok, s} =
        :gen_tcp.connect(String.to_charlist(@host), @imap_port, [
          :binary,
          active: false,
          packet: :line
        ])

      {:ok, "* OK" <> _} = :gen_tcp.recv(s, 0, 5_000)
      {:ok, _} = raw_cmd(s, ~s(LOGIN "#{user}" "x"))
      s
    end

    defp raw_cmd(s, line, literal \\ nil) do
      tag = "T#{System.unique_integer([:positive])}"

      if literal do
        :ok = :gen_tcp.send(s, "#{tag} #{line} {#{byte_size(literal)}}\r\n")
        {:ok, "+" <> _} = :gen_tcp.recv(s, 0, 5_000)
        :ok = :gen_tcp.send(s, [literal, "\r\n"])
      else
        :ok = :gen_tcp.send(s, "#{tag} #{line}\r\n")
      end

      collect(s, tag, [])
    end

    defp collect(s, tag, acc) do
      {:ok, line} = :gen_tcp.recv(s, 0, 5_000)

      if String.starts_with?(line, tag <> " ") do
        if line =~ ~r/\A\S+ OK/, do: {:ok, Enum.reverse(acc)}, else: {:error, line}
      else
        collect(s, tag, [line | acc])
      end
    end

    defp append!(user, folder, raw) do
      s = imap!(user)
      {:ok, _} = raw_cmd(s, ~s(APPEND "#{folder}"), raw)
      raw_cmd(s, "LOGOUT")
      :gen_tcp.close(s)
    end

    defp seen_flags(user, folder) do
      s = imap!(user)
      {:ok, _} = raw_cmd(s, ~s(EXAMINE "#{folder}"))
      {:ok, lines} = raw_cmd(s, "FETCH 1:* (FLAGS)")
      raw_cmd(s, "LOGOUT")
      :gen_tcp.close(s)
      Enum.filter(lines, &(&1 =~ "FETCH"))
    end

    defp raw(message_id) do
      "From: Alice <alice@example.test>\r\nTo: support@acme.test\r\nSubject: live\r\n" <>
        "Date: Wed, 23 Sep 2026 10:00:00 +0000\r\nMessage-ID: <#{message_id}>\r\n\r\nbody\r\n"
    end

    # ── fixtures

    setup do
      previous_enabled = Application.fetch_env(:platform, :mail_enabled)
      previous_mailer = Application.get_env(:platform, Platform.Mail.Mailer)
      Application.put_env(:platform, :mail_enabled, true)

      on_exit(fn ->
        Application.put_env(:platform, Platform.Mail.Mailer, previous_mailer)

        case previous_enabled do
          {:ok, v} -> Application.put_env(:platform, :mail_enabled, v)
          :error -> Application.delete_env(:platform, :mail_enabled)
        end
      end)

      n = System.unique_integer([:positive])
      org_id = Tenancy.get_org_by_slug!("initech").id

      admin =
        %User{}
        |> User.changeset(%{
          email: "live-#{n}@acme.test",
          name: "Live #{n}",
          oidc_sub: "oidc-live-#{n}"
        })
        |> Repo.insert!()

      %OrgMembership{}
      |> OrgMembership.changeset(%{user_id: admin.id, org_id: org_id, role: "admin"})
      |> Repo.insert!()

      {:ok, space} = Chat.create_space(%{name: "Live #{n}", slug: "live-#{n}", kind: "channel"})

      # A fresh GreenMail user per test; GreenMail creates it on first login.
      user = "support-#{n}@acme.test"
      s = imap!(user)
      {:ok, _} = raw_cmd(s, ~s(CREATE "Support"))
      raw_cmd(s, "LOGOUT")
      :gen_tcp.close(s)

      %{org_id: org_id, admin: admin, space: space, user: user, n: n}
    end

    defp account!(ctx, overrides) do
      attrs =
        Map.merge(
          %{
            "name" => "live-#{ctx.n}-#{System.unique_integer([:positive])}",
            "smtp_host" => @host,
            "smtp_port" => @smtp_port,
            "smtp_tls" => "none",
            "username" => ctx.user,
            "imap_host" => @host,
            "imap_port" => @imap_port,
            "imap_tls" => "none",
            "read_enabled" => true,
            "inbound_space_id" => ctx.space.id
          },
          overrides
        )

      {:ok, account} =
        Mail.create_account(ctx.admin, ctx.org_id, attrs, %{smtp: "x", imap: "x"})

      account
    end

    defp poll!(account) do
      {:ok, summary} = Inbound.poll(Repo.reload!(account), client: WireClient)
      summary
    end

    defp folders_of(account) do
      Repo.all(
        from(m in InboundMessage,
          where: m.account_id == ^account.id,
          order_by: [m.folder, m.uid],
          select: {m.folder, m.message_id_key}
        )
      )
    end

    test "scope [\"Support\"] ingests only Support mail; nothing is \\Seen", ctx do
      account = account!(ctx, %{"read_folders" => ["Support"]})
      assert %{folders: ["Support"], ingested: 0} = poll!(account)

      append!(ctx.user, "INBOX", raw("inbox-#{ctx.n}@x.test"))
      append!(ctx.user, "Support", raw("support-#{ctx.n}@x.test"))

      assert %{folders: ["Support"], ingested: 1} = poll!(account)
      assert folders_of(account) == [{"Support", "support-#{ctx.n}@x.test"}]

      for line <- seen_flags(ctx.user, "Support"), do: refute(line =~ "\\Seen")
      IO.puts("[live] scoped: #{inspect(folders_of(account))}")
      IO.puts("[live] Support flags after poll: #{inspect(seen_flags(ctx.user, "Support"))}")
    end

    test "an empty scope ingests every folder", ctx do
      account = account!(ctx, %{})
      assert %{folders: folders, ingested: 0} = poll!(account)
      assert "INBOX" in folders and "Support" in folders

      append!(ctx.user, "INBOX", raw("inbox-#{ctx.n}@x.test"))
      append!(ctx.user, "Support", raw("support-#{ctx.n}@x.test"))

      assert %{ingested: 2} = poll!(account)

      assert folders_of(account) == [
               {"INBOX", "inbox-#{ctx.n}@x.test"},
               {"Support", "support-#{ctx.n}@x.test"}
             ]

      for line <- seen_flags(ctx.user, "INBOX"), do: refute(line =~ "\\Seen")
      IO.puts("[live] unscoped: #{inspect(folders_of(account))}")
    end

    test "six polls log no GenServer crash", ctx do
      account = account!(ctx, %{})

      log =
        capture_log(fn ->
          for i <- 1..6 do
            append!(ctx.user, "Support", raw("six-#{i}-#{ctx.n}@x.test"))
            assert {:ok, _} = Inbound.poll(Repo.reload!(account), client: WireClient)
          end

          Process.sleep(500)
        end)

      refute log =~ "terminating"
      refute log =~ "[error]"
      assert length(folders_of(account)) == 5

      IO.puts(
        "[live] six polls: #{length(folders_of(account))} ingested, log bytes=#{byte_size(log)}"
      )
    end

    test "Send test over real SMTP reports SMTP 250", ctx do
      Application.put_env(:platform, Platform.Mail.Mailer, adapter: Swoosh.Adapters.SMTP)
      account = account!(ctx, %{})
      {:ok, _} = Mail.put_sender(ctx.admin, account, %{"key" => "ops", "address" => ctx.user})

      result = Mail.send_test(ctx.admin, account, "ops")
      assert {:ok, delivery} = result
      assert {:neutral, text} = PlatformWeb.EmailLive.test_result(result)
      assert text == "Accepted (SMTP 250) for #{ctx.admin.email}"
      IO.puts("[live] smtp_response=#{inspect(delivery.smtp_response)} ui=#{inspect(text)}")
    end
  end
end
