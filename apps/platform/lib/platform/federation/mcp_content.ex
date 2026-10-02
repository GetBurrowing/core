defmodule Platform.Federation.McpContent do
  @moduledoc """
  Opt-in marker that lets a tool handler ask the `/mcp` transport to deliver
  part of its result as an MCP `image` content block instead of base64 text
  (task 01a0fcfa).

  A handler that holds raw image bytes calls `offer_image/3` on its result
  map. When the bytes are an image every major vision provider accepts, the
  result gains a reserved, bytes-free marker key (`marker_key/0`) naming the
  field that carries the base64 and the SNIFFED mime type. The transport
  calls `split/1` to lift that field out into an image block; the WebSocket
  transport calls `strip/1` to drop the marker. In-process callers that
  ignore the marker still see the handler's full map, including the base64
  field, so their size and shape are unchanged apart from the marker.

  ## Eligibility

    * Only results whose declared `content_type` is `image/*` are
      considered. Anything else is returned unchanged, with no keys added.
    * The bytes are sniffed by magic number. The allowlist is PNG, JPEG,
      GIF and WebP — the formats Anthropic, OpenAI and Gemini all accept.
      The sniffed type, never the stored `content_type`, becomes the block's
      `mime_type`: Anthropic rejects a request whose media type disagrees
      with the bytes, and a rejected image fails the agent's whole provider
      turn, which is worse than receiving text.
    * Images larger than `image_block_max_bytes/0` stay text. The default
      3,750,000 raw bytes base64-encodes to exactly 5,000,000 characters,
      under Anthropic's 5 MiB per-image limit whether a provider measures
      raw or encoded length. Configure with
      `config :platform, :mcp_image_block_max_bytes, n`.

  A declared image that is not eligible gets an `image_block_skipped` key
  carrying the reason, so the agent can tell why it received text.
  """

  require Logger

  @marker :__mcp_image__
  @default_max_bytes 3_750_000

  @doc "The reserved result key carrying the image-block marker."
  @spec marker_key() :: atom()
  def marker_key, do: @marker

  @doc """
  Maximum raw image size, in bytes, eligible for an image block. Reads
  `:platform, :mcp_image_block_max_bytes` (default #{@default_max_bytes}).
  """
  @spec image_block_max_bytes() :: pos_integer()
  def image_block_max_bytes do
    Application.get_env(:platform, :mcp_image_block_max_bytes, @default_max_bytes)
  end

  @doc """
  True when `content_type` (case-insensitive, parameters ignored) declares
  an `image/*` type.
  """
  @spec image_content_type?(term()) :: boolean()
  def image_content_type?(content_type) when is_binary(content_type) do
    content_type
    |> normalize_content_type()
    |> String.starts_with?("image/")
  end

  def image_content_type?(_), do: false

  @doc """
  Offer `result[field]` as an MCP image block, given the raw `bytes` it
  encodes. Returns `result` with the marker added (eligible), with
  `image_block_skipped` added (declared image, not eligible), or unchanged
  (declared type is not `image/*`).
  """
  @spec offer_image(map(), atom(), binary()) :: map()
  def offer_image(result, field, bytes)
      when is_map(result) and is_atom(field) and is_binary(bytes) do
    declared = Map.get(result, :content_type)

    if image_content_type?(declared) do
      max = image_block_max_bytes()

      case sniff(bytes) do
        nil ->
          Map.put(
            result,
            :image_block_skipped,
            "declared #{normalize_content_type(declared)} but the bytes are not PNG, JPEG, GIF or WebP; returned as base64 text"
          )

        _mime when byte_size(bytes) > max ->
          Map.put(
            result,
            :image_block_skipped,
            "image is #{byte_size(bytes)} bytes, over the #{max}-byte image block cap; returned as base64 text"
          )

        mime ->
          Map.put(result, @marker, %{field: field, mime_type: mime})
      end
    else
      result
    end
  end

  @doc """
  Sniff the image type from magic bytes. Returns the mime type for PNG,
  JPEG, GIF or WebP, otherwise `nil`.
  """
  @spec sniff(binary()) :: String.t() | nil
  def sniff(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary>>), do: "image/png"
  def sniff(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  def sniff(<<"GIF87a", _::binary>>), do: "image/gif"
  def sniff(<<"GIF89a", _::binary>>), do: "image/gif"
  def sniff(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: "image/webp"
  def sniff(_), do: nil

  @doc """
  Split a handler result for the `/mcp` transport.

  Returns `{:image, rest, base64, mime_type}` when a well-formed marker is
  present (`rest` has both the marker and the base64 field removed), or
  `{:none, data}` with the marker removed otherwise. A malformed marker is
  logged and treated as absent; it never raises.
  """
  @spec split(term()) :: {:image, map(), String.t(), String.t()} | {:none, term()}
  def split(data) when is_map(data) and not is_struct(data) do
    case Map.fetch(data, @marker) do
      :error ->
        {:none, data}

      {:ok, %{field: field, mime_type: mime}}
      when is_atom(field) and is_binary(mime) and is_map_key(data, field) and
             is_binary(:erlang.map_get(field, data)) ->
        rest = Map.drop(data, [@marker, field])
        {:image, rest, Map.fetch!(data, field), mime}

      {:ok, malformed} ->
        Logger.warning(
          "McpContent.split: ignoring malformed #{inspect(@marker)} marker: #{inspect(malformed, limit: 10)}"
        )

        {:none, Map.delete(data, @marker)}
    end
  end

  def split(data), do: {:none, data}

  @doc "Remove the marker from a result (non-maps pass through)."
  @spec strip(term()) :: term()
  def strip(data) when is_map(data) and not is_struct(data), do: Map.delete(data, @marker)
  def strip(data), do: data

  defp normalize_content_type(content_type) do
    content_type
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
  end
end
