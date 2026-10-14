defmodule Platform.SignInAdmin.Config do
  @moduledoc """
  Switch and connection settings for the native sign-in users page, which
  manages the install's bundled pocket-id users from Suite (task
  01a113ea-3ef4-7001-b3fc-5d0a1bafc5df).

  Every value is read at call time, never in a module attribute, so an
  operator who changes the environment and restarts gets the new value and a
  test can flip it inside a single test.

  ## Environment

    * `POCKET_ID_ADMIN_ENABLED`: the master switch. On only when it is exactly
      the string `"true"`. Unset, `"1"`, `"TRUE"`, `"yes"` and every other
      value mean off, mirroring `Platform.Mail.Config.enabled?/0`.
    * `POCKET_ID_ADMIN_URL`: the server-to-server base URL of pocket-id (the
      installer sets `http://pocket-id:1411`, the compose service Caddy
      proxies to). A trailing slash is stripped.
    * `POCKET_ID_API_KEY`: the install's pocket-id `STATIC_API_KEY`, an
      admin-grade credential. It is only ever returned wrapped in a
      `Platform.SignInAdmin.Config.Key`, whose `Inspect` output is
      `#SignInAdmin.Key<redacted>`.

  ## Fail closed

  `enabled?/0` is true only when the switch is on AND the URL and the key are
  both present and non-blank. A URL and key set for other tooling never expose
  an admin surface on their own, and an operator can turn the page off without
  deleting the key.

  ## Injection

  `config :platform, :sign_in_admin_enabled, <bool>` short-circuits the read
  of the switch (not of the URL or key), the way `:mail_enabled` does.
  `config/test.exs` pins it to `false` so the suite is not a function of the
  host's environment. `:sign_in_admin_url` and `:sign_in_admin_api_key`, when
  set, replace the URL and key reads, so a test can point the client at a
  `Req.Test` stub without touching the OS environment. Tests that set any of
  these restore them in `on_exit/1`.

  Nothing here reads or writes the orgs table: orgs are clients, not
  deployments, so per-install settings come from the environment only.
  """

  defmodule Key do
    @moduledoc """
    The pocket-id API key, wrapped so that `inspect/1` (crash reports, socket
    assigns, `IO.inspect` while debugging) never prints it. Read the value with
    `key.value` at the one place a request header is built.
    """
    @enforce_keys [:value]
    defstruct [:value]

    @type t :: %__MODULE__{value: String.t()}

    defimpl Inspect do
      def inspect(_key, _opts), do: "#SignInAdmin.Key<redacted>"
    end
  end

  @spec enabled?() :: boolean()
  def enabled? do
    switch_on?() and present?(url()) and present?(raw_key())
  end

  @doc "The pocket-id base URL with any trailing slash removed, or nil."
  @spec url() :: String.t() | nil
  def url do
    case read(:sign_in_admin_url, "POCKET_ID_ADMIN_URL") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> String.trim_trailing(trimmed, "/")
        end

      _ ->
        nil
    end
  end

  @doc "The pocket-id API key wrapped in a redacting struct, or nil when unset or blank."
  @spec api_key() :: Key.t() | nil
  def api_key do
    case raw_key() do
      value when is_binary(value) ->
        if present?(value), do: %Key{value: value}, else: nil

      _ ->
        nil
    end
  end

  @doc """
  The browser-facing base of pocket-id: the OIDC issuer (pocket-id's
  `APP_URL`). Sign-in links are built on it as `<public_base>/lc/<code>`.
  """
  @spec public_base() :: String.t()
  def public_base, do: Platform.OIDC.issuer()

  defp switch_on? do
    case Application.fetch_env(:platform, :sign_in_admin_enabled) do
      {:ok, injected} -> injected == true
      :error -> System.get_env("POCKET_ID_ADMIN_ENABLED") == "true"
    end
  end

  defp raw_key, do: read(:sign_in_admin_api_key, "POCKET_ID_API_KEY")

  defp read(app_key, env_var) do
    case Application.fetch_env(:platform, app_key) do
      {:ok, injected} -> injected
      :error -> System.get_env(env_var)
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
