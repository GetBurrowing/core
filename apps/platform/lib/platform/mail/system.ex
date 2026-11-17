defmodule Platform.Mail.System do
  @moduledoc """
  The install-wide transactional sender: the install speaking as itself, for
  invites and (later) sign-in mail.

  It exists apart from agent mail accounts (`Platform.Mail.Account`) because
  the two answer different questions. An agent account is a per-agent
  identity that people configure: its own address, relay and Vault secret,
  its own sent folder and receipts. A sign-in or invite email has no agent
  behind it; it must come from one stable address the operator chose at
  install time, and it must not depend on any agent having mail set up.

  It is OFF until configured. `configured?/0` is false while
  `SYSTEM_SMTP_HOST` is unset, and `deliver/4` then returns
  `{:error, :not_configured}` and sends nothing, so callers can offer a
  manual fallback (the invite link slip) on an install without a relay.

  Configuration is read in `config/runtime.exs` from `SYSTEM_MAIL_FROM`,
  `SYSTEM_SMTP_HOST`, `SYSTEM_SMTP_PORT`, `SYSTEM_SMTP_USERNAME`,
  `SYSTEM_SMTP_PASSWORD` and `SYSTEM_SMTP_TLS` (`tls`, `starttls` or `none`,
  the same vocabulary as an account's `smtp_tls`; default `starttls`) into
  `config :platform, Platform.Mail.System`.

  No second adapter: the message goes through `Platform.Mail.Mailer` with
  the relay settings passed as `deliver/2` overrides, exactly as
  `Platform.Mail.Deliverer` does for an account. Unlike the Deliverer this
  writes no `Platform.Mail.Delivery` row: there is no mailbox to file it in.

  `deliver/4` never raises: it returns `{:ok, receipt}` or `{:error, reason}`
  and logs the failure (reason only, never the recipient or the body).
  """
  require Logger

  alias Platform.Mail.Mailer
  alias Swoosh.Email

  @type result :: {:ok, term()} | {:error, term()}

  @doc "True when an install-wide SMTP relay is configured."
  @spec configured?() :: boolean()
  def configured?, do: present?(config(:host))

  @doc """
  Send one email from the install. `html_body` may be nil for a plain-text
  message.
  """
  @spec deliver(String.t(), String.t(), String.t(), String.t() | nil) :: result()
  def deliver(to, subject, text_body, html_body) do
    cond do
      not configured?() ->
        {:error, :not_configured}

      not present?(config(:from)) ->
        Logger.warning("mail.system.deliver_failed reason=no_from")
        {:error, :no_from}

      true ->
        send_mail(to, subject, text_body, html_body)
    end
  rescue
    exception ->
      Logger.warning("mail.system.deliver_failed reason=raised #{inspect(exception.__struct__)}")
      {:error, {:raised, Exception.message(exception)}}
  catch
    kind, reason ->
      Logger.warning("mail.system.deliver_failed reason=#{kind}")
      {:error, {kind, reason}}
  end

  defp send_mail(to, subject, text_body, html_body) do
    email =
      Email.new()
      |> Email.from(parse_from(config(:from)))
      |> Email.to(to)
      |> Email.subject(subject)
      |> Email.text_body(text_body)
      |> maybe_html(html_body)

    case Mailer.deliver(email, relay_config()) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        Logger.warning("mail.system.deliver_failed reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp maybe_html(email, html) when is_binary(html) and html != "",
    do: Email.html_body(email, html)

  defp maybe_html(email, _), do: email

  # "Burrow <noreply@x>" -> {"Burrow", "noreply@x"}; a bare address stays bare.
  defp parse_from(from) do
    case Regex.run(~r/^\s*"?([^"<]*?)"?\s*<([^>]+)>\s*$/, from) do
      [_, "", address] -> String.trim(address)
      [_, name, address] -> {name, String.trim(address)}
      _ -> String.trim(from)
    end
  end

  # Same shape as `Platform.Mail.Deliverer.relay_config/2`.
  defp relay_config do
    host = config(:host)
    tls = tls_mode()

    base = [
      relay: host,
      port: port(tls),
      no_mx_lookups: true,
      retries: 0
    ]

    tls_opts =
      case tls do
        "tls" -> [ssl: true, tls: :never, sockopts: tls_options(host)]
        "starttls" -> [ssl: false, tls: :always, tls_options: tls_options(host)]
        _ -> [ssl: false, tls: :never]
      end

    username = config(:username)
    password = config(:password)

    auth =
      if present?(username) and is_binary(password) do
        [auth: :always, username: username, password: password]
      else
        [auth: :never]
      end

    base ++ tls_opts ++ auth
  end

  defp tls_mode do
    case config(:tls) do
      mode when mode in ["tls", "starttls", "none"] -> mode
      _ -> "starttls"
    end
  end

  defp port(tls) do
    case config(:port) do
      port when is_integer(port) -> port
      _ -> default_port(tls)
    end
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

  defp config(key), do: :platform |> Application.get_env(__MODULE__, []) |> Keyword.get(key)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
