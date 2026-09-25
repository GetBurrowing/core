defmodule Platform.Federation.Peers.Config do
  @moduledoc """
  Switches for install-to-install federation (task 01a0d90f, ADR 0054).

  ## Fail closed

  Federation is on only when `PEER_FEDERATION_ENABLED` is exactly the string
  `"true"`. Unset, `"1"`, `"TRUE"`, `"yes"` and every other value mean off,
  mirroring `Platform.Mail.Config.enabled?/0`. While it is off,
  `/.well-known/suite-federation` answers 404 and no peer traffic is sent or
  accepted.

  `config :platform, :peer_federation_enabled, <bool>` short-circuits the
  environment read. `config/test.exs` pins it to `false` so the suite does not
  depend on the host's environment; a test that needs federation on flips it
  with `Application.put_env/3` and restores it in `on_exit/1`.

  ## Plain http is a rig affordance, never a prod one

  `allow_http?/0` reads `PEER_FEDERATION_ALLOW_HTTP` (same exact-`"true"`
  rule, same `:peer_federation_allow_http` override) and is honoured ONLY when
  `Application.get_env(:platform, :env) != :prod`. The two-install rig peers
  speak plain http on moon's podman `dev` network; a production install always
  requires https, whatever the variable says.

  ## Advertised base URL

  `base_url/0` is what the descriptor advertises and what peers call back.
  `PEER_FEDERATION_BASE_URL` overrides it (the rig needs the podman
  container hostname, not `localhost`); otherwise it is the endpoint's own
  URL. A trailing slash is stripped.
  """

  @spec enabled?() :: boolean()
  def enabled? do
    flag(:peer_federation_enabled, "PEER_FEDERATION_ENABLED")
  end

  @spec allow_http?() :: boolean()
  def allow_http? do
    Application.get_env(:platform, :env) != :prod and
      flag(:peer_federation_allow_http, "PEER_FEDERATION_ALLOW_HTTP")
  end

  @spec base_url() :: String.t()
  def base_url do
    url =
      case Application.fetch_env(:platform, :peer_federation_base_url) do
        {:ok, url} when is_binary(url) and url != "" ->
          url

        _ ->
          case System.get_env("PEER_FEDERATION_BASE_URL") do
            url when is_binary(url) and url != "" -> url
            _ -> PlatformWeb.Endpoint.url()
          end
      end

    String.trim_trailing(url, "/")
  end

  defp flag(app_key, env_var) do
    case Application.fetch_env(:platform, app_key) do
      {:ok, injected} -> injected == true
      :error -> System.get_env(env_var) == "true"
    end
  end
end
