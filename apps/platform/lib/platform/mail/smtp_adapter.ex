defmodule Platform.Mail.SmtpAdapter do
  @moduledoc """
  The production mail adapter (task 01a1a933 stage 2): `Swoosh.Adapters.SMTP`
  with the message bytes rendered by `Platform.Mail.Mime`, which puts a
  calendar invite's `text/calendar` part inside `multipart/alternative`.

  Everything else is Swoosh's SMTP adapter unchanged: the same envelope
  (From, then To + Cc + Bcc addresses, deduplicated), the same relay
  options through `Swoosh.Adapters.SMTP.gen_smtp_config/1`, the same
  `:gen_smtp_client.send_blocking/2` call and the same return shapes, so
  `Platform.Mail.Deliverer`'s receipt handling is unchanged.
  """
  use Swoosh.Adapter, required_config: [:relay], required_deps: [gen_smtp: :gen_smtp_client]

  alias Platform.Mail.Mime
  alias Swoosh.Email

  @impl true
  def deliver(%Email{} = email, config) do
    sender = Mime.sender(email)
    body = Mime.render(email, config)

    case :gen_smtp_client.send_blocking(
           {sender, recipients(email), body},
           Swoosh.Adapters.SMTP.gen_smtp_config(config)
         ) do
      receipt when is_binary(receipt) -> {:ok, receipt}
      {:error, type, message} -> {:error, {type, message}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recipients(%Email{} = email) do
    [email.to, email.cc, email.bcc]
    |> Enum.concat()
    |> Enum.map(fn {_name, address} -> address end)
    |> Enum.uniq()
  end
end
