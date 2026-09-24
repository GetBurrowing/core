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

  defp build_email(%Delivery{} = delivery) do
    Swoosh.Email.new()
    |> Swoosh.Email.from(from(delivery))
    |> Swoosh.Email.to(delivery.recipients)
    |> Swoosh.Email.subject(delivery.subject || "")
    |> Swoosh.Email.text_body(delivery.body || "")
    |> Swoosh.Email.header("Message-ID", delivery.message_id_header)
  end

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

  # `Swoosh.Adapters.SMTP` returns `{:ok, receipt}` only when
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
    |> Keyword.get(:adapter) == Swoosh.Adapters.SMTP
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
