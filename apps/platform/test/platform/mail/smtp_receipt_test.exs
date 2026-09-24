defmodule Platform.Mail.SmtpReceiptTest do
  @moduledoc """
  "Send test" over the REAL `Swoosh.Adapters.SMTP` / gen_smtp stack to a
  loopback socket that answers with GreenMail 2.1.14's recorded SMTP bytes
  (task 01a0cf21 stage 7). Runs in the default suite and in CI.

  The defect it pins: GreenMail answered the end of DATA with `250 OK`, but
  gen_smtp's `try_DATA/4` matches `<<"250 ", Receipt/binary>>` and returns
  only `Receipt` ("OK"), so the stored `smtp_response` carried no code and the
  form said "Accepted (SMTP)". The recording test adapter used elsewhere
  returns a receipt WITH a code, which is why no earlier test saw it.

  async: false — swaps the mailer adapter and `:mail_enabled` in app env.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Mail
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # Recorded from greenmail/standalone:2.1.14 on 2026-09-23 (the AUTH LOGIN
  # prompts are RFC 4954's; GreenMail's AUTH PLAIN reply was recorded).
  @banner "220 /10.89.2.201 GreenMail SMTP Service v2.1.14 ready\r\n"
  @ehlo "250-/10.89.2.201\r\n250-AUTH PLAIN LOGIN XOAUTH2\r\n250 SMTPUTF8\r\n"
  @auth_ok "235 2.7.0  Authentication Succeeded\r\n"

  defp start_smtp!(test_pid) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :line,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 10_000)
        :ok = :gen_tcp.send(socket, @banner)
        smtp_loop(socket, test_pid, :command)
      end)

    :ok = :gen_tcp.controlling_process(listen, server)
    on_exit(fn -> Process.exit(server, :kill) end)
    port
  end

  defp smtp_loop(socket, test_pid, mode) do
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, line} ->
        send(test_pid, {:smtp_line, mode, line})

        {reply, next} = smtp_reply(mode, line)
        if reply, do: :ok = :gen_tcp.send(socket, reply)

        if next == :closed,
          do: :gen_tcp.close(socket),
          else: smtp_loop(socket, test_pid, next)

      {:error, _} ->
        :ok
    end
  end

  defp smtp_reply(:data, ".\r\n"), do: {"250 OK\r\n", :command}
  defp smtp_reply(:data, _line), do: {nil, :data}
  defp smtp_reply(:auth_user, _), do: {"334 UGFzc3dvcmQ6\r\n", :auth_pass}
  defp smtp_reply(:auth_pass, _), do: {@auth_ok, :command}

  defp smtp_reply(:command, line) do
    case line |> String.upcase() |> String.split([" ", "\r\n"], parts: 2) |> hd() do
      verb when verb in ["EHLO", "HELO"] -> {@ehlo, :command}
      "AUTH" -> auth_reply(line)
      "MAIL" -> {"250 OK\r\n", :command}
      "RCPT" -> {"250 OK\r\n", :command}
      "DATA" -> {"354 Start mail input; end with <CRLF>.<CRLF>\r\n", :data}
      "QUIT" -> {"221 /10.89.2.201 Service closing transmission channel\r\n", :closed}
      "RSET" -> {"250 OK\r\n", :command}
      _ -> {"500 unrecognised\r\n", :command}
    end
  end

  defp auth_reply(line) do
    if line =~ ~r/\AAUTH LOGIN/i,
      do: {"334 VXNlcm5hbWU6\r\n", :auth_user},
      else: {@auth_ok, :command}
  end

  setup do
    previous_enabled = Application.fetch_env(:platform, :mail_enabled)
    previous_mailer = Application.get_env(:platform, Platform.Mail.Mailer)
    Application.put_env(:platform, :mail_enabled, true)
    Application.put_env(:platform, Platform.Mail.Mailer, adapter: Swoosh.Adapters.SMTP)

    on_exit(fn ->
      Application.put_env(:platform, Platform.Mail.Mailer, previous_mailer)

      case previous_enabled do
        {:ok, v} -> Application.put_env(:platform, :mail_enabled, v)
        :error -> Application.delete_env(:platform, :mail_enabled)
      end
    end)

    n = System.unique_integer([:positive])
    org_id = Tenancy.get_org_by_slug!("soylent").id

    admin =
      %User{}
      |> User.changeset(%{
        email: "receipt-#{n}@example.com",
        name: "Receipt #{n}",
        oidc_sub: "oidc-receipt-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: admin.id, org_id: org_id, role: "admin"})
    |> Repo.insert!()

    port = start_smtp!(self())

    {:ok, account} =
      Mail.create_account(
        admin,
        org_id,
        %{
          "name" => "receipt-#{n}",
          "smtp_host" => "127.0.0.1",
          "smtp_port" => port,
          "smtp_tls" => "none",
          "username" => "relay-user"
        },
        %{smtp: "relay-pass"}
      )

    {:ok, _} = Mail.put_sender(admin, account, %{"key" => "ops", "address" => "ops@example.test"})

    %{admin: admin, account: account}
  end

  test "GreenMail's bare `250 OK` is stored and shown as SMTP 250", ctx do
    result = Mail.send_test(ctx.admin, ctx.account, "ops")

    assert {:ok, delivery} = result
    assert delivery.status == "accepted"
    assert delivery.smtp_response == "250 OK"

    assert PlatformWeb.EmailLive.test_result(result) ==
             {:neutral, "Accepted (SMTP 250) for #{ctx.admin.email}"}

    # The real client authenticated with the vault credential before sending.
    assert_received {:smtp_line, :command, "AUTH" <> _}
    assert_received {:smtp_line, :data, ".\r\n"}
  end
end
