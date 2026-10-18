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
  speak plain http on the test rig's podman `dev` network; a production install always
  requires https, whatever the variable says.

  ## Advertised base URL

  `base_url/0` is what the descriptor advertises and what peers call back.
  `PEER_FEDERATION_BASE_URL` overrides it (the rig needs the podman
  container hostname, not `localhost`); otherwise it is the endpoint's own
  URL. A trailing slash is stripped.

  ## Signing protocol (task 01a14ba9 stage 2)

  `signing_protocol/0` is the protocol id this install SIGNS with when the
  recipient supports it. It reads `PEER_FEDERATION_SIGNING_PROTOCOL` with the
  same exact-string rule as the flags above: only the exact string
  `"burrow-federation/2"` selects v2. Unset, `"burrow-federation/2 "`,
  `"BURROW-FEDERATION/2"` and every other value mean `"suite-federation/1"`.
  `config :platform, :peer_federation_signing_protocol, <value>` short-circuits
  the environment read under the same exact-string rule; `config/test.exs`
  pins it to `nil` (v1) so the suite does not depend on the host.

  The variable is a ceiling, not a decision: `Platform.Federation.Peers.Envelope.build/4`
  signs v2 only when this says v2 AND the recipient peer advertised v2. Flip it
  only when `Platform.Federation.Peers.protocol_readiness/0` reports every
  active peer ready (ADR 0054, "Protocol versions").
  """

  @protocol_v1 "suite-federation/1"
  @protocol_v2 "burrow-federation/2"

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

  @spec signing_protocol() :: String.t()
  def signing_protocol do
    value =
      case Application.fetch_env(:platform, :peer_federation_signing_protocol) do
        {:ok, injected} -> injected
        :error -> System.get_env("PEER_FEDERATION_SIGNING_PROTOCOL")
      end

    if value == @protocol_v2, do: @protocol_v2, else: @protocol_v1
  end

  defp flag(app_key, env_var) do
    case Application.fetch_env(:platform, app_key) do
      {:ok, injected} -> injected == true
      :error -> System.get_env(env_var) == "true"
    end
  end
end
