defmodule Platform.InstructionPacks.Download do
  @moduledoc "Bounded HTTPS downloads through the existing feedback broker. No manifest URL is consulted."
  alias Platform.Feedback.GithubPublisher.Broker
  alias Platform.InstructionPacks.Signature
  @limit 1_100_000

  def fetch(pack_id, version, roots, options \\ []) do
    with {:ok, envelope} <- fetch_envelope(pack_id, version, roots, options),
         do: {:ok, envelope["manifest"]}
  end

  def catalog(options \\ []) do
    with {:ok, body} <- request("/instruction-packs", options),
         {:ok, %{"packs" => ids} = data} <- Jason.decode(body),
         true <- Map.keys(data) == ["packs"],
         true <- is_list(ids) and length(ids) <= 100,
         true <- Enum.all?(ids, &slug?/1) and Enum.uniq(ids) == ids do
      {:ok, ids}
    else
      {:error, reason}
      when reason in [:download_failed, :invalid_pack_source, :release_unavailable] ->
        {:error, reason}

      _ ->
        {:error, :invalid_catalog}
    end
  rescue
    _ -> {:error, :invalid_catalog}
  end

  def fetch_latest(pack_id, roots, options \\ []) do
    with true <- slug?(pack_id),
         {:ok, body} <- request("/instruction-packs/" <> pack_id <> "/latest", options),
         {:ok, %{"pack_id" => ^pack_id}} <- Signature.decode(body, roots) do
      Jason.decode(body)
    else
      false -> {:error, :invalid_pack_source}
      {:ok, _} -> {:error, :unexpected_release}
      error -> error
    end
  end

  def fetch_envelope(pack_id, version, roots, options \\ []) do
    with true <- slug?(pack_id) and is_integer(version) and version > 0,
         {:ok, body} <-
           request("/instruction-packs/" <> pack_id <> "/" <> Integer.to_string(version), options) do
      case Signature.decode(body, roots) do
        {:ok, %{"pack_id" => ^pack_id, "version" => ^version}} -> Jason.decode(body)
        {:ok, _} -> {:error, :unexpected_release}
        error -> error
      end
    else
      false -> {:error, :invalid_pack_source}
      error -> error
    end
  end

  defp request(path, options) do
    with {:ok, base} <- Broker.base_url(),
         %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}
         when is_binary(host) <- URI.parse(base) do
      # Only a test adapter may be injected. Security options cannot be overridden.
      opts =
        Keyword.take(options, [:plug]) ++
          [
            url: base <> path,
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
        {:ok, %{status: 200, body: body}} ->
          {:ok, body}

        {:ok, %{status: 404}} ->
          {:error, :release_unavailable}

        _ ->
          {:error, :download_failed}
      end
    else
      _ -> {:error, :invalid_pack_source}
    end
  rescue
    _ -> {:error, :download_failed}
  end

  defp slug?(id), do: is_binary(id) and Regex.match?(~r/\A[a-z0-9][a-z0-9_.-]{0,127}\z/, id)
end
