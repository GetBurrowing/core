defmodule PlatformWeb.AttachmentResponsePolicy do
  @moduledoc """
  The one place that decides how stored user bytes are presented to a browser.

  Task 01a16a08 (stored XSS): chat attachments were served `inline` for every
  `text/*` and `image/*` type with no Content-Security-Policy, so an uploaded
  `text/html` or `image/svg+xml` file ran as same-origin script when opened.
  Uploads deliberately still accept those types (users share `.html` / `.svg`
  as downloads, and the upload path's job is declared == sent integrity), so
  the response headers are the only place the bytes meet a browser. This
  module owns them.

  ## Inline allowlist

  `disposition/1` returns `:inline` ONLY for:

    * `image/*` except `image/svg+xml` (SVG is a script-capable document)
    * `video/*`
    * `audio/*`
    * `application/pdf`

  Everything else is `:attachment`: every `text/*`, `image/svg+xml`,
  `application/xhtml+xml`, `application/octet-stream` and any unknown type.
  The type is normalised first (parameters stripped, trimmed, case-folded),
  so `"TEXT/HTML; charset=utf-8"` cannot slip past a literal match.

  ## Sandbox CSP

  `put_sandbox_csp/2` is the single CSP merge. It APPENDS to an existing
  `content-security-policy` header rather than replacing it, so a browser
  pipeline's `base-uri` / `frame-ancestors` survive, and it refuses to add a
  second `sandbox` directive (browsers ignore a duplicate, which would
  silently change the policy's meaning).
  """

  import Plug.Conn

  @csp_header "content-security-policy"

  # Start of string or `;`, optional whitespace, `sandbox`, then whitespace,
  # `;` or end of string.
  @sandbox_directive ~r/(?:^|;)\s*sandbox(?:\s|;|$)/i

  @doc """
  Returns `:inline` for the allowlisted media types and `:attachment` for
  everything else (including `nil` and non-binary input).
  """
  @spec disposition(term()) :: :inline | :attachment
  def disposition(content_type) when is_binary(content_type) do
    content_type
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
    |> normalised_disposition()
  end

  def disposition(_content_type), do: :attachment

  # ORDER IS LOAD-BEARING: the svg clause must sit above `"image/" <> _`,
  # otherwise SVG (a script-capable document) is served inline.
  defp normalised_disposition("image/svg+xml"), do: :attachment
  defp normalised_disposition("image/" <> _rest), do: :inline
  defp normalised_disposition("video/" <> _rest), do: :inline
  defp normalised_disposition("audio/" <> _rest), do: :inline
  defp normalised_disposition("application/pdf"), do: :inline
  defp normalised_disposition(_content_type), do: :attachment

  @doc """
  Appends `directive` (default `"sandbox;"`) to the response's existing
  Content-Security-Policy. A conn whose CSP already carries a `sandbox`
  directive is returned unchanged.
  """
  @spec put_sandbox_csp(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_sandbox_csp(conn, directive \\ "sandbox;") do
    existing =
      case get_resp_header(conn, @csp_header) do
        [value | _] -> String.trim(value)
        [] -> ""
      end

    if Regex.match?(@sandbox_directive, existing) do
      conn
    else
      merged = String.trim_leading(existing <> " " <> directive)
      put_resp_header(conn, @csp_header, merged)
    end
  end
end
