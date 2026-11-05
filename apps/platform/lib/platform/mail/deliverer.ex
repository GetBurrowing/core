defmodule Platform.Mail.Deliverer do
  @moduledoc """
  Hands one committed `mail_deliveries` row to SMTP (task
  01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 2).

  The plan called this `Platform.Mail.Sender.deliver/1`; `Platform.Mail.Sender`
  is already the `mail_senders` schema (stage 1), so the worker lives here.

  `deliver/1` RE-READS the row from the database and requires status
  `sending`. An uncommitted row is invisible to it and a refused row is
  rejected, so the only way to reach SMTP is through a policy decision that
  was already committed by `Platform.Mail.Dispatch`. It refuses to run inside
  a transaction for the same reason.

  It builds the `Swoosh.Email` from the SNAPSHOT (From = the sender address
  and display name, To = the recorded recipients, Message-ID
  `<delivery_id@sender-domain>`), builds the relay config from the account
  and its Vault secret (`Platform.Mail.fetch_secret/2`), calls
  `Platform.Mail.Mailer.deliver/2` inside `try/rescue/catch`, and records:

    * `accepted` + `smtp_response` + `accepted_at` — the relay answered 250
      to the end of DATA; `smtp_response` is `"250 "` plus gen_smtp's receipt
      text, which arrives with the code stripped (see `format_receipt/1`);
    * `failed` + `error` — anything else, including a raise or an exit.

  The word is `accepted`: SMTP acceptance is the only acknowledgment there
  is, and it is not delivery.
  """

  alias Platform.Mail
  alias Platform.Mail.Account
  alias Platform.Mail.Delivery
  alias Platform.Mail.Mailer
  alias Platform.Mail.Sender
  alias Platform.Repo

  @doc """
  Deliver the committed, `sending` delivery `delivery_id`.

  Returns `{:ok, delivery}` (accepted), `{:error, {:failed, error, delivery}}`,
  or `{:error, :not_found | :in_transaction | {:not_sendable, status}}` when
  nothing was attempted.
  """
  @spec deliver(binary()) ::
          {:ok, Delivery.t()}
          | {:error, {:failed, String.t(), Delivery.t()}}
          | {:error, :not_found | :in_transaction | {:not_sendable, String.t()}}
  def deliver(delivery_id) when is_binary(delivery_id) do
    if Repo.in_transaction?() do
      {:error, :in_transaction}
    else
      case Repo.get(Delivery, delivery_id) do
        nil -> {:error, :not_found}
        %Delivery{status: "sending"} = delivery -> attempt(delivery)
        %Delivery{status: status} -> {:error, {:not_sendable, status}}
      end
    end
  end

  defp attempt(%Delivery{} = delivery) do
    account = Repo.get!(Account, delivery.account_id)

    result = safe_deliver(fn -> send_via_mailer(delivery, account) end)

    case result do
      {:ok, receipt} -> record_accepted(delivery, receipt)
      {:error, error} -> record_failed(delivery, error)
    end
  end

  # Building the relay config (Vault read, CA store) is inside the guard too:
  # every way this can go wrong must end as a recorded `failed`, never as a
  # crash that leaves the row stuck at `sending`.
  defp safe_deliver(fun) do
    case fun.() do
      {:ok, receipt} -> {:ok, receipt}
      {:error, reason} -> {:error, format_error(reason)}
    end
  rescue
    exception -> {:error, "raised: " <> Exception.message(exception)}
  catch
    :exit, reason -> {:error, "exit: " <> inspect(reason)}
    kind, reason -> {:error, "#{kind}: " <> inspect(reason)}
  end

  defp send_via_mailer(delivery, account) do
    with {:ok, config} <- smtp_config(account) do
      delivery |> build_email() |> Mailer.deliver(config)
    end
  end

  @doc false
  # Public for the deliverer tests only; `deliver/1` is the API.
  @spec build_email(Delivery.t()) :: Swoosh.Email.t()
  def build_email(%Delivery{} = delivery) do
    Swoosh.Email.new()
    |> Swoosh.Email.from(from(delivery))
    |> Swoosh.Email.to(delivery.recipients)
    |> Swoosh.Email.subject(delivery.subject || "")
    |> Swoosh.Email.text_body(delivery.body || "")
    |> Swoosh.Email.header("Message-ID", delivery.message_id_header)
    |> put_html(delivery.html_body)
    |> put_reply_to(delivery.reply_to)
    |> put_calendar(delivery.calendar_method, delivery.calendar_ics)
  end

  defp put_html(email, html) when is_binary(html) and html != "",
    do: Swoosh.Email.html_body(email, html)

  defp put_html(email, _html), do: email

  defp put_reply_to(email, reply_to) when is_binary(reply_to) and reply_to != "",
    do: Swoosh.Email.reply_to(email, reply_to)

  defp put_reply_to(email, _reply_to), do: email

  # A calendar invite (task 01a1a933 stages 1-2). Two parts carry the same
  # iCalendar bytes:
  #
  #   * a `text/calendar; charset=UTF-8; method=<METHOD>` part, which is what
  #     Gmail, Outlook and Apple Mail key their Accept/Decline bar on;
  #   * an `invite.ics` attachment (`application/ics`) for clients that only
  #     offer a file to open.
  #
  # Swoosh builds its multipart/alternative from text_body + html_body only,
  # so the calendar part is handed over as an attachment entry carrying its
  # own Content-Type header, and `Platform.Mail.Mime` (what
  # `Platform.Mail.SmtpAdapter` sends) moves it INSIDE the alternative:
  #
  #   multipart/mixed
  #   ├── multipart/alternative
  #   │   ├── text/plain; charset=utf-8
  #   │   ├── text/html; charset=utf-8        (when html_body is set)
  #   │   └── text/calendar; charset=UTF-8; method=REQUEST
  #   └── application/ics; invite.ics         (attachment, base64)
  #
  # Verified by parsing `Mime.render/2` output in
  # test/platform/mail/deliverer_test.exs and the real adapter's DATA bytes
  # in test/platform/mail/smtp_receipt_test.exs.
  defp put_calendar(email, method, ics)
       when method in ["REQUEST", "CANCEL"] and is_binary(ics) and ics != "" do
    calendar_type = "text/calendar; charset=UTF-8; method=#{method}"

    # `Swoosh.Email.attachment/2` prepends, so the .ics file goes on first
    # to come out last.
    email
    |> Swoosh.Email.attachment(
      Swoosh.Attachment.new({:data, ics},
        filename: "invite.ics",
        content_type: "application/ics",
        type: :attachment
      )
    )
    |> Swoosh.Email.attachment(
      Swoosh.Attachment.new({:data, ics},
        filename: "invite.ics",
        content_type: "text/calendar",
        type: :attachment,
        headers: [{"Content-Type", calendar_type}, {"Content-Disposition", "inline"}]
      )
    )
  end

  defp put_calendar(email, _method, _ics), do: email

  # The display name is presentation, read from the sender at send time; the
  # address is the snapshot and never changes.
  defp from(%Delivery{account_id: account_id, sender_key: key, from_address: address}) do
    case Repo.get_by(Sender, account_id: account_id, key: key) do
      %Sender{address: ^address, display_name: name} when is_binary(name) and name != "" ->
        {name, address}

      _ ->
        address
    end
  end

  defp smtp_config(%Account{smtp_host: host}) when host in [nil, ""],
    do: {:error, "smtp_host_not_configured"}

  defp smtp_config(%Account{} = account) do
    with {:ok, password} <- password(account) do
      {:ok, relay_config(account, password)}
    end
  end

  defp password(%Account{smtp_secret_slug: nil}), do: {:ok, nil}

  defp password(%Account{} = account) do
    case Mail.fetch_secret(account, :smtp) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, "smtp_secret_unavailable: #{inspect(reason)}"}
    end
  end

  defp relay_config(%Account{} = account, password) do
    host = account.smtp_host

    base = [
      relay: host,
      port: account.smtp_port || default_port(account.smtp_tls),
      no_mx_lookups: true,
      retries: 0
    ]

    tls =
      case account.smtp_tls do
        "tls" -> [ssl: true, tls: :never, sockopts: tls_options(host)]
        "starttls" -> [ssl: false, tls: :always, tls_options: tls_options(host)]
        _ -> [ssl: false, tls: :never]
      end

    auth =
      if is_binary(account.username) and account.username != "" and is_binary(password) do
        [auth: :always, username: account.username, password: password]
      else
        [auth: :never]
      end

    base ++ tls ++ auth
  end

  defp default_port("tls"), do: 465
  defp default_port("starttls"), do: 587
  defp default_port(_), do: 25

  defp tls_options(host) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      depth: 99,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp record_accepted(%Delivery{} = delivery, receipt) do
    delivery
    |> Delivery.status_changeset(%{
      status: "accepted",
      smtp_response: format_receipt(receipt),
      accepted_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  defp record_failed(%Delivery{} = delivery, error) do
    case delivery
         |> Delivery.status_changeset(%{status: "failed", error: error})
         |> Repo.update() do
      {:ok, failed} -> {:error, {:failed, error, failed}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # `Platform.Mail.SmtpAdapter`, like the `Swoosh.Adapters.SMTP` it wraps,
  # returns `{:ok, receipt}` only when
  # `:gen_smtp_client.send_blocking/2` returned a binary, and gen_smtp 1.3's
  # `try_DATA/4` returns one only from the clause matching `<<"250 ",
  # Receipt/binary>>` on the reply to the end-of-data `.` — every other reply
  # throws. So under that adapter the code WAS 250, and gen_smtp has stripped
  # it: the receipt is the text after "250 " (GreenMail: "OK"). Put it back so
  # the stored response states the code. Any other adapter's receipt (the test
  # adapters) is stored as returned: 250 is proven for gen_smtp only.
  defp format_receipt(receipt) when is_binary(receipt) do
    if smtp_adapter?(), do: "250 " <> String.trim(receipt), else: String.trim(receipt)
  end

  defp format_receipt(receipt), do: inspect(receipt)

  defp smtp_adapter? do
    :platform
    |> Application.get_env(Mailer, [])
    |> Keyword.get(:adapter)
    |> Kernel.in([Swoosh.Adapters.SMTP, Platform.Mail.SmtpAdapter])
  end

  defp format_error(reason), do: describe_error(reason)

  @doc """
  The text recorded on a failed delivery for an adapter error `reason`.

  A server that closes the connection before the message is accepted is
  spelled out instead of shown only as a raw term. gen_smtp reports a
  rejected login this way: after Gmail answers `535 5.7.8 Username and
  Password not accepted` to the first AUTH mechanism it hangs up, the client's
  next mechanism finds the socket closed, and the 535 never reaches us. So a
  closed connection on a correctly paired port and security is, in practice,
  a bad username or app password. The raw term stays at the end for whoever
  debugs it.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error(reason) when is_binary(reason), do: reason

  def describe_error({:retries_exceeded, {:network_failure, host, {:error, :closed}}} = reason) do
    "#{host_text(host)} closed the connection before accepting the message. " <>
      "This usually means the username or password was rejected: check the " <>
      "password (a Gmail app password is 16 letters with no spaces) and that " <>
      "port and security match (465 with TLS, or 587 with STARTTLS). " <>
      "(#{inspect(reason)})"
  end

  def describe_error(reason), do: inspect(reason)

  defp host_text(host) when is_binary(host), do: host
  defp host_text(host) when is_list(host), do: List.to_string(host)
  defp host_text(host), do: inspect(host)
end
