defmodule Platform.Vault.OAuthTest do
  use Platform.DataCase

  alias Platform.Vault
  alias Platform.Vault.OAuth

  # ---------------------------------------------------------------------------
  # Test setup — runs before every test.
  #
  # 1. Register a Req.Test stub that returns a valid token response.
  # 2. Inject the stub-backed Req client so OAuth module never makes real HTTP.
  # 3. Store fake client credentials in Vault so authorize_url / exchange work.
  # ---------------------------------------------------------------------------

  setup do
    # Stub: returns a successful token payload for every POST.
    Req.Test.stub(:platform_oauth_test, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "test-access-token",
        "refresh_token" => "test-refresh-token",
        "expires_at" => nil,
        "token_type" => "Bearer",
        "scope" => "read write"
      })
    end)

    test_req = Req.new(plug: {Req.Test, :platform_oauth_test})
    Application.put_env(:platform, :oauth_req_client, test_req)
    on_exit(fn -> Application.delete_env(:platform, :oauth_req_client) end)

    # Store client credentials so Vault.get("anthropic-oauth-client") succeeds.
    {:ok, _} =
      Vault.put(
        "anthropic-oauth-client",
        :api_key,
        Jason.encode!(%{"client_id" => "test-client-id", "client_secret" => "test-secret"}),
        scope: {:platform, nil}
      )

    :ok
  end

  # ---------------------------------------------------------------------------
  # provider_config/1
  # ---------------------------------------------------------------------------

  describe "provider_config/1" do
    test "returns config for anthropic" do
      assert {:ok, config} = OAuth.provider_config("anthropic")
      assert config.authorize_url =~ "anthropic"
      assert is_list(config.scopes)
      assert is_binary(config.token_url)
    end

    test "returns config for openai" do
      assert {:ok, config} = OAuth.provider_config("openai")
      assert config.authorize_url =~ "openai"
      assert is_list(config.scopes)
    end

    test "returns error for unknown provider" do
      assert {:error, :unknown_provider} = OAuth.provider_config("unknown-provider")
    end
  end

  # ---------------------------------------------------------------------------
  # authorize_url/2
  # ---------------------------------------------------------------------------

  describe "authorize_url/2" do
    test "returns a valid URL with PKCE params" do
      assert {:ok, url, state} =
               OAuth.authorize_url("anthropic", callback_uri: "https://example.com/callback")

      assert is_binary(url)
      assert is_binary(state)
      assert String.starts_with?(url, "https://")

      uri = URI.parse(url)
      params = URI.decode_query(uri.query)

      assert params["code_challenge"] != nil,
             "code_challenge must be present in the authorization URL"

      assert params["code_challenge_method"] == "S256"
      assert params["state"] == state
      assert params["response_type"] == "code"
      assert params["client_id"] == "test-client-id"
    end

    test "uses the provided state value" do
      custom_state = "my-custom-csrf-state"

      assert {:ok, url, ^custom_state} =
               OAuth.authorize_url("anthropic",
                 callback_uri: "https://example.com/cb",
                 state: custom_state
               )

      uri = URI.parse(url)
      params = URI.decode_query(uri.query)
      assert params["state"] == custom_state
    end

    test "uses custom scopes when provided" do
      assert {:ok, url, _state} =
               OAuth.authorize_url("anthropic",
                 callback_uri: "https://example.com/cb",
                 scopes: ["custom:scope"]
               )

      params = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert params["scope"] == "custom:scope"
    end

    test "returns error for unknown provider" do
      assert {:error, :unknown_provider} =
               OAuth.authorize_url("no-such-provider", callback_uri: "https://example.com/cb")
    end

    test "different calls produce different code challenges (PKCE is randomized)" do
      {:ok, url1, _} = OAuth.authorize_url("anthropic", callback_uri: "https://example.com/cb")
      {:ok, url2, _} = OAuth.authorize_url("anthropic", callback_uri: "https://example.com/cb")

      p1 = url1 |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      p2 = url2 |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      refute p1["code_challenge"] == p2["code_challenge"],
             "PKCE code_challenge must be unique per request"
    end
  end

  # ---------------------------------------------------------------------------
  # handle_callback/2
  # ---------------------------------------------------------------------------

  describe "handle_callback/2" do
    test "exchanges a valid code and stores encrypted tokens in Vault" do
      {:ok, _url, state} =
        OAuth.authorize_url("anthropic", callback_uri: "https://example.com/cb")

      assert {:ok, credential} =
               OAuth.handle_callback("anthropic", %{"code" => "auth-code-abc", "state" => state})

      assert credential.slug == "anthropic-oauth"
      assert credential.credential_type == "oauth2"
      assert credential.provider == "anthropic"

      # Verify the tokens are actually stored and decryptable.
      assert {:ok, raw} = Vault.get("anthropic-oauth")
      assert {:ok, tokens} = Jason.decode(raw)
      assert tokens["access_token"] == "test-access-token"
      assert tokens["refresh_token"] == "test-refresh-token"
    end

    test "accepts atom-keyed params" do
      {:ok, _url, state} =
        OAuth.authorize_url("anthropic", callback_uri: "https://example.com/cb")

      assert {:ok, credential} =
               OAuth.handle_callback("anthropic", %{code: "auth-code-xyz", state: state})

      assert credential.slug == "anthropic-oauth"
    end

    test "returns error when state does not match" do
      assert {:error, :state_mismatch} =
               OAuth.handle_callback("anthropic", %{
                 "code" => "some-code",
                 "state" => "completely-wrong-state"
               })
    end

    test "consumes the state entry (replay prevention)" do
      {:ok, _url, state} =
        OAuth.authorize_url("anthropic", callback_uri: "https://example.com/cb")

      # First call succeeds.
      assert {:ok, _} =
               OAuth.handle_callback("anthropic", %{"code" => "code-1", "state" => state})

      # Second call with the same state must fail.
      assert {:error, :state_mismatch} =
               OAuth.handle_callback("anthropic", %{"code" => "code-2", "state" => state})
    end

    test "emits credential_created telemetry" do
      {:ok, _url, state} =
        OAuth.authorize_url("anthropic", callback_uri: "https://example.com/cb")

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:platform, :vault, :credential_created]])

      assert {:ok, _cred} =
               OAuth.handle_callback("anthropic", %{"code" => "code-tel", "state" => state})

      assert_receive {[:platform, :vault, :credential_created], ^ref, _measurements, meta}
      assert meta.slug == "anthropic-oauth"

      :telemetry.detach(ref)
    end
  end

  # ---------------------------------------------------------------------------
  # refresh/1
  # ---------------------------------------------------------------------------

  describe "refresh/1" do
    setup do
      # Store an existing oauth credential for the refresh tests.
      existing_tokens =
        Jason.encode!(%{
          "access_token" => "old-access-token",
          "refresh_token" => "old-refresh-token",
          "expires_at" => nil,
          "token_type" => "Bearer",
          "scope" => "read write",
          "provider" => "anthropic"
        })

      {:ok, _} =
        Vault.put("anthropic-oauth", :oauth2, existing_tokens,
          provider: "anthropic",
          scope: {:platform, nil}
        )

      :ok
    end

    test "refreshes and updates the stored tokens" do
      assert {:ok, credential} = OAuth.refresh("anthropic-oauth")
      assert credential.slug == "anthropic-oauth"

      # Verify new tokens are stored.
      assert {:ok, raw} = Vault.get("anthropic-oauth")
      assert {:ok, tokens} = Jason.decode(raw)
      assert tokens["access_token"] == "test-access-token"
    end

    test "accepts a credential struct (or any map with :slug)" do
      fake_cred = %{slug: "anthropic-oauth"}
      assert {:ok, credential} = OAuth.refresh(fake_cred)
      assert credential.slug == "anthropic-oauth"
    end

    test "emits oauth_refreshed telemetry on success" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:platform, :vault, :oauth_refreshed]])

      assert {:ok, _} = OAuth.refresh("anthropic-oauth")

      assert_receive {[:platform, :vault, :oauth_refreshed], ^ref, _measurements, meta}
      assert meta.slug == "anthropic-oauth"

      :telemetry.detach(ref)
    end

    test "emits oauth_refresh_failed telemetry on failure" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :vault, :oauth_refresh_failed]
        ])

      assert {:error, _} = OAuth.refresh("nonexistent-oauth")

      assert_receive {[:platform, :vault, :oauth_refresh_failed], ^ref, _measurements, meta}
      assert meta.slug == "nonexistent-oauth"

      :telemetry.detach(ref)
    end

    test "returns error for unknown slug" do
      assert {:error, :not_found} = OAuth.refresh("missing-oauth")
    end
  end
end
