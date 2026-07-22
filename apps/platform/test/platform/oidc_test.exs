defmodule Platform.OIDCTest do
  @moduledoc """
  rbac-external-users M2 stage 1: the OIDC external-marker claim readers.
  `external_claim?/1` is the pure predicate `normalize_oidc_user/1` delegates
  to, so exercising it here covers the claim-shape matrix the plan pins.
  """
  use ExUnit.Case, async: true

  alias Platform.OIDC

  describe "external_group/0 + external_claim/0" do
    test "read the configured marker value and claim name (test defaults)" do
      # config/config.exs base defaults (survive the test.exs :oidc merge).
      assert OIDC.external_group() == "sxi-external"
      assert OIDC.external_claim() == "groups"
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
end
