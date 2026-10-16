defmodule Platform.Agents.AgentRuntimeTest do
  @moduledoc """
  Tests for the `AgentRuntime` schema's pure helpers and the
  `Platform.Federation.update_metadata/2` round-trip.

  Pure helper tests use `ExUnit.Case` (no DB). The `update_metadata/2`
  round-trip uses `Platform.DataCase` because it touches Postgres.
  """
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Agents.AgentRuntime
  alias Platform.Access.RuntimeProfiles
  alias Platform.Federation
  alias Platform.Federation.ToolAuthorization
  alias Platform.Federation.ToolSurface
  alias Platform.Repo

  describe "default_tool_profile/0 (pure)" do
    test "includes \"skill\" so federated runtimes get DB-shipped skill access by default" do
      assert "skill" in AgentRuntime.default_tool_profile()
    end

    test "every default bundle is in the valid bundle allowlist" do
      defaults = AgentRuntime.default_tool_profile()
      valid = RuntimeProfiles.valid_modules()
      assert Enum.all?(defaults, &(&1 in valid))
    end
  end

  describe "meetings bundle reachability (task 01a066af stage 4)" do
    # `meeting_say` is the only way an invited agent can speak in a room. It
    # was registered inside `task_tools/0` and therefore stamped `"task"`, a
    # bundle that is NOT a default — so a voice-capable runtime sitting on the
    # defaults was refused by `ToolAuthorization.authorize/2` before the
    # room-membership guard ever ran, and could not speak at all.
    #
    # The runtime here is built from the accessor, not a literal list: the
    # point is that WHATEVER the defaults are, they reach `meeting_say`.
    # A root-admin owner supplies the permission cap for this positive control.
    test "a runtime on default bundles may call meeting_say" do
      {:ok, runtime} =
        Federation.register_runtime(root_admin!().id, %{
          runtime_id: "meeting-default-#{System.unique_integer([:positive])}"
        })

      assert :ok = ToolAuthorization.authorize("meeting_say", runtime)
      assert :ok = ToolAuthorization.authorize("meeting_create", runtime)
      assert "meeting_say" in ToolAuthorization.tool_names(runtime)
    end

    # Task 01a083c3 stage 1 — the same defect as above, one tool later.
    # `meeting_activity_push` was registered in `task_tools/0` by task 01a07400
    # stage 1, AFTER 01a066af stage 4 had moved `meeting_create` and
    # `meeting_say` into `meetings`, so it stayed stamped `"task"`. A default
    # runtime could therefore speak in a meeting but could not declare that it
    # was thinking, so it read as idle and, past 120s, as failed.
    #
    # Built from the accessor, never a literal bundle list: the proposition is
    # that WHATEVER the defaults are, they reach this tool. Hardcoding
    # `["federation", ..., "meetings"]` would assert something else entirely
    # and would survive removal of `"meetings"` from `@default_tool_profile`.
    #
    # `authorize/2` returns a BARE `{:error, :forbidden}`; the readable
    # `tool '...' not in allowed bundles` string is rendered only at the
    # transport boundaries (`runtime_channel.ex`, `mcp_controller.ex`), so
    # there is nothing to match on here beyond `:ok`.
    test "a runtime on default bundles may call meeting_activity_push" do
      {:ok, runtime} =
        Federation.register_runtime(root_admin!().id, %{
          runtime_id: "meeting-activity-default-#{System.unique_integer([:positive])}"
        })

      assert :ok = ToolAuthorization.authorize("meeting_activity_push", runtime)
      assert "meeting_activity_push" in ToolAuthorization.tool_names(runtime)
    end

    test "\"meetings\" is a default, not merely grantable" do
      assert "meetings" in AgentRuntime.default_tool_profile()
      assert "meetings" in RuntimeProfiles.valid_modules()
      assert "meetings" in ToolSurface.all_bundles()
    end
  end

  describe "bundle registry is a single set" do
    # Task 019ff110. `ToolSurface.all_bundles/0` registered `files` while
    # `@core_valid_modules` rejected it, so the full surface could not be persisted
    # onto a runtime row even deliberately — `all_bundles/0` did not round-trip
    # into `tool_profile`.
    #
    # Both operands are derived from their own module's accessor ON PURPOSE.
    # A test pinning the names would pass while both lists drifted together in
    # the wrong direction, and would need editing on every legitimate bundle
    # addition — which trains people to edit it without reading it.
    test "ToolSurface.all_bundles/0 and RuntimeProfiles.valid_modules/0 agree exactly" do
      surface = MapSet.new(ToolSurface.all_bundles())
      valid = MapSet.new(RuntimeProfiles.valid_modules())

      registered_but_rejected = surface |> MapSet.difference(valid) |> Enum.sort()
      permitted_but_unregistered = valid |> MapSet.difference(surface) |> Enum.sort()

      # Both directions are named separately: a bare `assert a == b` on two
      # long lists says nothing about which side is wrong or which way to fix
      # it, and the two directions have opposite remedies.
      message = """
      The bundle registry has drifted into two different sets.

      Registered by ToolSurface.all_bundles/0 but REJECTED by \
      RuntimeProfiles.valid_modules/0 (a runtime cannot hold these, so the tools \
      in them can never be granted): #{inspect(registered_but_rejected)}

      Permitted by RuntimeProfiles.valid_modules/0 but NEVER REGISTERED by \
      ToolSurface.all_bundles/0 (a row may hold these and get nothing): \
      #{inspect(permitted_but_unregistered)}

      Fix the side that is stale. Widening the validator makes a bundle \
      grantable; it does not grant it, and it must not change \
      @default_tool_profile.
      """

      assert surface == valid, message
    end
  end

  describe "newly-registered runtime (DB)" do
    test "receives the default tool_profile, including \"skill\"" do
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "rt-default-bundles-#{System.unique_integer([:positive])}"
        })

      reloaded = Repo.get!(AgentRuntime, runtime.id)
      assert "skill" in RuntimeProfiles.tool_profile(reloaded)
      assert RuntimeProfiles.tool_profile(reloaded) == AgentRuntime.default_tool_profile()
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

    # Task 01a0d6c5 stage 2: the Hermes Agent channel plugin declares
    # `hermes_channel`. Without it in the allowlist the runtime reads as
    # "unknown" and falls through to the model-name guidance path.
    test "returns \"hermes_channel\" when metadata.client_info.product is \"hermes_channel\"" do
      runtime = %AgentRuntime{
        metadata: %{"client_info" => %{"product" => "hermes_channel", "version" => "0.1.0"}}
      }

      assert AgentRuntime.client_product(runtime) == "hermes_channel"
    end

    test "returns \"unknown\" for a near-miss of hermes_channel (allowlist is exact)" do
      runtime = %AgentRuntime{metadata: %{"client_info" => %{"product" => "hermes"}}}
      assert AgentRuntime.client_product(runtime) == "unknown"
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

  defp create_user, do: root_admin!()
end
