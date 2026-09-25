defmodule Platform.OIDCTest do
  @moduledoc """
  rbac-external-users M2 stage 1: the OIDC external-marker claim readers.
  `external_claim?/1` is the pure predicate `normalize_oidc_user/1` delegates
  to, so exercising it here covers the claim-shape matrix the plan pins.
  """
  use ExUnit.Case, async: true

  alias Platform.OIDC

  describe "authorize_url/0 scope" do
    test "requests the `groups` scope so Pocket-ID releases the external-user claim" do
      {:ok, %{url: url}} = OIDC.authorize_url()

      scope =
        url
        |> URI.parse()
        |> Map.get(:query)
        |> URI.decode_query()
        |> Map.get("scope")

      assert scope
      assert scope =~ "groups"
      # The full default scope is threaded through unchanged.
      assert scope == "openid email profile groups"
    end

    test "an OIDC_SCOPE override (config :scope) replaces the default" do
      original = Application.get_env(:platform, :oidc, [])

      try do
        Application.put_env(
          :platform,
          :oidc,
          Keyword.put(original, :scope, "openid email profile groups roles")
        )

        {:ok, %{url: url}} = OIDC.authorize_url()

        scope =
          url
          |> URI.parse()
          |> Map.get(:query)
          |> URI.decode_query()
          |> Map.get("scope")

        assert scope == "openid email profile groups roles"
      after
        Application.put_env(:platform, :oidc, original)
      end
    end
  end

  describe "external_group/0 + external_claim/0" do
    test "read the configured marker value and claim name (test defaults)" do
      # config/config.exs base defaults (survive the test.exs :oidc merge).
      assert OIDC.external_group() == "sxi-external"
      assert OIDC.external_claim() == "groups"
    end
  end

  # Task 019ff7ff stage 2 — the claim's VALUES, not its truthiness.
  describe "claim_groups/1" do
    test "a list comes back as a list of strings, order preserved" do
      assert OIDC.claim_groups(%{"groups" => ["employees", "acme-client"]}) ==
               ["employees", "acme-client"]
    end

    test "a bare string wraps to a one-element list" do
      assert OIDC.claim_groups(%{"groups" => "acme-client"}) == ["acme-client"]
    end

    test "nil, absent, and malformed claims all yield []" do
      assert OIDC.claim_groups(%{"groups" => nil}) == []
      assert OIDC.claim_groups(%{"sub" => "x"}) == []
      assert OIDC.claim_groups(%{"groups" => %{"nested" => true}}) == []
      assert OIDC.claim_groups(%{"groups" => 42}) == []
    end

    test "non-binary members of a list are dropped, binaries kept" do
      assert OIDC.claim_groups(%{"groups" => ["acme-client", 42, nil, %{}]}) == ["acme-client"]
    end

    test "non-map input -> []" do
      assert OIDC.claim_groups(nil) == []
      assert OIDC.claim_groups("groups") == []
    end

    test "reads the configured claim NAME, not a hardcoded \"groups\"" do
      original = Application.get_env(:platform, :oidc, [])

      try do
        Application.put_env(:platform, :oidc, Keyword.put(original, :external_claim, "roles"))
        assert OIDC.claim_groups(%{"roles" => ["acme-client"]}) == ["acme-client"]
        # Anti-vacuity: the OLD claim name no longer reads.
        assert OIDC.claim_groups(%{"groups" => ["acme-client"]}) == []
      after
        Application.put_env(:platform, :oidc, original)
      end
    end

    test "does NOT depend on external_group being configured (values are data, not a marker)" do
      original = Application.get_env(:platform, :oidc, [])

      try do
        Application.put_env(:platform, :oidc, Keyword.put(original, :external_group, nil))
        assert OIDC.claim_groups(%{"groups" => ["acme-client"]}) == ["acme-client"]
        # Control: the predicate DOES go false under the same config.
        refute OIDC.external_claim?(%{"groups" => ["sxi-external"]})
      after
        Application.put_env(:platform, :oidc, original)
      end
    end
  end

  describe "external_claim?/1" do
    test "list containing the group -> true" do
      assert OIDC.external_claim?(%{"groups" => ["employees", "sxi-external"]})
    end

    test "list without the group -> false" do
      refute OIDC.external_claim?(%{"groups" => ["employees", "partners"]})
    end

    test "bare string equal to the group -> true" do
      assert OIDC.external_claim?(%{"groups" => "sxi-external"})
    end

    test "bare string not equal -> false" do
      refute OIDC.external_claim?(%{"groups" => "sxi-internal"})
    end

    test "claim missing entirely -> false" do
      refute OIDC.external_claim?(%{"sub" => "x", "email" => "e@x.io"})
    end

    test "malformed claim (map / number) -> false, no crash" do
      refute OIDC.external_claim?(%{"groups" => %{"nested" => true}})
      refute OIDC.external_claim?(%{"groups" => 42})
      refute OIDC.external_claim?(%{"groups" => nil})
    end

    test "non-map input -> false" do
      refute OIDC.external_claim?(nil)
      refute OIDC.external_claim?("groups")
    end

    test "no configured group -> false even if a matching claim is present" do
      original = Application.get_env(:platform, :oidc, [])

      try do
        Application.put_env(:platform, :oidc, Keyword.put(original, :external_group, nil))
        refute OIDC.external_claim?(%{"groups" => ["sxi-external"]})
      after
        Application.put_env(:platform, :oidc, original)
      end
    end
  end

  # ADR 0053 (task 01a0d69d stage 3): Assent's Httpc adapter with no trust
  # store verifies against :certifi.cacerts(), compiled into certifi.beam, so an
  # install's own root (tls = internal) could never be trusted and /auth/login
  # answered 500. Measured on a throwaway VM: the install root was in CAStore's
  # file and in :public_key.cacerts_get(), and absent from :certifi.cacerts().
  describe "http_adapter/1 trust store" do
    test "prod configures the bare Httpc adapter (the value http_adapter/1 resolves)" do
      config = Config.Reader.read!(Path.expand("../../config/config.exs", __DIR__), env: :prod)

      assert get_in(config, [:platform, :oidc, :http_adapter]) == Assent.HTTPAdapter.Httpc
    end

    test "the bare Httpc adapter verifies against CAStore's file, the global trust store" do
      assert OIDC.http_adapter(Assent.HTTPAdapter.Httpc) ==
               {Assent.HTTPAdapter.Httpc, ssl: [cacertfile: CAStore.file_path()]}

      assert File.read!(CAStore.file_path()) =~ "-----BEGIN CERTIFICATE-----"
    end

    test "only the trust store is supplied, so Assent keeps peer and hostname verification" do
      {Assent.HTTPAdapter.Httpc, opts} = OIDC.http_adapter(Assent.HTTPAdapter.Httpc)

      # Assent.HTTPAdapter.Httpc adds verify: :verify_peer, a hostname
      # verify_fun and customize_hostname_check only when :verify_fun is absent.
      assert Keyword.keys(opts[:ssl]) == [:cacertfile]
    end

    test "any other configured adapter passes through unchanged" do
      assert OIDC.http_adapter({Assent.HTTPAdapter.Mint, []}) == {Assent.HTTPAdapter.Mint, []}
      assert OIDC.http_adapter(nil) == nil
    end
  end
end
