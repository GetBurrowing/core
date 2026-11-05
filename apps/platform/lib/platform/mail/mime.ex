defmodule Platform.Mail.Mime do
  @moduledoc """
  Renders a `Swoosh.Email` to the RFC 5322 bytes the relay receives (task
  01a1a933 stage 2). `Platform.Mail.SmtpAdapter` sends exactly what this
  returns, and the deliverer tests parse exactly what this returns.

  It is Swoosh's own SMTP rendering (`Swoosh.Adapters.SMTP.Helpers`,
  pinned at swoosh 1.28.1 in mix.lock) with ONE change: a calendar invite's
  `text/calendar` part is moved INSIDE the `multipart/alternative`, next to
  the plain and HTML bodies. Swoosh builds that alternative from
  `text_body` + `html_body` only, so `Platform.Mail.Deliverer` hands the
  calendar part over as an attachment entry and this module moves it.
  Outlook shows its Accept/Decline bar for a `text/calendar; method=...`
  alternative; Gmail and Apple Mail accept either placement.

  A message with a calendar invite comes out as:

      multipart/mixed
      ├── multipart/alternative
      │   ├── text/plain; charset=utf-8
      │   ├── text/html; charset=utf-8          (when html_body is set)
      │   └── text/calendar; charset=UTF-8; method=REQUEST|CANCEL
      └── application/ics; invite.ics           (attachment, same bytes)

  Every other message renders byte-for-byte as Swoosh would render it.
  """

  alias Swoosh.Adapters.SMTP.Helpers

  @doc "The message `email` as the bytes handed to gen_smtp."
  @spec render(Swoosh.Email.t(), keyword()) :: binary()
  def render(%Swoosh.Email{} = email, config \\ []) do
    {message_config, config} = Keyword.split(config, [:transfer_encoding, :keep_bcc])
    {encoding_config, _config} = Keyword.split(config, [:dkim])

    {type, subtype, headers, parts} =
      email
      |> Helpers.prepare_message(message_config)
      |> calendar_into_alternative()

    :mimemail.encode({type, subtype, headers, %{}, parts}, encoding_config)
  end

  @doc "The SMTP envelope sender of `email` (as `Swoosh.Adapters.SMTP`)."
  @spec sender(Swoosh.Email.t()) :: String.t()
  def sender(%Swoosh.Email{} = email), do: Helpers.sender(email)

  defp calendar_into_alternative({"multipart", "mixed", headers, [content | attachments]} = msg) do
    case Enum.split_with(attachments, &calendar_part?/1) do
      {[calendar], rest} ->
        {"multipart", "mixed", headers,
         [alternative(content, calendar_alternative(calendar)) | rest]}

      _ ->
        msg
    end
  end

  defp calendar_into_alternative(message), do: message

  defp calendar_part?({"text", "calendar", _headers, _params, _content}), do: true
  defp calendar_part?(_part), do: false

  # The attachment entry's own Content-Type header carries `method=`; the
  # attachment disposition and filename are dropped, because an alternative
  # is a rendering of the message, not a file.
  defp calendar_alternative({"text", "calendar", headers, _params, content}) do
    content_type =
      Enum.find_value(headers, "text/calendar; charset=UTF-8", fn {name, value} ->
        if String.downcase(name) == "content-type", do: value
      end)

    {"text", "calendar",
     [{"Content-Type", content_type}, {"Content-Transfer-Encoding", "base64"}],
     %{content_type_params: [], disposition: "inline", disposition_params: []}, content}
  end

  defp alternative({"multipart", "alternative", headers, params, parts}, calendar),
    do: {"multipart", "alternative", headers, params, parts ++ [calendar]}

  defp alternative(single_part, calendar),
    do: {"multipart", "alternative", [], %{}, [single_part, calendar]}
end
