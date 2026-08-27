defmodule PlatformWeb.PublicSite do
  @moduledoc """
  THE one reader of `:public_site_host` — the public web address this
  deployment offers to external guests.

  Its only caller today is the guest meeting surface: the expired-invite,
  invalid-invite and temporarily-unavailable cards each render a single
  outbound action, and this module decides whether that action exists at all.

  ## Unconfigured means ABSENT, not defaulted

  `core` is a public, open-source repository, so the failure this module
  exists to make impossible is a baked-in default: a hostname compiled into
  the product sends every other deployment's guests — typically a client's
  staff — to a company they have no relationship with. There is therefore no
  `||` fallback anywhere below, and `url/0` returns `nil` rather than a
  guessed host or a malformed `https://`.

  Callers MUST fail closed on `nil`: omit the action from the DOM. An empty
  label or a dead `href` on a page shown to an outside visitor is worse than
  no button, and each card's body copy already carries the action that
  actually helps them (ask whoever invited you).

  This mirrors `Platform.Meetings.GuestInvite.guest_host_configured?/0` and
  `PlatformWeb.ExternalSurface.meet_host_configured?/0`: same two-function
  shape, same "unset, `nil`, `\"\"` and whitespace all mean the same thing"
  rule, same one-reader-per-key discipline. `PUBLIC_SITE_HOST` is exposed as
  `:public_site_host` in `config/runtime.exs`.
  """

  @doc """
  The raw configured public-site host, or `nil` when unset.

  Read with NO default, on purpose — see the moduledoc.
  """
  @spec host() :: String.t() | nil
  def host, do: Application.get_env(:platform, :public_site_host)

  @doc """
  Whether a usable public-site host is configured.

  True only for a binary with non-whitespace content once any scheme is
  stripped. Unset, `nil`, `""`, `"   "` and a bare `"https://"` all return
  false, and every one of them means the same thing: this deployment has no
  public site to offer a guest.
  """
  @spec configured?() :: boolean()
  def configured?, do: display_host() != nil

  @doc """
  The host as it should be READ by a guest, or `nil`.

  Trimmed, and with a leading `http://` / `https://` removed so a value
  configured as a URL renders as `example.test` rather than
  `https://example.test` in the label and never builds `https://https://…`
  in the href. A trailing slash goes too, for the same reason.
  """
  @spec display_host() :: String.t() | nil
  def display_host do
    case host() do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> strip_scheme()
        |> String.trim_trailing("/")
        |> String.trim()
        |> case do
          "" -> nil
          host -> host
        end

      _ ->
        nil
    end
  end

  @doc """
  The absolute `https://` URL for the public site, or `nil` when unconfigured.

  `nil` is the whole contract for the unconfigured case: there is no
  host-relative degradation here as there is in
  `PlatformWeb.ExternalRedirect.chat_url/1`, because a guest error card has
  no useful same-host destination to fall back to.
  """
  @spec url() :: String.t() | nil
  def url do
    case display_host() do
      nil -> nil
      host -> "https://" <> host
    end
  end

  defp strip_scheme("https://" <> rest), do: rest
  defp strip_scheme("http://" <> rest), do: rest
  defp strip_scheme(value), do: value
end
