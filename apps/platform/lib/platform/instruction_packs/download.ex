defmodule Platform.InstructionPacks.Download do
  @moduledoc "Bounded HTTPS downloads through the existing feedback broker. No manifest URL is consulted."
  alias Platform.Feedback.GithubPublisher.Broker
  alias Platform.InstructionPacks.Signature
  @limit 1_100_000

  def fetch(pack_id, version, roots, options \\ []) do
    with true <- is_binary(pack_id) and Regex.match?(~r/\A[a-z0-9][a-z0-9_.-]{0,127}\z/, pack_id),
         true <- is_integer(version) and version > 0,
         {:ok, base} <- Broker.base_url(),
         %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}
         when is_binary(host) <- URI.parse(base) do
      # Only a test adapter may be injected. Security options cannot be overridden.
      opts =
        Keyword.take(options, [:plug]) ++
          [
            url: base <> "/instruction-packs/" <> pack_id <> "/" <> Integer.to_string(version),
            redirect: false,
            retry: false,
            decode_body: false,
            compressed: false,
            receive_timeout: 10_000,
            connect_options: [timeout: 5_000],
            into: fn {:data, data}, {req, resp} ->
              body = (resp.body || "") <> data

              if byte_size(body) <= @limit do
                {:cont, {req, %{resp | body: body}}}
              else
                {:halt, {req, %Req.TransportError{reason: :pack_too_large}}}
              end
            end
          ]

      case Req.get(opts) do
        {:ok, %{status: 200, body: body}} -> Signature.decode(body, roots)
        _ -> {:error, :download_failed}
      end
    else
      _ -> {:error, :invalid_pack_source}
    end
  rescue
    _ -> {:error, :download_failed}
  end
end
