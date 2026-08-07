defmodule PlatformWeb.Plugs.RawBodyPaths do
  @moduledoc """
  `Plug.Parsers` that steps aside for routes which must read the raw body
  themselves.

  The presigned attachment upload (`POST /chat/attachments/upload/:token`,
  ADR 0039) streams request bytes straight to the storage adapter. It cannot
  do that if `Plug.Parsers` has already consumed the body — and `Plug.Parsers`
  consumes anything it recognises, which includes `application/json`.

  The consequence was silent and content-type dependent: a PNG upload stored
  its bytes (no parser claims `image/png`, so the body survived to the
  controller) while a JSON upload of the same shape finalized at **zero
  bytes**, because the parser had drained it. Nothing errored. The attachment
  row went `ready`, the canvas rendered a link, and the file behind it was
  empty. Found in task 019fcfcf stage 5, where the `.excalidraw` scene file —
  the artefact that makes an exported whiteboard reopenable — was the JSON.

  `PlatformWeb.Router` has claimed since ADR 0039 that "body parsers are
  bypassed via the endpoint's body-reader skip-list". There was no skip-list.
  This module is it.

  Deliberately a path prefix match on `path_info`, not a content-type check:
  the property we want is "this ROUTE owns its body", which must hold for
  every content type a client might send, including ones no parser claims
  today.
  """

  @behaviour Plug

  # Route prefixes whose controllers read the raw body themselves.
  @raw_body_prefixes [
    ["chat", "attachments", "upload"]
  ]

  @impl true
  def init(opts), do: Plug.Parsers.init(opts)

  @impl true
  def call(conn, opts) do
    if raw_body_route?(conn.path_info) do
      conn
    else
      Plug.Parsers.call(conn, opts)
    end
  end

  defp raw_body_route?(path_info) do
    Enum.any?(@raw_body_prefixes, fn prefix ->
      Enum.take(path_info, length(prefix)) == prefix
    end)
  end
end
