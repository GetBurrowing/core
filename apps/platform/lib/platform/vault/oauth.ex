defmodule Platform.Vault.OAuth do
  @moduledoc """
  OAuth2 flow management for Vault credentials.

  Handles authorization URL generation with PKCE, callback token exchange,
  and encrypted token storage in Platform.Vault.

  ## Provider Support

  Providers are configured via `@providers`. Add new providers by expanding
  the map — no code changes are required elsewhere.

  ## PKCE

  All authorization requests use PKCE (RFC 7636) with S256 code challenge
  method. The `{state, code_verifier}` pair is held in a named ETS table
  (`:vault_oauth_states`) and consumed on the first matching callback.

  ## HTTP

  Token exchange and refresh are performed via `Req`. In tests you can
  inject a custom client with `Req.Test` by setting:

      Application.put_env(:platform, :oauth_req_client, Req.new(plug: {Req.Test, :my_stub}))
  """

  alias Platform.Vault

  @ets_table :vault_oauth_states

  @providers %{
    "anthropic" => %{
      authorize_url: "https://console.anthropic.com/oauth/authorize",
      token_url: "https://console.anthropic.com/oauth/token",
      scopes: ["read", "write"]
    },
    "openai" => %{
      authorize_url: "https://auth.openai.com/authorize",
      token_url: "https://auth.openai.com/token",
      scopes: ["model.read", "model.request"]
    }
  }

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc """
  Generate an OAuth2 authorization URL with PKCE for the given provider.

  Client credentials (`client_id` and `client_secret`) are loaded from Vault
  using the slug `"{provider}-oauth-client"` (expected to be a JSON-encoded
  map with `"client_id"` and `"client_secret"` keys).

  The `{state, code_verifier}` pair is stored in ETS for validation during
  the callback.

  ## Options

    * `:callback_uri` — **(required)** the redirect URI registered with the provider
    * `:scopes`       — list of scope strings; defaults to provider's default scopes
    * `:state`        — CSRF state token; auto-generated (URL-safe base64) if omitted

  ## Returns

    * `{:ok, authorize_url, state}` — URL to redirect the user to
    * `{:error, reason}` — lookup or encoding failure
  """
  @spec authorize_url(String.t(), keyword()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def authorize_url(provider, opts \\ []) do
    with {:ok, config} <- provider_config(provider),
         {:ok, client_json} <- Vault.get("#{provider}-oauth-client"),
         {:ok, %{"client_id" => client_id, "client_secret" => client_secret}} <-
           Jason.decode(client_json) do
      callback_uri = Keyword.fetch!(opts, :callback_uri)
      state = Keyword.get(opts, :state, generate_state())
      scopes = Keyword.get(opts, :scopes, config.scopes)

      code_verifier = generate_code_verifier()
      code_challenge = generate_code_challenge(code_verifier)

      ensure_table()
      :ets.insert(@ets_table, {state, code_verifier})

      client =
        OAuth2.Client.new(
          strategy: OAuth2.Strategy.AuthCode,
          client_id: client_id,
          client_secret: client_secret,
          redirect_uri: callback_uri,
          site: extract_site(config.authorize_url),
          authorize_url: config.authorize_url,
          token_url: config.token_url
        )

      url =
        OAuth2.Client.authorize_url!(client,
          state: state,
          scope: Enum.join(scopes, " "),
          code_challenge: code_challenge,
          code_challenge_method: "S256"
        )

      {:ok, url, state}
    end
  end

  @doc """
  Handle the OAuth2 callback by exchanging the authorization code for tokens
  and storing them encrypted in Vault.

  Validates the `state` parameter against the stored PKCE `code_verifier`.
  On success the tokens are persisted as an `oauth2` credential with slug
  `"{provider}-oauth"`.

  ## Params map (string or atom keys)

    * `:code`  — the authorization code received from the provider
    * `:state` — the CSRF state token to validate

  ## Returns

    * `{:ok, credential}` — metadata for the newly created vault credential
    * `{:error, :state_mismatch}` — state not found or does not match
    * `{:error, reason}` — token exchange or storage failure
  """
  @spec handle_callback(String.t(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def handle_callback(provider, params) do
    code = params[:code] || params["code"]
    state = params[:state] || params["state"]

    ensure_table()

    case :ets.lookup(@ets_table, state) do
      [{^state, code_verifier}] ->
        :ets.delete(@ets_table, state)
        exchange_and_store(provider, code, code_verifier)

      _ ->
        {:error, :state_mismatch}
    end
  end

  @doc """
  Refresh the OAuth2 access token for an existing vault credential.

  Accepts either a slug string or any map/struct with a `:slug` key
  (e.g. a `Platform.Vault.Credential`). The stored JSON payload is decoded,
  the `refresh_token` is used to obtain new tokens, and the credential is
  atomically rotated via `Vault.rotate/3`.

  ## Telemetry

    * `[:platform, :vault, :oauth_refreshed]` — on success
    * `[:platform, :vault, :oauth_refresh_failed]` — on any failure

  ## Returns

    * `{:ok, credential}` — updated credential metadata
    * `{:error, reason}` — refresh or rotation failure
  """
  @spec refresh(String.t() | map()) ::
          {:ok, map()} | {:error, term()}
  def refresh(%{slug: slug}), do: refresh(slug)

  def refresh(slug) when is_binary(slug) do
    result =
      with {:ok, raw} <- Vault.get(slug),
           {:ok, tokens} <- Jason.decode(raw),
           provider <- tokens["provider"] || provider_from_slug(slug),
           {:ok, config} <- provider_config(provider),
           {:ok, client_json} <- Vault.get("#{provider}-oauth-client"),
           {:ok, %{"client_id" => client_id, "client_secret" => client_secret}} <-
             Jason.decode(client_json),
           {:ok, new_tokens} <-
             do_refresh(config.token_url, client_id, client_secret, tokens["refresh_token"]) do
        updated_payload = Jason.encode!(Map.merge(tokens, new_tokens))

        Vault.rotate(slug, updated_payload)
      end

    case result do
      {:ok, credential} ->
        :telemetry.execute(
          [:platform, :vault, :oauth_refreshed],
          %{system_time: System.system_time()},
          %{slug: slug}
        )

        {:ok, credential}

      {:error, reason} ->
        :telemetry.execute(
          [:platform, :vault, :oauth_refresh_failed],
          %{system_time: System.system_time()},
          %{slug: slug, reason: inspect(reason)}
        )

        {:error, reason}
    end
  end

  @doc """
  Return the OAuth config map for a known provider.

  ## Returns

    * `{:ok, config}` — map with `:authorize_url`, `:token_url`, `:scopes`
    * `{:error, :unknown_provider}`
  """
  @spec provider_config(String.t()) :: {:ok, map()} | {:error, :unknown_provider}
  def provider_config(provider) do
    case Map.get(@providers, provider) do
      nil -> {:error, :unknown_provider}
      config -> {:ok, config}
    end
  end

  # ── Private: PKCE ─────────────────────────────────────────────────────────────

  defp generate_code_verifier do
    :crypto.strong_rand_bytes(64)
    |> Base.url_encode64(padding: false)
  end

  defp generate_code_challenge(code_verifier) do
    :crypto.hash(:sha256, code_verifier)
    |> Base.url_encode64(padding: false)
  end

  defp generate_state do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
  end

  # ── Private: Token Exchange ───────────────────────────────────────────────────

  defp exchange_and_store(provider, code, code_verifier) do
    with {:ok, config} <- provider_config(provider),
         {:ok, client_json} <- Vault.get("#{provider}-oauth-client"),
         {:ok, %{"client_id" => client_id, "client_secret" => client_secret}} <-
           Jason.decode(client_json),
         {:ok, tokens} <-
           do_token_exchange(config.token_url, client_id, client_secret, code, code_verifier) do
      payload =
        Jason.encode!(%{
          access_token: tokens["access_token"],
          refresh_token: tokens["refresh_token"],
          expires_at: tokens["expires_at"],
          token_type: tokens["token_type"],
          scope: tokens["scope"],
          provider: provider
        })

      slug = "#{provider}-oauth"

      case Vault.put(slug, :oauth2, payload, provider: provider, scope: {:platform, nil}) do
        {:ok, credential} ->
          :telemetry.execute(
            [:platform, :vault, :credential_created],
            %{system_time: System.system_time()},
            %{slug: slug, provider: provider}
          )

          {:ok, credential}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_token_exchange(token_url, client_id, client_secret, code, code_verifier) do
    req_client()
    |> Req.post(
      url: token_url,
      form: [
        grant_type: "authorization_code",
        code: code,
        code_verifier: code_verifier,
        client_id: client_id,
        client_secret: client_secret
      ]
    )
    |> handle_token_response()
  end

  defp do_refresh(token_url, client_id, client_secret, refresh_token) do
    req_client()
    |> Req.post(
      url: token_url,
      form: [
        grant_type: "refresh_token",
        refresh_token: refresh_token,
        client_id: client_id,
        client_secret: client_secret
      ]
    )
    |> handle_token_response()
  end

  defp handle_token_response({:ok, %{status: 200, body: body}}) when is_map(body),
    do: {:ok, body}

  defp handle_token_response({:ok, %{status: status, body: body}}),
    do: {:error, {:http_error, status, body}}

  defp handle_token_response({:error, reason}),
    do: {:error, reason}

  defp req_client do
    Application.get_env(
      :platform,
      :oauth_req_client,
      Req.new(headers: [accept: "application/json"])
    )
  end

  # ── Private: ETS ──────────────────────────────────────────────────────────────

  defp ensure_table do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:set, :public, :named_table])
    end

    @ets_table
  end

  # ── Private: Helpers ──────────────────────────────────────────────────────────

  # Extract the scheme+host from an absolute URL.
  # Used as the OAuth2.Client `:site` when authorize_url is absolute.
  defp extract_site(url) do
    uri = URI.parse(url)
    "#{uri.scheme}://#{uri.host}"
  end

  # Infer provider name from slug by stripping the "-oauth" suffix.
  # Convention: "{provider}-oauth" (e.g. "anthropic-oauth" → "anthropic").
  defp provider_from_slug(slug) do
    case String.split(slug, "-oauth", parts: 2) do
      [provider, _] -> provider
      _ -> slug |> String.split("-") |> List.first()
    end
  end
end
