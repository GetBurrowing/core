defmodule Platform.Agents.AgentRuntimeTest do
  @moduledoc """
  Tests for the `AgentRuntime` schema's pure helpers and the
  `Platform.Federation.update_metadata/2` round-trip.

  Pure helper tests use `ExUnit.Case` (no DB). The `update_metadata/2`
  round-trip uses `Platform.DataCase` because it touches Postgres.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.AgentRuntime
  alias Platform.Federation
  alias Platform.Federation.ToolSurface
  alias Platform.Repo

  describe "default_allowed_bundles/0 (pure)" do
    test "includes \"skill\" so federated runtimes get DB-shipped skill access by default" do
      assert "skill" in AgentRuntime.default_allowed_bundles()
    end

    test "every default bundle is in the valid bundle allowlist" do
      defaults = AgentRuntime.default_allowed_bundles()
      valid = AgentRuntime.valid_bundles()
      assert Enum.all?(defaults, &(&1 in valid))
    end
  end

  describe "bundle registry is a single set" do
    # Task 019ff110. `ToolSurface.all_bundles/0` registered `files` while
    # `@valid_bundles` rejected it, so the full surface could not be persisted
    # onto a runtime row even deliberately — `all_bundles/0` did not round-trip
    # into `allowed_bundles`.
    #
    # Both operands are derived from their own module's accessor ON PURPOSE.
    # A test pinning the names would pass while both lists drifted together in
    # the wrong direction, and would need editing on every legitimate bundle
    # addition — which trains people to edit it without reading it.
    test "ToolSurface.all_bundles/0 and AgentRuntime.valid_bundles/0 agree exactly" do
      surface = MapSet.new(ToolSurface.all_bundles())
      valid = MapSet.new(AgentRuntime.valid_bundles())

      registered_but_rejected = surface |> MapSet.difference(valid) |> Enum.sort()
      permitted_but_unregistered = valid |> MapSet.difference(surface) |> Enum.sort()

      # Both directions are named separately: a bare `assert a == b` on two
      # long lists says nothing about which side is wrong or which way to fix
      # it, and the two directions have opposite remedies.
      message = """
      The bundle registry has drifted into two different sets.

      Registered by ToolSurface.all_bundles/0 but REJECTED by \
      AgentRuntime.valid_bundles/0 (a runtime cannot hold these, so the tools \
      in them can never be granted): #{inspect(registered_but_rejected)}

      Permitted by AgentRuntime.valid_bundles/0 but NEVER REGISTERED by \
      ToolSurface.all_bundles/0 (a row may hold these and get nothing): \
      #{inspect(permitted_but_unregistered)}

      Fix the side that is stale. Widening the validator makes a bundle \
      grantable; it does not grant it, and it must not change \
      @default_allowed_bundles.
      """

      assert surface == valid, message
    end
  end

  describe "newly-registered runtime (DB)" do
    test "receives the default allowed_bundles, including \"skill\"" do
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "rt-default-bundles-#{System.unique_integer([:positive])}"
        })

      reloaded = Repo.get!(AgentRuntime, runtime.id)
      assert "skill" in reloaded.allowed_bundles
      assert reloaded.allowed_bundles == AgentRuntime.default_allowed_bundles()
    end
  end

  describe "client_product/1 (pure)" do
    test "returns \"openclaw\" when metadata.client_info.product is \"openclaw\"" do
      runtime = %AgentRuntime{
        metadata: %{"client_info" => %{"product" => "openclaw", "version" => "0.1.0"}}
      }

      assert AgentRuntime.client_product(runtime) == "openclaw"
    end

    test "returns \"claude_channel\" when metadata.client_info.product is \"claude_channel\"" do
      runtime = %AgentRuntime{
        metadata: %{"client_info" => %{"product" => "claude_channel"}}
      }

      assert AgentRuntime.client_product(runtime) == "claude_channel"
    end

    test "returns \"unknown\" when metadata is empty (no client_info ever set)" do
      runtime = %AgentRuntime{metadata: %{}}
      assert AgentRuntime.client_product(runtime) == "unknown"
    end

    test "returns \"unknown\" when client_info is present but product key is missing" do
      runtime = %AgentRuntime{metadata: %{"client_info" => %{"version" => "0.1.0"}}}
      assert AgentRuntime.client_product(runtime) == "unknown"
    end

    test "returns \"unknown\" defensively when product is not in the allowlist" do
      runtime = %AgentRuntime{
        metadata: %{"client_info" => %{"product" => "definitely-not-real"}}
      }

      assert AgentRuntime.client_product(runtime) == "unknown"
    end

    test "returns \"unknown\" when client_info is present but not a map" do
      runtime = %AgentRuntime{metadata: %{"client_info" => "garbage"}}
      assert AgentRuntime.client_product(runtime) == "unknown"
    end
  end

  describe "client_features/1 (pure)" do
    test "returns the declared feature list when client_info.features is present" do
      runtime = %AgentRuntime{
        metadata: %{
          "client_info" => %{
            "product" => "claude_channel",
            "version" => "0.3.0",
            "features" => ["system_event_prompt"]
          }
        }
      }

      assert AgentRuntime.client_features(runtime) == ["system_event_prompt"]
      # The new accessor must not disturb the existing product read.
      assert AgentRuntime.client_product(runtime) == "claude_channel"
    end

    test "returns every declared binary feature, not just the one this task cares about" do
      runtime = %AgentRuntime{
        metadata: %{
          "client_info" => %{"features" => ["alpha", "system_event_prompt", "zeta"]}
        }
      }

      assert AgentRuntime.client_features(runtime) == ["alpha", "system_event_prompt", "zeta"]
    end

    test "returns [] when client_info is present but the features key is missing" do
      runtime = %AgentRuntime{
        metadata: %{"client_info" => %{"product" => "claude_channel", "version" => "0.2.0"}}
      }

      assert AgentRuntime.client_features(runtime) == []
    end

    test "returns [] when metadata is empty (no client_info ever set)" do
      assert AgentRuntime.client_features(%AgentRuntime{metadata: %{}}) == []
    end

    test "returns [] when metadata is nil (legacy row)" do
      assert AgentRuntime.client_features(%AgentRuntime{metadata: nil}) == []
    end

    test "returns [] when client_info is present but not a map" do
      assert AgentRuntime.client_features(%AgentRuntime{metadata: %{"client_info" => "garbage"}}) ==
               []
    end

    test "returns [] for non-list features values (map, string, integer, nil)" do
      for bad <- [%{"a" => 1}, "system_event_prompt", 7, nil] do
        runtime = %AgentRuntime{metadata: %{"client_info" => %{"features" => bad}}}
        assert AgentRuntime.client_features(runtime) == [], "expected [] for #{inspect(bad)}"
      end
    end

    test "filters non-binary entries out of a mixed list, keeping the binaries" do
      runtime = %AgentRuntime{
        metadata: %{
          "client_info" => %{
            "features" => ["system_event_prompt", 1, nil, %{"a" => 1}, ["nested"], :atom, "other"]
          }
        }
      }

      assert AgentRuntime.client_features(runtime) == ["system_event_prompt", "other"]
    end

    test "never returns nil for any of the degenerate shapes" do
      for runtime <- [
            %AgentRuntime{metadata: %{}},
            %AgentRuntime{metadata: nil},
            %AgentRuntime{metadata: %{"client_info" => %{}}},
            %AgentRuntime{metadata: %{"client_info" => %{"features" => nil}}}
          ] do
        assert is_list(AgentRuntime.client_features(runtime))
      end
    end
  end

  describe "client_supports?/2 (pure)" do
    test "true for a declared feature and false for an undeclared one, in the same run" do
      runtime = %AgentRuntime{
        metadata: %{"client_info" => %{"features" => ["system_event_prompt"]}}
      }

      assert AgentRuntime.client_supports?(runtime, "system_event_prompt") == true
      assert AgentRuntime.client_supports?(runtime, "some_other_capability") == false
    end

    test "a claude_channel runtime at version \"0.2.0\" with no features returns false — version is not the discriminator" do
      # Exact production shape of every runtime on the ticket's list.
      unproven = %AgentRuntime{
        metadata: %{"client_info" => %{"product" => "claude_channel", "version" => "0.2.0"}}
      }

      # Same version string, but the capability is declared.
      proven = %AgentRuntime{
        metadata: %{
          "client_info" => %{
            "product" => "claude_channel",
            "version" => "0.2.0",
            "features" => ["system_event_prompt"]
          }
        }
      }

      assert AgentRuntime.client_supports?(unproven, "system_event_prompt") == false
      assert AgentRuntime.client_supports?(proven, "system_event_prompt") == true

      # The two differ only in `features`; the version field is identical.
      assert unproven.metadata["client_info"]["version"] ==
               proven.metadata["client_info"]["version"]
    end

    test "fails closed for a runtime we have heard nothing from" do
      assert AgentRuntime.client_supports?(%AgentRuntime{metadata: %{}}, "system_event_prompt") ==
               false

      assert AgentRuntime.client_supports?(%AgentRuntime{metadata: nil}, "system_event_prompt") ==
               false

      assert AgentRuntime.client_supports?(
               %AgentRuntime{metadata: %{"client_info" => "garbage"}},
               "system_event_prompt"
             ) == false
    end

    test "requires an exact match — near-miss feature names are not accepted" do
      runtime = %AgentRuntime{
        metadata: %{
          "client_info" => %{
            "features" => [
              "system_event_prompt_v2",
              "SYSTEM_EVENT_PROMPT",
              " system_event_prompt ",
              "system_event"
            ]
          }
        }
      }

      assert AgentRuntime.client_supports?(runtime, "system_event_prompt") == false
      # ...but an exactly-matching entry in the same list shape does count.
      exact = %AgentRuntime{
        metadata: %{
          "client_info" => %{"features" => ["system_event_prompt_v2", "system_event_prompt"]}
        }
      }

      assert AgentRuntime.client_supports?(exact, "system_event_prompt") == true
    end
  end

  describe "system_event_prompt_feature/0 (pure)" do
    test "is the literal string the fixed bridge declares" do
      assert AgentRuntime.system_event_prompt_feature() == "system_event_prompt"
    end

    test "drives client_supports?/2 both ways so callers need no bare literal" do
      feature = AgentRuntime.system_event_prompt_feature()

      proven = %AgentRuntime{metadata: %{"client_info" => %{"features" => [feature]}}}
      unproven = %AgentRuntime{metadata: %{"client_info" => %{"product" => "claude_channel"}}}

      assert AgentRuntime.client_supports?(proven, feature) == true
      assert AgentRuntime.client_supports?(unproven, feature) == false
    end
  end

  describe "Federation.update_metadata/2 (DB round-trip)" do
    test "merges new keys into metadata without dropping existing ones" do
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "rt-meta-#{System.unique_integer([:positive])}",
          metadata: %{"existing" => "keep"}
        })

      {:ok, updated} =
        Federation.update_metadata(runtime, %{
          "client_info" => %{"product" => "openclaw", "version" => "0.1.0"}
        })

      reloaded = Repo.get!(AgentRuntime, updated.id)

      assert reloaded.metadata["existing"] == "keep"
      assert reloaded.metadata["client_info"] == %{"product" => "openclaw", "version" => "0.1.0"}
      assert AgentRuntime.client_product(reloaded) == "openclaw"
    end

    test "treats nil metadata as empty map (defensive)" do
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "rt-meta-#{System.unique_integer([:positive])}"
        })

      # Force-clear metadata to nil to simulate a legacy row.
      runtime = %{runtime | metadata: nil}

      {:ok, updated} =
        Federation.update_metadata(runtime, %{"client_info" => %{"product" => "claude_channel"}})

      reloaded = Repo.get!(AgentRuntime, updated.id)
      assert reloaded.metadata["client_info"]["product"] == "claude_channel"
      assert AgentRuntime.client_product(reloaded) == "claude_channel"
    end
  end

  defp create_user do
    Repo.insert!(%User{
      email: "rt_meta_test_#{System.unique_integer([:positive])}@example.com",
      name: "Runtime Meta Test User",
      oidc_sub: "oidc-rt-meta-#{System.unique_integer([:positive])}"
    })
  end
end
