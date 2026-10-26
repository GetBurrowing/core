defmodule PlatformWeb.RuntimeChannelTest do
  use PlatformWeb.ChannelCase, async: false

  import Platform.TenancyFixtures
  import Ecto.Query

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Access.RuntimeProfiles
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Federation.DeadLetter
  alias Platform.Federation.DeadLetterReplay
  alias Platform.Federation.DeadLetters
  alias Platform.Federation.ToolAuthorization
  alias Platform.Federation.ToolSurface
  alias Platform.Meetings.IntentQueue
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks

  setup do
    # Set up a writable uploads directory for attachment tests
    previous_root = Application.get_env(:platform, :chat_attachments_root)

    upload_root =
      Platform.TestTemp.mkdir!("runtime_channel_test_uploads")

    Application.put_env(:platform, :chat_attachments_root, upload_root)

    on_exit(fn ->
      Application.put_env(:platform, :chat_attachments_root, previous_root)
      File.rm_rf(upload_root)
    end)

    user = create_user()
    agent = create_agent()

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "test-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, raw_token} = Federation.activate_runtime(runtime)
    {:ok, _linked} = Federation.link_agent(activated, agent)

    # Reload runtime to get agent_id
    runtime = Federation.get_runtime(activated.id)

    space = create_space()

    {:ok, agent_participant} =
      Chat.add_agent_participant(space.id, agent, display_name: agent.name)

    %{
      runtime: runtime,
      raw_token: raw_token,
      agent: agent,
      space: space,
      agent_participant: agent_participant,
      user: user
    }
  end

  defp set_runtime_profile(runtime, modules) do
    {:ok, _profile} = RuntimeProfiles.set_tool_profile(runtime, modules)
    {:ok, runtime}
  end

  defp create_user, do: root_admin!()

  defp create_agent(attrs \\ %{}) do
    defaults = %{
      slug: "agent-#{System.unique_integer([:positive])}",
      name: "Test Agent",
      status: "active"
    }

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    agent
  end

  # A second activated runtime with its own linked agent, for tests that need
  # two independent `proven` maps to compare against each other. Same shape as
  # the `setup` block above; the user is reused because the runtime, not its
  # owner, is what the presence map is keyed on.
  defp extra_runtime!(user) do
    agent = create_agent()

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "test-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, raw_token} = Federation.activate_runtime(runtime)
    {:ok, _linked} = Federation.link_agent(activated, agent)

    %{runtime: Federation.get_runtime(activated.id), raw_token: raw_token, agent: agent}
  end

  defp create_space(attrs \\ %{}) do
    default = %{name: "Test", slug: "test-#{System.unique_integer([:positive])}", kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp joined_socket(ctx) do
    {:ok, socket} =
      connect(PlatformWeb.RuntimeSocket, %{
        "runtime_id" => ctx.runtime.runtime_id,
        "token" => ctx.raw_token
      })

    {:ok, _reply, socket} = subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})
    socket
  end

  describe "connect and join" do
    test "authenticated runtime can connect and join channel", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})
    end

    test "unauthenticated connection is rejected" do
      assert :error =
               connect(PlatformWeb.RuntimeSocket, %{
                 "runtime_id" => "bogus",
                 "token" => "bad-token"
               })
    end

    test "wrong runtime_id on join is rejected", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, "runtime:wrong-id", %{})
    end

    test "channel process re-tracks presence when the RuntimePresence Agent state resets", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, joined_socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      assert Platform.Federation.RuntimePresence.online?(ctx.runtime.runtime_id)

      # Simulate the RuntimePresence Agent process crashing / hot-reloading
      # while the live RuntimeChannel process keeps running.
      # Fully-qualified because this file aliases `Platform.Agents.Agent`.
      Elixir.Agent.update(Platform.Federation.RuntimePresence, fn _ -> %{} end)
      refute Platform.Federation.RuntimePresence.online?(ctx.runtime.runtime_id)

      # Fire the retrack message directly — bypasses the 30s timer to keep
      # the test fast. The scheduled cycle uses the same handler.
      send(joined_socket.channel_pid, :presence_retrack)

      # Give the channel process a scheduling tick.
      _ = :sys.get_state(joined_socket.channel_pid)

      assert Platform.Federation.RuntimePresence.online?(ctx.runtime.runtime_id)
    end

    test "the 30s retrack preserves connected_at and only advances last_seen_at", ctx do
      # The self-heal above must not cost `connected_at` its meaning. When the
      # retrack overwrites the whole entry, `connected_at` becomes a rolling
      # 30-second clock: never older than one tick for ANY online runtime, so it
      # can no longer distinguish a fresh session from a month-old one. Note
      # that "connected_at is present and recent" passes either way — the
      # assertion that separates them is that it does not MOVE.
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, joined_socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      before = Platform.Federation.RuntimePresence.status(ctx.runtime.runtime_id)
      assert %{connected_at: %DateTime{}, last_seen_at: %DateTime{}} = before

      # Two full retrack cycles. The sleep is what makes the difference
      # observable: `DateTime.utc_now/0` twice inside one microsecond would
      # compare `:eq` for reasons that have nothing to do with the fix.
      for _ <- 1..2 do
        Process.sleep(10)
        send(joined_socket.channel_pid, :presence_retrack)
        _ = :sys.get_state(joined_socket.channel_pid)
      end

      later = Platform.Federation.RuntimePresence.status(ctx.runtime.runtime_id)

      # The session start is not a rolling clock.
      assert DateTime.compare(later.connected_at, before.connected_at) == :eq

      # ...and the retrack still ran: liveness moved forward. Without this half
      # a retrack that did nothing at all would pass.
      assert DateTime.compare(later.last_seen_at, before.last_seen_at) == :gt
    end

    test "a genuine re-join DOES move connected_at", ctx do
      # The counterpart to the test above: `connected_at` is pinned against the
      # 30s tick, not frozen. A real new session must still reset it, otherwise
      # the field is merely stale rather than merely rolling.
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, joined_socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      first_session = Platform.Federation.RuntimePresence.status(ctx.runtime.runtime_id)

      # `close/1` shuts the channel down with `{:shutdown, :closed}`, and
      # `subscribe_and_join` linked it to this process — untrapped, that EXIT
      # takes the test with it.
      Process.flag(:trap_exit, true)

      # Wait for terminate/2 to have actually run — it untracks, and racing it
      # against the second join would delete the entry we are about to read.
      ref = Process.monitor(joined_socket.channel_pid)
      close(joined_socket)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000
      refute Platform.Federation.RuntimePresence.online?(ctx.runtime.runtime_id)

      {:ok, rejoin_socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, _rejoined} =
        subscribe_and_join(rejoin_socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      second_session = Platform.Federation.RuntimePresence.status(ctx.runtime.runtime_id)

      assert DateTime.compare(second_session.connected_at, first_session.connected_at) == :gt
    end

    test "join drains this runtime's dead letters, and the 30s retrack does NOT", ctx do
      # There are exactly two presence call sites in this module: `track/1` in
      # join/3 and `touch/1` in the periodic `:presence_retrack` self-heal. Only
      # the first is a reconnect. Hooking the second would re-drain every
      # connected runtime twice a minute forever, so this test pins BOTH halves
      # — a drain-on-join assertion alone would still pass with the hook in the
      # wrong place.
      first = seed_dead_letter(ctx, 1)

      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, joined_socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      # A sync call behind join/3's cast: the replay server's mailbox is FIFO,
      # so this returns only once the join-triggered drain has finished.
      assert DeadLetterReplay.drain_count(ctx.runtime.runtime_id) == 1
      assert Repo.get(DeadLetter, first.id).disposition == "replayed"

      # Now a fresh, equally replayable letter — and the retrack path.
      second = seed_dead_letter(ctx, 2)

      send(joined_socket.channel_pid, :presence_retrack)
      _ = :sys.get_state(joined_socket.channel_pid)

      assert DeadLetterReplay.drain_count(ctx.runtime.runtime_id) == 1
      assert Repo.get(DeadLetter, second.id).disposition == "pending"

      # The positive control: that row was drainable the whole time, so its
      # survival above is the retrack declining to schedule, not an
      # undeliverable row.
      :ok = DeadLetterReplay.schedule(ctx.runtime.runtime_id)
      assert DeadLetterReplay.drain_count(ctx.runtime.runtime_id) == 2
      assert Repo.get(DeadLetter, second.id).disposition == "replayed"
    end
  end

  # A pending, policy-eligible `architecture.audit_diff` letter for this
  # context's runtime: a real current plan with a `passed` stage, which is what
  # `DeadLetterPolicy.audit_diff_freshness/1` rules on.
  defp seed_dead_letter(ctx, position) do
    suffix = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "DL Channel Project #{suffix}"})

    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "DL Channel Task #{suffix}"})

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: position,
        name: "Stage #{position}",
        status: "passed"
      })

    {:ok, letter} =
      DeadLetters.record(%{
        runtime_id: ctx.runtime.runtime_id,
        runtime_pk: ctx.runtime.id,
        agent_id: ctx.agent.id,
        agent_slug: ctx.agent.slug,
        source: "system_event",
        responsibility_key: "architecture.audit_diff",
        feature: "architecture",
        trigger_kind: :event_topic,
        subject_type: "stage",
        subject_id: stage.id,
        payload: %{
          signal: %{
            reason: :system_event,
            agent_id: ctx.agent.id,
            agent_slug: ctx.agent.slug,
            responsibility_key: "architecture.audit_diff",
            feature: "architecture",
            trigger_kind: :event_topic,
            metadata: %{stage_id: stage.id, plan_id: plan.id, task_id: task.id}
          }
        },
        reason: :runtime_offline
      })

    assert letter.disposition == "pending"
    letter
  end

  defp join_and_capture_capabilities(runtime, raw_token) do
    {:ok, socket} =
      connect(PlatformWeb.RuntimeSocket, %{
        "runtime_id" => runtime.runtime_id,
        "token" => raw_token
      })

    {:ok, _reply, _joined} = subscribe_and_join(socket, "runtime:#{runtime.runtime_id}", %{})

    assert_push("capabilities", payload)
    payload
  end

  # Join `runtime` with an explicit `client_info` map and return the joined
  # socket. Each call opens a fresh transport, so successive calls model a
  # runtime disconnecting and re-joining (used by the downgrade test).
  defp join_with_client_info(runtime, raw_token, client_info) do
    {:ok, socket} =
      connect(PlatformWeb.RuntimeSocket, %{
        "runtime_id" => runtime.runtime_id,
        "token" => raw_token
      })

    {:ok, _reply, joined} =
      subscribe_and_join(socket, "runtime:#{runtime.runtime_id}", %{
        "client_info" => client_info
      })

    joined
  end

  # Register and activate a SECOND runtime (with its own agent), so a test can
  # hold two independently-declaring runtimes at once. Mirrors the setup block.
  defp register_second_runtime(user) do
    agent = create_agent()

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "test-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, raw_token} = Federation.activate_runtime(runtime)
    {:ok, _linked} = Federation.link_agent(activated, agent)

    {Federation.get_runtime(activated.id), raw_token}
  end

  # Regression guard for the bug this task fixes: the push used to be
  # `ToolSurface.tool_definitions()` — the whole catalogue — regardless
  # of the runtime's `tool_profile`. It must now be exactly the set
  # `ToolAuthorization.effective_tools/1` resolves, which is also what
  # `/mcp tools/list` returns for the same runtime.
  describe "capabilities push" do
    test "is scoped to the runtime's granted bundles, not the full catalogue", ctx do
      # register_runtime/2 yields AgentRuntime.default_tool_profile/0 —
      # six bundles, with canvas/task/plan/memory/review absent.
      payload = join_and_capture_capabilities(ctx.runtime, ctx.raw_token)

      expected = ToolAuthorization.effective_tools(ctx.runtime)

      assert payload.tool_count == length(payload.tools)
      assert payload.tool_count == length(expected)
      assert Enum.map(payload.tools, & &1.name) == Enum.map(expected, & &1.name)

      # Strictly narrower than the full surface, and specifically missing
      # tools from bundles this runtime was never granted.
      assert payload.tool_count > 0
      assert payload.tool_count < length(ToolSurface.tool_definitions())

      names = Enum.map(payload.tools, & &1.name)
      assert "federation_status" in names
      refute "task_create" in names
      refute "canvas_create" in names
    end

    test "a federation-only runtime is pushed exactly federation_status", ctx do
      {:ok, runtime} = set_runtime_profile(ctx.runtime, ["federation"])

      payload = join_and_capture_capabilities(runtime, ctx.raw_token)

      assert Enum.map(payload.tools, & &1.name) == [
               "federation_status",
               "vault_fetch",
               "vault_list"
             ]

      assert payload.tool_count == 3
    end

    test "a runtime with no bundles is pushed zero tools", ctx do
      {:ok, runtime} = set_runtime_profile(ctx.runtime, [])

      payload = join_and_capture_capabilities(runtime, ctx.raw_token)

      assert payload.tools == []
      assert payload.tool_count == 0
    end

    test "fails closed to an empty set when the runtime row is gone at join time", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      # The row disappears between connect/3 (which authenticated against
      # it) and join/3. The join still succeeds; the push must NOT fall
      # back to the full surface.
      Repo.delete!(ctx.runtime)

      {:ok, _reply, joined} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      assert joined.assigns.runtime == nil
      assert_push("capabilities", payload)
      assert payload == %{tools: [], tool_count: 0}
    end

    test "emits capabilities_pushed telemetry carrying the scoped count", ctx do
      {:ok, runtime} = set_runtime_profile(ctx.runtime, ["federation"])

      handler_id = "capabilities-pushed-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:platform, :federation, :capabilities_pushed],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:capabilities_pushed, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      _payload = join_and_capture_capabilities(runtime, ctx.raw_token)

      assert_receive {:capabilities_pushed, %{tool_count: 3}, metadata}
      assert metadata.runtime_id == runtime.runtime_id
      assert metadata.external == false
    end
  end

  describe "client_info handshake on join" do
    test "join with valid client_info stashes assigns and persists to metadata", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, joined_socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{
          "client_info" => %{"product" => "openclaw", "version" => "1.2.3"}
        })

      assert joined_socket.assigns.client_info == %{
               product: "openclaw",
               version: "1.2.3",
               build: nil,
               build_error: nil,
               started_at: nil,
               features: []
             }

      reloaded = Repo.get(Platform.Agents.AgentRuntime, ctx.runtime.id)
      assert reloaded.metadata["client_info"]["product"] == "openclaw"
      assert reloaded.metadata["client_info"]["version"] == "1.2.3"
      assert is_binary(reloaded.metadata["client_info"]["last_seen_at"])
    end

    test "join without client_info defaults to unknown and does not touch metadata", ctx do
      original_metadata = ctx.runtime.metadata || %{}

      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, joined_socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      assert joined_socket.assigns.client_info == %{
               product: "unknown",
               version: nil,
               build: nil,
               build_error: nil,
               started_at: nil,
               features: []
             }

      reloaded = Repo.get(Platform.Agents.AgentRuntime, ctx.runtime.id)
      # Metadata should be unchanged — no client_info ever written.
      assert reloaded.metadata == original_metadata
      refute Map.has_key?(reloaded.metadata || %{}, "client_info")
    end

    test "join with bogus product lands as unknown but is still persisted", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, joined_socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{
          "client_info" => %{"product" => "definitely_not_a_real_product"}
        })

      assert joined_socket.assigns.client_info == %{
               product: "unknown",
               version: nil,
               build: nil,
               build_error: nil,
               started_at: nil,
               features: []
             }

      reloaded = Repo.get(Platform.Agents.AgentRuntime, ctx.runtime.id)
      # Client DID declare something, just garbage — we persist the
      # defensive "unknown" so we have a record of the failed declaration.
      assert reloaded.metadata["client_info"]["product"] == "unknown"
      assert reloaded.metadata["client_info"]["version"] == nil
      assert is_binary(reloaded.metadata["client_info"]["last_seen_at"])
    end

    # Task 01a0d6c5 stage 2: the Hermes Agent channel plugin.
    test "join with product hermes_channel persists hermes_channel", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, joined_socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{
          "client_info" => %{"product" => "hermes_channel", "version" => "0.1.0"}
        })

      assert joined_socket.assigns.client_info.product == "hermes_channel"

      reloaded = Repo.get(Platform.Agents.AgentRuntime, ctx.runtime.id)
      assert reloaded.metadata["client_info"]["product"] == "hermes_channel"
      assert Platform.Agents.AgentRuntime.client_product(reloaded) == "hermes_channel"
    end

    test "join with an unlisted near-miss product (hermes) still persists unknown", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, joined_socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{
          "client_info" => %{"product" => "hermes"}
        })

      assert joined_socket.assigns.client_info.product == "unknown"

      reloaded = Repo.get(Platform.Agents.AgentRuntime, ctx.runtime.id)
      assert reloaded.metadata["client_info"]["product"] == "unknown"
    end

    test "AgentRuntime.client_product/1 round-trips the persisted value end-to-end", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, _joined_socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{
          "client_info" => %{"product" => "claude_channel", "version" => "0.9.0"}
        })

      reloaded = Repo.get(Platform.Agents.AgentRuntime, ctx.runtime.id)
      assert Platform.Agents.AgentRuntime.client_product(reloaded) == "claude_channel"
    end
  end

  describe "client_info features handshake" do
    test "declared features persist alongside product and version", ctx do
      joined =
        join_with_client_info(ctx.runtime, ctx.raw_token, %{
          "product" => "claude_channel",
          "version" => "0.3.0",
          "features" => ["system_event_prompt"]
        })

      assert joined.assigns.client_info == %{
               product: "claude_channel",
               version: "0.3.0",
               build: nil,
               build_error: nil,
               started_at: nil,
               features: ["system_event_prompt"]
             }

      reloaded = Repo.get(Platform.Agents.AgentRuntime, ctx.runtime.id)
      ci = reloaded.metadata["client_info"]

      assert ci["features"] == ["system_event_prompt"]
      # The new key must be ADDITIVE. Asserting only `features` would pass
      # on a handshake that silently dropped product/version.
      assert ci["product"] == "claude_channel"
      assert ci["version"] == "0.3.0"
      assert is_binary(ci["last_seen_at"])
    end

    test "client_info without a features key persists an empty list", ctx do
      join_with_client_info(ctx.runtime, ctx.raw_token, %{
        "product" => "claude_channel",
        "version" => "0.2.0"
      })

      reloaded = Repo.get(Platform.Agents.AgentRuntime, ctx.runtime.id)
      ci = reloaded.metadata["client_info"]

      assert Map.has_key?(ci, "features")
      assert ci["features"] == []
      assert ci["product"] == "claude_channel"
      assert ci["version"] == "0.2.0"
    end

    test "re-joining on a build without the capability revokes the recorded claim", ctx do
      join_with_client_info(ctx.runtime, ctx.raw_token, %{
        "product" => "claude_channel",
        "version" => "0.3.0",
        "features" => ["system_event_prompt"]
      })

      after_fixed = Repo.get(Platform.Agents.AgentRuntime, ctx.runtime.id)
      assert after_fixed.metadata["client_info"]["features"] == ["system_event_prompt"]

      # Same runtime id, downgraded to a pre-fix build: declares client_info
      # but no features. `Federation.update_metadata/2` is shallow at the top
      # level, so the whole nested client_info map is replaced and the claim
      # is dropped. That is the REQUIRED semantic — a capability claim must
      # not outlive the build that earned it.
      join_with_client_info(ctx.runtime, ctx.raw_token, %{
        "product" => "claude_channel",
        "version" => "0.2.0"
      })

      after_downgrade = Repo.get(Platform.Agents.AgentRuntime, ctx.runtime.id)
      ci = after_downgrade.metadata["client_info"]

      assert ci["features"] == []
      assert ci["product"] == "claude_channel"
      assert ci["version"] == "0.2.0"
    end

    test "a join with no client_info at all leaves a prior declaration untouched", ctx do
      join_with_client_info(ctx.runtime, ctx.raw_token, %{
        "product" => "claude_channel",
        "version" => "0.3.0",
        "features" => ["system_event_prompt"]
      })

      declared = Repo.get(Platform.Agents.AgentRuntime, ctx.runtime.id)

      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, _joined} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      silent = Repo.get(Platform.Agents.AgentRuntime, ctx.runtime.id)

      # "never told us" and "told us it lacks the feature" must produce
      # DIFFERENT stored state: the silent join must not clear the claim
      # the way the downgrade join above does.
      assert silent.metadata["client_info"] == declared.metadata["client_info"]
      assert silent.metadata["client_info"]["features"] == ["system_event_prompt"]
    end

    test "non-list features degrade to an empty list without crashing the join", ctx do
      for hostile <- [%{"a" => 1}, [1, 2, 3], nil, "system_event_prompt", 42] do
        joined =
          join_with_client_info(ctx.runtime, ctx.raw_token, %{
            "product" => "claude_channel",
            "version" => "0.2.0",
            "features" => hostile
          })

        assert joined.assigns.client_info.features == [],
               "expected #{inspect(hostile)} to degrade to []"

        reloaded = Repo.get(Platform.Agents.AgentRuntime, ctx.runtime.id)
        assert reloaded.metadata["client_info"]["features"] == []
        assert reloaded.metadata["client_info"]["product"] == "claude_channel"
      end
    end

    test "oversized feature lists and entries are bounded before they reach jsonb", ctx do
      flood = for i <- 1..5000, do: "feature_#{i}"

      joined =
        join_with_client_info(ctx.runtime, ctx.raw_token, %{
          "product" => "claude_channel",
          "version" => "0.2.0",
          "features" => flood ++ ["system_event_prompt"]
        })

      persisted = joined.assigns.client_info.features

      assert length(persisted) == 32
      assert Enum.all?(persisted, &is_binary/1)
      assert persisted == Enum.sort(persisted)
      assert persisted == Enum.uniq(persisted)

      reloaded = Repo.get(Platform.Agents.AgentRuntime, ctx.runtime.id)
      assert reloaded.metadata["client_info"]["features"] == persisted

      # Individual entries over the byte cap are dropped, and dropping them
      # must not take the legitimate entry down with it.
      joined2 =
        join_with_client_info(ctx.runtime, ctx.raw_token, %{
          "product" => "claude_channel",
          "version" => "0.2.0",
          "features" => [
            String.duplicate("x", 10_000),
            String.duplicate("y", 65),
            String.duplicate("z", 64),
            "",
            "system_event_prompt",
            "system_event_prompt"
          ]
        })

      assert joined2.assigns.client_info.features == [
               "system_event_prompt",
               String.duplicate("z", 64)
             ]

      reloaded2 = Repo.get(Platform.Agents.AgentRuntime, ctx.runtime.id)

      assert reloaded2.metadata["client_info"]["features"] == [
               "system_event_prompt",
               String.duplicate("z", 64)
             ]
    end
  end

  # The fact this whole task exists for: a plugin release only takes effect
  # when the client PROCESS restarts, so `version` alone cannot tell you
  # whether a shipped capability is actually loaded. `build` says which build,
  # `started_at` says how old the process running it is.
  #
  # CROSS-REPO NOTE: core can only RECEIVE these keys. The channel plugin that
  # would send them lives in `claude-code-suite-channel`, a different repo.
  # Until a plugin release actually sends them, both persist as nil for real
  # runtimes — expected, and rendered downstream as "unknown", not as a bug.
  describe "client_info build and process start time" do
    test "two runtimes declaring different builds each persist their OWN build", ctx do
      {runtime_b, token_b} = register_second_runtime(ctx.user)

      sha_a = "1111111111111111111111111111111111111111"
      sha_b = "2222222222222222222222222222222222222222"
      refute sha_a == sha_b

      join_with_client_info(ctx.runtime, ctx.raw_token, %{
        "product" => "claude_channel",
        "version" => "0.3.0",
        "build" => sha_a,
        "started_at" => "2026-09-04T01:02:03Z"
      })

      join_with_client_info(runtime_b, token_b, %{
        "product" => "claude_channel",
        "version" => "0.3.0",
        "build" => sha_b,
        "started_at" => "2026-09-04T09:08:07Z"
      })

      reloaded_a = Repo.get(AgentRuntime, ctx.runtime.id)
      reloaded_b = Repo.get(AgentRuntime, runtime_b.id)

      # Deliberately NOT "a build key is present" — that is vacuous and passes
      # against a handshake that hardcodes one constant. Each row must carry
      # the value ITS OWN client sent, and the two must differ.
      assert AgentRuntime.client_build(reloaded_a) == sha_a
      assert AgentRuntime.client_build(reloaded_b) == sha_b
      refute AgentRuntime.client_build(reloaded_a) == AgentRuntime.client_build(reloaded_b)

      # Same shape of check for the process start time.
      assert AgentRuntime.client_started_at(reloaded_a) == ~U[2026-09-04 01:02:03Z]
      assert AgentRuntime.client_started_at(reloaded_b) == ~U[2026-09-04 09:08:07Z]

      refute AgentRuntime.client_started_at(reloaded_a) ==
               AgentRuntime.client_started_at(reloaded_b)
    end

    test "a client_info declaring neither build nor started_at persists nil for both", ctx do
      join_with_client_info(ctx.runtime, ctx.raw_token, %{
        "product" => "claude_channel",
        "version" => "0.3.0",
        "features" => ["system_event_prompt"]
      })

      reloaded = Repo.get(AgentRuntime, ctx.runtime.id)
      ci = reloaded.metadata["client_info"]

      assert Map.has_key?(ci, "build")
      assert Map.has_key?(ci, "started_at")
      assert ci["build"] == nil
      assert ci["started_at"] == nil
      assert AgentRuntime.client_build(reloaded) == nil
      assert AgentRuntime.client_started_at(reloaded) == nil

      # The new keys must be ADDITIVE: everything the handshake already
      # recorded still round-trips.
      assert ci["product"] == "claude_channel"
      assert ci["version"] == "0.3.0"
      assert ci["features"] == ["system_event_prompt"]
      assert is_binary(ci["last_seen_at"])
    end

    test "a malformed started_at persists nil, and the join still succeeds", ctx do
      joined =
        join_with_client_info(ctx.runtime, ctx.raw_token, %{
          "product" => "claude_channel",
          "version" => "0.3.0",
          "build" => "deadbeef",
          "started_at" => "yesterday"
        })

      # nil, NOT DateTime.utc_now/0. A fabricated process-start time would
      # render as "just restarted" — the exact false reassurance this field
      # exists to prevent — so an unparseable value must degrade to absent.
      assert joined.assigns.client_info.started_at == nil

      reloaded = Repo.get(AgentRuntime, ctx.runtime.id)
      assert reloaded.metadata["client_info"]["started_at"] == nil
      assert AgentRuntime.client_started_at(reloaded) == nil

      # And it does not take the rest of the declaration down with it.
      assert reloaded.metadata["client_info"]["build"] == "deadbeef"
      assert reloaded.metadata["client_info"]["product"] == "claude_channel"
    end

    test "a legacy join with no client_info at all records neither key", ctx do
      original_metadata = ctx.runtime.metadata || %{}

      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, joined} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      assert joined.assigns.client_info.build == nil
      assert joined.assigns.client_info.started_at == nil

      reloaded = Repo.get(AgentRuntime, ctx.runtime.id)

      # The `declared?` gate skips the persist entirely, so "never told us"
      # stays distinguishable from "told us it has no build".
      assert reloaded.metadata == original_metadata
      refute Map.has_key?(reloaded.metadata || %{}, "client_info")
      assert AgentRuntime.client_build(reloaded) == nil
      assert AgentRuntime.client_started_at(reloaded) == nil
    end

    test "rejoining on an older build REPLACES the recorded build", ctx do
      join_with_client_info(ctx.runtime, ctx.raw_token, %{
        "product" => "claude_channel",
        "version" => "0.3.0",
        "build" => "newbuildsha",
        "started_at" => "2026-09-04T10:00:00Z"
      })

      assert AgentRuntime.client_build(Repo.get(AgentRuntime, ctx.runtime.id)) == "newbuildsha"

      # Same runtime, restarted onto an older build. update_metadata/2 is
      # shallow at the top level so the nested map is replaced wholesale, and
      # the newer claim is lost. That is REQUIRED: a build claim must not
      # outlive the process that made it.
      join_with_client_info(ctx.runtime, ctx.raw_token, %{
        "product" => "claude_channel",
        "version" => "0.2.0",
        "build" => "oldbuildsha",
        "started_at" => "2026-09-04T11:00:00Z"
      })

      reloaded = Repo.get(AgentRuntime, ctx.runtime.id)
      assert AgentRuntime.client_build(reloaded) == "oldbuildsha"
      assert AgentRuntime.client_started_at(reloaded) == ~U[2026-09-04 11:00:00Z]
    end

    test "a build at the byte cap is kept; one over it is rejected, not truncated", ctx do
      at_cap = String.duplicate("a", 64)
      over_cap = String.duplicate("b", 65)

      joined_ok =
        join_with_client_info(ctx.runtime, ctx.raw_token, %{
          "product" => "claude_channel",
          "build" => at_cap
        })

      assert joined_ok.assigns.client_info.build == at_cap
      assert AgentRuntime.client_build(Repo.get(AgentRuntime, ctx.runtime.id)) == at_cap

      joined_over =
        join_with_client_info(ctx.runtime, ctx.raw_token, %{
          "product" => "claude_channel",
          "build" => over_cap
        })

      # nil, not a 64-byte prefix: a truncated sha is still a well-formed sha,
      # so truncating would manufacture an identifier pointing at no commit.
      assert joined_over.assigns.client_info.build == nil
      assert AgentRuntime.client_build(Repo.get(AgentRuntime, ctx.runtime.id)) == nil
    end

    test "the accessors return nil for every degenerate metadata shape", _ctx do
      degenerate = [
        %{},
        %{metadata: nil},
        %{metadata: "not a map"},
        %{metadata: %{}},
        %{metadata: %{"client_info" => nil}},
        %{metadata: %{"client_info" => "not a map"}},
        %{metadata: %{"client_info" => []}},
        %{metadata: %{"client_info" => %{}}},
        %{metadata: %{"client_info" => %{"build" => 42, "started_at" => 42}}},
        %{metadata: %{"client_info" => %{"build" => nil, "started_at" => nil}}},
        %{metadata: %{"client_info" => %{"build" => "", "started_at" => "yesterday"}}},
        %{metadata: %{"client_info" => %{"started_at" => "2026-13-45T99:99:99Z"}}}
      ]

      for input <- degenerate do
        assert AgentRuntime.client_build(input) == nil,
               "client_build/1 did not return nil for #{inspect(input)}"

        assert AgentRuntime.client_started_at(input) == nil,
               "client_started_at/1 did not return nil for #{inspect(input)}"
      end
    end

    # DISCRIMINATING CHECK against the failure this ticket was actually filed
    # from, using the verbatim handshake the channel plugin sends on either
    # side of the capability boundary.
    #
    # The missing capability was the `meeting_transcript` handler, added to
    # `claude-code-suite-channel` in 63229eb (2026-09-03). A plugin older than
    # that receives nothing from a meeting and sits mute, with no error.
    # 63229eb touched NEITHER package.json NOR CLIENT_FEATURES — verified in
    # that repo: `version` is "0.3.0" and `CLIENT_FEATURES` is the identical
    # single-element ["system_event_prompt"] at both commits. The two builds
    # therefore send a BYTE-IDENTICAL client_info across exactly the boundary
    # that cost a real meeting.
    #
    # So: any surfacing built on product/version/features alone is VACUOUS for
    # this ticket — an operator reads 0.3.0 / ["system_event_prompt"] either
    # way and concludes the runtime is fine. This test pins that, and pins
    # that `build` is the field that breaks the tie.
    #
    # It is a TRIPWIRE. When a plugin release starts declaring `build`, the
    # first two nil assertions below start failing, and what has to be
    # rewritten is precisely the claim "core still cannot tell these apart".
    test "the two plugin builds this ticket was filed from are indistinguishable until the plugin declares a build",
         ctx do
      {runtime_b, token_b} = register_second_runtime(ctx.user)

      # Verbatim CLIENT_INFO from both commits. Equal on purpose.
      before_capability = %{
        "product" => "claude_channel",
        "version" => "0.3.0",
        "features" => ["system_event_prompt"]
      }

      after_capability = %{
        "product" => "claude_channel",
        "version" => "0.3.0",
        "features" => ["system_event_prompt"]
      }

      assert before_capability == after_capability,
             "the premise of this test is that the plugin handshake did not change across 63229eb"

      join_with_client_info(ctx.runtime, ctx.raw_token, before_capability)
      join_with_client_info(runtime_b, token_b, after_capability)

      stale = Repo.get(AgentRuntime, ctx.runtime.id)
      current = Repo.get(AgentRuntime, runtime_b.id)

      # Everything that arrives TODAY is equal, so nothing built on it can
      # discriminate the two builds.
      assert Map.take(stale.metadata["client_info"], ["product", "version", "features"]) ==
               Map.take(current.metadata["client_info"], ["product", "version", "features"])

      # And the two fields this stage adds are nil on both sides, because
      # neither plugin build sends them. Core can only RECEIVE these keys —
      # the plugin is a different repository. This stage alone therefore does
      # NOT make the originating failure detectable; the remaining gap is
      # entirely upstream.
      assert AgentRuntime.client_build(stale) == nil
      assert AgentRuntime.client_build(current) == nil
      assert AgentRuntime.client_started_at(stale) == nil
      assert AgentRuntime.client_started_at(current) == nil

      # The same two runtimes DO separate the moment the plugin declares its
      # build. The receive path added here is the mechanism; only the client
      # side is missing.
      join_with_client_info(
        ctx.runtime,
        ctx.raw_token,
        Map.put(before_capability, "build", "b238164e")
      )

      join_with_client_info(runtime_b, token_b, Map.put(after_capability, "build", "63229eb"))

      refute AgentRuntime.client_build(Repo.get(AgentRuntime, ctx.runtime.id)) ==
               AgentRuntime.client_build(Repo.get(AgentRuntime, runtime_b.id))
    end

    # MEASURED COUNTEREXAMPLE, encoded so it cannot be forgotten by a display
    # stage. On 2026-09-04 a runtime on another host reported a process start
    # of 2026-09-03 21:06 — SIX HOURS AFTER plugin commit 63229eb merged
    # upstream at 15:07Z — and still could not hear a meeting, because its
    # local checkout was behind and the restart loaded months-old code.
    #
    # So "started_at is later than the fix" does NOT imply "has the fix".
    # `started_at` can only REFUTE freshness (started before the fix => cannot
    # have it), never establish it. `build` is the field that actually
    # discriminates. This test pins that asymmetry as behaviour: the runtime
    # that looks NEWER by start time is the one that is STALE by build.
    test "a process that restarted after the fix can still be on an old build — started_at cannot establish freshness",
         ctx do
      {runtime_b, token_b} = register_second_runtime(ctx.user)

      fix_merged_at = ~U[2026-09-03 15:07:00Z]

      # Saru's runtime: restarted well AFTER the fix merged, but the checkout
      # it loaded was stale, so it is running pre-capability code.
      join_with_client_info(ctx.runtime, ctx.raw_token, %{
        "product" => "claude_channel",
        "version" => "0.3.0",
        "build" => "b238164e",
        "started_at" => "2026-09-03T21:06:00Z"
      })

      # A genuinely current runtime that happens to have been started EARLIER
      # than the stale one, but after the fix.
      join_with_client_info(runtime_b, token_b, %{
        "product" => "claude_channel",
        "version" => "0.3.0",
        "build" => "63229eb",
        "started_at" => "2026-09-03T16:00:00Z"
      })

      stale = Repo.get(AgentRuntime, ctx.runtime.id)
      current = Repo.get(AgentRuntime, runtime_b.id)

      # Both restarted after the fix merged, so a "started after the fix ⇒ has
      # the fix" reading calls BOTH current. That reading is wrong.
      assert DateTime.compare(AgentRuntime.client_started_at(stale), fix_merged_at) == :gt
      assert DateTime.compare(AgentRuntime.client_started_at(current), fix_merged_at) == :gt

      # Worse: ordering by start time ranks the STALE runtime as the fresher
      # of the two. Recency of restart is anti-correlated with truth here.
      assert DateTime.compare(
               AgentRuntime.client_started_at(stale),
               AgentRuntime.client_started_at(current)
             ) == :gt

      # Only `build` separates them correctly.
      assert AgentRuntime.client_build(stale) == "b238164e"
      assert AgentRuntime.client_build(current) == "63229eb"
    end

    test "a non-UTC started_at is normalized to UTC on the way in and out", ctx do
      join_with_client_info(ctx.runtime, ctx.raw_token, %{
        "product" => "claude_channel",
        "build" => "tzsha",
        "started_at" => "2026-09-04T12:00:00+02:00"
      })

      reloaded = Repo.get(AgentRuntime, ctx.runtime.id)
      assert AgentRuntime.client_started_at(reloaded) == ~U[2026-09-04 10:00:00Z]
    end
  end

  # Task 01a09e63 stage 3. Before this, every runtime without a build rendered
  # the same "unknown" — a client that TRIED and could not resolve its sha, a
  # client that predates the build contract, and a legacy client that
  # declares nothing were indistinguishable, and the uniform "unknown" read as
  # an answer. `client_build_status` says which of the four a row is.
  #
  # The `claude_channel*.json` / `openclaw*.json` fixtures are the payloads the
  # two plugins ACTUALLY send, copied verbatim from their PRs (provenance in
  # test/support/fixtures/client_info/README.md) — so these tests assert the
  # round trip against the real client halves, not against a shape core
  # imagined for them.
  describe "client_build_status in federation_status (task 01a09e63)" do
    @client_info_fixtures Path.expand("../../support/fixtures/client_info", __DIR__)

    defp client_info_fixture(name) do
      @client_info_fixtures |> Path.join(name <> ".json") |> File.read!() |> Jason.decode!()
    end

    defp join_without_client_info(runtime, raw_token) do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => runtime.runtime_id,
          "token" => raw_token
        })

      {:ok, _reply, joined} = subscribe_and_join(socket, "runtime:#{runtime.runtime_id}", %{})
      joined
    end

    defp context_row(runtime_id),
      do: Enum.find(Federation.federation_status(), &(&1.runtime_id == runtime_id))

    defp tool_row(runtime_id) do
      {:ok, %{runtimes: runtimes}} = ToolSurface.execute("federation_status", %{}, %{})
      Enum.find(runtimes, &(&1.runtime_id == runtime_id))
    end

    test "NEGATIVE CONTROL: build / build_error / version-only / no client_info are four distinct statuses",
         ctx do
      {rt_unresolved, tok_unresolved} = register_second_runtime(ctx.user)
      {rt_precontract, tok_precontract} = register_second_runtime(ctx.user)
      {rt_legacy, tok_legacy} = register_second_runtime(ctx.user)

      reported = client_info_fixture("claude_channel")
      unresolved = client_info_fixture("openclaw_unresolved")

      join_with_client_info(ctx.runtime, ctx.raw_token, reported)
      join_with_client_info(rt_unresolved, tok_unresolved, unresolved)

      # A client that predates the contract: product + version, nothing else.
      join_with_client_info(rt_precontract, tok_precontract, %{
        "product" => "claude_channel",
        "version" => "0.3.0"
      })

      join_without_client_info(rt_legacy, tok_legacy)

      ids = %{
        reported: ctx.runtime.runtime_id,
        unresolved: rt_unresolved.runtime_id,
        precontract: rt_precontract.runtime_id,
        legacy: rt_legacy.runtime_id
      }

      expected = %{
        reported: "reported",
        unresolved: "unresolved",
        precontract: "not_reported",
        legacy: "no_client_info"
      }

      for {label, row_fun} <- [context: &context_row/1, tool: &tool_row/1] do
        rows = Map.new(ids, fn {k, id} -> {k, row_fun.(id)} end)

        statuses = Map.new(rows, fn {k, row} -> {k, row.client_build_status} end)
        assert statuses == expected, "#{label}: #{inspect(statuses)}"

        assert statuses |> Map.values() |> Enum.uniq() |> length() == 4,
               "#{label}: the four client kinds collapsed onto fewer statuses"

        assert rows.unresolved.client_build_error == unresolved["build_error"]
        assert rows.reported.client_build_error == nil
        assert rows.precontract.client_build_error == nil
        assert rows.legacy.client_build_error == nil
      end

      # The version-only runtime: never promoted to a build.
      assert context_row(ids.precontract).client_build == nil
      assert tool_row(ids.precontract).client_build == "unknown"
      refute tool_row(ids.precontract).client_build == "0.3.0"

      # Only the reporting runtime carries a sha.
      assert tool_row(ids.reported).client_build == reported["build"]

      for id <- [ids.unresolved, ids.precontract, ids.legacy] do
        assert tool_row(id).client_build == "unknown"
      end
    end

    for family <- ["claude_channel", "openclaw"] do
      @family family
      test "ROUND TRIP (#{family}): the tool row reports exactly the build and process start the plugin sent",
           ctx do
        sent = client_info_fixture(@family)
        assert sent["build"] =~ ~r/\A[0-9a-f]{40}\z/, "fixture is not the reported shape"

        join_with_client_info(ctx.runtime, ctx.raw_token, sent)

        row = tool_row(ctx.runtime.runtime_id)

        assert row.client_build == sent["build"]
        assert row.client_build_status == "reported"
        assert row.client_build_error == nil
        assert row.process_started_at == sent["started_at"]

        # A process start, not a connection time: the join just happened,
        # the plugin process started when the fixture was captured.
        assert row.online == true
        assert is_binary(row.connected_at)
        refute row.process_started_at == row.connected_at

        refute row.client_build == sent["version"]
      end

      test "ROUND TRIP (#{family} unresolved): the tool row carries the plugin's own reason",
           ctx do
        sent = client_info_fixture(@family <> "_unresolved")
        refute Map.has_key?(sent, "build"), "fixture is not the unresolved shape"

        join_with_client_info(ctx.runtime, ctx.raw_token, sent)

        row = tool_row(ctx.runtime.runtime_id)

        assert row.client_build == "unknown"
        assert row.client_build_status == "unresolved"
        assert row.client_build_error == sent["build_error"]
        assert row.process_started_at == sent["started_at"]
      end
    end

    test "rejoin with a build after an unresolved join flips to reported and clears the error; the reverse LOSES the sha",
         ctx do
      unresolved = client_info_fixture("claude_channel_unresolved")
      reported = client_info_fixture("claude_channel")

      join_with_client_info(ctx.runtime, ctx.raw_token, unresolved)
      assert context_row(ctx.runtime.runtime_id).client_build_status == "unresolved"

      join_with_client_info(ctx.runtime, ctx.raw_token, reported)
      row = context_row(ctx.runtime.runtime_id)
      assert row.client_build_status == "reported"
      assert row.client_build == reported["build"]
      assert row.client_build_error == nil

      reloaded = Repo.get(AgentRuntime, ctx.runtime.id)
      assert reloaded.metadata["client_info"]["build_error"] == nil

      # Replace-not-merge: a process that now says it cannot name its build
      # must not keep advertising the previous process's sha.
      join_with_client_info(ctx.runtime, ctx.raw_token, unresolved)
      row = context_row(ctx.runtime.runtime_id)
      assert row.client_build_status == "unresolved"
      assert row.client_build == nil
      assert row.client_build_error == unresolved["build_error"]
      assert tool_row(ctx.runtime.runtime_id).client_build == "unknown"
    end

    test "a non-binary or blank build_error degrades to nil without failing the join", ctx do
      for bad <- [42, %{"nested" => "map"}, ["list"], "", "   ", nil] do
        joined =
          join_with_client_info(ctx.runtime, ctx.raw_token, %{
            "product" => "claude_channel",
            "version" => "0.3.0",
            "build_error" => bad
          })

        assert joined.assigns.client_info.build_error == nil, "for #{inspect(bad)}"

        row = context_row(ctx.runtime.runtime_id)
        assert row.client_build_error == nil, "for #{inspect(bad)}"
        assert row.client_build_status == "not_reported", "for #{inspect(bad)}"
      end
    end

    test "an oversized build_error is bounded to 200 bytes at a UTF-8 boundary, not dropped",
         ctx do
      # Deliberately TRUNCATED, unlike an oversized build (rejected to nil):
      # a truncated reason is still true, while dropping it would demote an
      # honest "I tried and could not" to "predates the contract".
      # A one-byte prefix puts byte 200 in the MIDDLE of a two-byte "é", so a
      # plain binary_part would leave invalid UTF-8 (and fail the jsonb write).
      oversized = "x" <> String.duplicate("é", 500)

      joined =
        join_with_client_info(ctx.runtime, ctx.raw_token, %{
          "product" => "openclaw",
          "build_error" => oversized
        })

      kept = joined.assigns.client_info.build_error
      assert is_binary(kept)
      assert byte_size(kept) == 199
      assert String.valid?(kept)
      assert String.starts_with?(oversized, kept)

      row = context_row(ctx.runtime.runtime_id)
      assert row.client_build_status == "unresolved"
      assert row.client_build_error == kept
    end

    test "a build core rejects is reported as unresolved with core's reason, never as not_reported",
         ctx do
      join_with_client_info(ctx.runtime, ctx.raw_token, %{
        "product" => "claude_channel",
        "build" => String.duplicate("f", 65)
      })

      row = context_row(ctx.runtime.runtime_id)
      assert row.client_build == nil
      assert row.client_build_status == "unresolved"
      assert row.client_build_error =~ "core rejected client_info.build"
    end

    test "a reported build carries no build_error even if the client sent one", ctx do
      join_with_client_info(ctx.runtime, ctx.raw_token, %{
        "product" => "claude_channel",
        "build" => "85e499f47f579868afda64ec93ced00b28fe06ad",
        "build_error" => "stale reason"
      })

      row = context_row(ctx.runtime.runtime_id)
      assert row.client_build_status == "reported"
      assert row.client_build_error == nil
    end
  end

  # Task 01a06d01 stage 2: `proven` is an observation log, not a claim.
  #
  # The declared list (`client_info.features`) provably cannot do this job:
  # across `claude-code-suite-channel` `b238164e` -> `63229eb`, the commit
  # that ADDED the `meeting_transcript` listener, package.json `version`
  # stays `0.3.0` and `CLIENT_FEATURES` stays `["system_event_prompt"]`.
  # Two builds, one able to hear a meeting and one not, send a byte-identical
  # `client_info`. Only an inbound frame separates them.
  describe "inbound frames record capability proofs" do
    test "a reply frame proves chat_reply and leaves meeting_transcript ABSENT", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "reply", %{
        "space_id" => ctx.space.id,
        "content" => "Hello from external runtime!"
      })

      # Round-trip a frame the channel answers, so the earlier cast is done.
      ref = push(socket, "pong", %{})
      assert is_reference(ref)
      Process.sleep(50)

      proven = Platform.Federation.RuntimePresence.status(ctx.runtime.runtime_id).proven

      assert Map.has_key?(proven, "chat_reply")

      # THE discriminating assertion. Core broadcasts `meeting_transcript`
      # OUTBOUND and never hears back, so nothing about this runtime's
      # ability to receive one has been observed. Asserted as an explicit
      # absence, because the failure mode being guarded against is a proof
      # being recorded from a frame core SENT — which would look like a
      # working feature while reporting the opposite of the truth.
      refute Map.has_key?(proven, "meeting_transcript")
    end

    test "a meeting_say_ack proves meeting_voice, not the transcript path", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "meeting_say_ack", %{
        "utterance_id" => Platform.Types.UUIDv7.generate(),
        "room_name" => "space-test",
        "status" => "spoken"
      })

      Process.sleep(50)

      proven = Platform.Federation.RuntimePresence.status(ctx.runtime.runtime_id).proven

      assert Map.has_key?(proven, "meeting_voice")
      refute Map.has_key?(proven, "meeting_transcript")
      refute Map.has_key?(proven, "chat_reply")
    end

    test "a pong proves NOTHING — a heartbeat is a socket, not a capability", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      before = Platform.Federation.RuntimePresence.status(ctx.runtime.runtime_id)

      push(socket, "pong", %{})
      Process.sleep(50)

      after_pong = Platform.Federation.RuntimePresence.status(ctx.runtime.runtime_id)

      # Every connected runtime sends these. If a pong proved anything, every
      # cell would read green for every runtime forever and the column would
      # carry no information at all.
      assert after_pong.proven == before.proven
      assert after_pong.proven == %{}
      assert after_pong.connected_at == before.connected_at
    end

    test "a proof does not survive into a new session on the same runtime_id", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, joined_socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(joined_socket, "reply", %{"space_id" => ctx.space.id, "content" => "first session"})
      Process.sleep(50)

      assert Map.has_key?(
               Platform.Federation.RuntimePresence.status(ctx.runtime.runtime_id).proven,
               "chat_reply"
             )

      # Same shutdown dance as the `connected_at` re-join test above: `close/1`
      # exits with `{:shutdown, :closed}` over a link `subscribe_and_join`
      # created, and `terminate/2` must have finished untracking before the
      # second join, or the two race.
      Process.flag(:trap_exit, true)
      ref = Process.monitor(joined_socket.channel_pid)
      close(joined_socket)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000

      {:ok, rejoin} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, _rejoined} =
        subscribe_and_join(rejoin, "runtime:#{ctx.runtime.runtime_id}", %{})

      # The reconnecting process may be a different build entirely. What the
      # last one demonstrated is not evidence about this one.
      assert Platform.Federation.RuntimePresence.status(ctx.runtime.runtime_id).proven == %{}
    end

    # Task 01a06dfb stage 2 — the inbound frame that finally makes the
    # transcript path observable. Everything else core has about it is
    # either a claim by the runtime (`client_info.features`) or a frame
    # core itself sent (the broadcast). Only this ack is evidence.
    test "a meeting_transcript_ack proves meeting_transcript", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      # Nothing yet: the join alone must not have stamped anything.
      assert Platform.Federation.RuntimePresence.status(ctx.runtime.runtime_id).proven == %{}

      push(socket, "meeting_transcript_ack", %{
        "segment_id" => Platform.Types.UUIDv7.generate(),
        "room_name" => "space-test",
        "build" => "0.4.0"
      })

      Process.sleep(50)

      proven = Platform.Federation.RuntimePresence.status(ctx.runtime.runtime_id).proven

      assert Map.has_key?(proven, "meeting_transcript")

      # By key, not by "proven is non-empty": an assertion any non-empty map
      # satisfies does not distinguish this capability from another one, and
      # would pass on a handler that stamped the wrong string.
      refute Map.has_key?(proven, "meeting_voice")
      refute Map.has_key?(proven, "chat_reply")
    end

    # Named mutation "prove-on-join" (task 01a06dfb stage 2).
    #
    # The counterpart to the reconnect test above, checked at the FIRST
    # join rather than a re-join: a runtime that has connected and done
    # nothing else has proven nothing. Moving the new `prove/2` call into
    # `join/3` — or into the 30s `:presence_retrack` self-heal, which the
    # join schedules — turns the transcript cell green for every runtime
    # that can complete a handshake, which is exactly the declaration-shaped
    # signal `proven` exists to replace. This test is what goes red.
    test "a fresh join proves NOTHING before any ack is pushed", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      # Let the join's own work settle, so the absence below is a real
      # absence and not a read that merely won a race.
      Process.sleep(50)

      proven = Platform.Federation.RuntimePresence.status(ctx.runtime.runtime_id).proven

      assert proven == %{}
      refute Map.has_key?(proven, "meeting_transcript")
    end

    # Task 01a06f53. Until this test, `handle_in("meeting_say_ack", ...)`
    # called `prove/2` on ARRIVAL of the frame, before the payload was read
    # at all — so an ack whose own contents said the utterance failed
    # stamped `meeting_voice` as observed. Found live: three `meeting_say`
    # calls returned `no_ack`, `federation_status` reported `meeting_voice`
    # proven off the late acks, and the human in the room heard nothing at
    # any point.
    #
    # The inbound-frame reasoning is still sound; the conclusion drawn from
    # it was too strong. What a say-ack evidences unconditionally is "the
    # worker is connected and running the say-ack code path" — that is
    # liveness, and `touch/1` is what liveness is for. Only `status:
    # "spoken"` evidences that audio reached the room.
    test "a FAILED say-ack does not prove meeting_voice — it is liveness, not capability", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      before = Platform.Federation.RuntimePresence.status(ctx.runtime.runtime_id)

      # The join alone must not have stamped anything, or the absence below
      # would be inherited rather than earned.
      assert before.proven == %{}

      push(socket, "meeting_say_ack", %{
        "utterance_id" => Platform.Types.UUIDv7.generate(),
        "room_name" => "space-test",
        "status" => "failed",
        "error" => "not joined to the room"
      })

      Process.sleep(50)

      after_ack = Platform.Federation.RuntimePresence.status(ctx.runtime.runtime_id)

      refute Map.has_key?(after_ack.proven, "meeting_voice")
      assert after_ack.proven == %{}

      # The other half of the fix, and the reason this is not simply a
      # dropped `prove/2` call: a failed ack IS liveness evidence, so
      # `last_seen_at` must still advance and `connected_at` must not move.
      # A fix that deleted the presence write entirely would pass the two
      # assertions above and fail these.
      assert DateTime.compare(after_ack.last_seen_at, before.last_seen_at) == :gt
      assert after_ack.connected_at == before.connected_at
    end

    # Named mutation "default to spoken". `record_agent_say_ack/2` refuses to
    # default an absent status to its success token, for the same reason: the
    # success branch there posts text to chat. The proof must refuse it too,
    # so a worker that sends a bare receipt cannot turn the cell green.
    test "a say-ack with NO status does not prove meeting_voice", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "meeting_say_ack", %{
        "utterance_id" => Platform.Types.UUIDv7.generate(),
        "room_name" => "space-test"
      })

      Process.sleep(50)

      proven = Platform.Federation.RuntimePresence.status(ctx.runtime.runtime_id).proven

      refute Map.has_key?(proven, "meeting_voice")
      assert proven == %{}
    end

    # The discrimination, pinned by comparison rather than against a literal
    # (task 01a06f53's anti-vacuity clause). Two acks on two runtimes,
    # byte-identical but for `status` — including the same `utterance_id`, so
    # status really is the only difference. Neither id is in
    # `Platform.Meetings.SayRegistry`, so both are registry misses and
    # neither posts anything to chat; only the presence stamp differs.
    #
    # Asserting the failed case alone would pass just as well against a
    # handler that had stopped proving `meeting_voice` altogether. The
    # spoken half is what rules that out, and the maps are required to
    # DIFFER so the pair cannot both be satisfied by one behaviour.
    test "two acks identical but for status: only the spoken one proves meeting_voice", ctx do
      other = extra_runtime!(ctx.user)

      {:ok, spoken_socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, spoken_socket} =
        subscribe_and_join(spoken_socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      {:ok, failed_socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => other.runtime.runtime_id,
          "token" => other.raw_token
        })

      {:ok, _reply, failed_socket} =
        subscribe_and_join(failed_socket, "runtime:#{other.runtime.runtime_id}", %{})

      base = %{
        "utterance_id" => Platform.Types.UUIDv7.generate(),
        "room_name" => "space-test",
        "duration_s" => 1.5
      }

      push(spoken_socket, "meeting_say_ack", Map.put(base, "status", "spoken"))
      push(failed_socket, "meeting_say_ack", Map.put(base, "status", "failed"))

      Process.sleep(50)

      spoken_proven =
        Platform.Federation.RuntimePresence.status(ctx.runtime.runtime_id).proven

      failed_proven =
        Platform.Federation.RuntimePresence.status(other.runtime.runtime_id).proven

      assert Map.has_key?(spoken_proven, "meeting_voice")
      refute Map.has_key?(failed_proven, "meeting_voice")
      refute spoken_proven == failed_proven

      # Both runtimes are online and were seen just now. The difference is
      # confined to the capability map; the failed ack is not a lesser
      # connection.
      assert Platform.Federation.RuntimePresence.online?(other.runtime.runtime_id)
    end
  end

  describe "reply message" do
    test "posts to space as agent", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "reply", %{
        "space_id" => ctx.space.id,
        "content" => "Hello from external runtime!"
      })

      # Give it time to process
      Process.sleep(100)

      # Verify message was posted
      messages = Chat.list_messages(ctx.space.id, limit: 10)
      assert Enum.any?(messages, fn m -> m.content == "Hello from external runtime!" end)
    end

    # The positive control for the two refusal tests below. Without it a
    # handler that refused EVERY frame would pass both of them.
    test "a permitted reply replies :ok with the persisted message id", ctx do
      socket = joined_socket(ctx)

      ref = push(socket, "reply", %{"space_id" => ctx.space.id, "content" => "Authorized"})

      assert_reply ref, :ok, %{message_id: message_id, space_id: space_id}
      assert space_id == ctx.space.id

      # The id is not merely well-formed — the row is in the database.
      message = Repo.get!(Chat.Message, message_id)
      assert message.content == "Authorized"
      assert message.space_id == ctx.space.id
    end

    test "an unknown space_id is refused on the push ref, naming the id", ctx do
      socket = joined_socket(ctx)
      unknown_space_id = Ecto.UUID.generate()

      ref = push(socket, "reply", %{"space_id" => unknown_space_id, "content" => "x"})

      assert_reply ref, :error, %{error: error, recoverable: false}
      assert error =~ unknown_space_id
      assert error == "Access denied: agent is not a participant in space #{unknown_space_id}"

      # The out-of-band event still fires for older bridges.
      assert_push "error", %{error: ^error}
    end

    test "an existing space with no participant row is refused identically", ctx do
      socket = joined_socket(ctx)

      other_space =
        create_space(%{name: "Other", slug: "other-#{System.unique_integer([:positive])}"})

      ref = push(socket, "reply", %{"space_id" => other_space.id, "content" => "x"})

      assert_reply ref, :error, %{error: error, recoverable: false}

      # Byte-identical to the unknown-space wording modulo the id: the two
      # cases must not be distinguishable by the caller.
      assert error == "Access denied: agent is not a participant in space #{other_space.id}"

      unknown_space_id = Ecto.UUID.generate()

      assert String.replace(error, other_space.id, unknown_space_id) ==
               "Access denied: agent is not a participant in space #{unknown_space_id}"

      refute Enum.any?(Chat.list_messages(other_space.id, limit: 10), &(&1.content == "x"))
    end

    # Task 01a1655c stage 2: `attachment_ids` links already-uploaded rows.
    defp ready_upload!(ctx, content_type \\ "video/mp4") do
      bytes = :crypto.strong_rand_bytes(128)
      hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

      {:ok, started} =
        Platform.Chat.Attachments.ToolHandlers.upload_start(
          %{
            "space_id" => ctx.space.id,
            "filename" => "clip.mp4",
            "content_type" => content_type,
            "byte_size" => byte_size(bytes)
          },
          %{
            space_id: ctx.space.id,
            agent_id: ctx.agent.id,
            agent_participant_id: ctx.agent_participant.id
          }
        )

      pending = Repo.get!(Chat.Attachment, started.id)

      {:ok, _} =
        Platform.Chat.AttachmentStorage.Adapter.LocalDisk.persist(
          pending.storage_key,
          {:binary, bytes}
        )

      {:ok, finalized} =
        Platform.Chat.Attachments.ToolHandlers.finalize_pending(started.id, %{
          byte_size: byte_size(bytes),
          content_hash: hash
        })

      finalized.id
    end

    test "a reply with attachment_ids links the uploaded row to the posted message", ctx do
      socket = joined_socket(ctx)
      attachment_id = ready_upload!(ctx)

      ref =
        push(socket, "reply", %{
          "space_id" => ctx.space.id,
          "content" => "the clip",
          "attachment_ids" => [attachment_id]
        })

      assert_reply ref, :ok, %{message_id: message_id, space_id: space_id}
      assert space_id == ctx.space.id

      message = Repo.get!(Chat.Message, message_id)
      assert message.content == "the clip"
      assert message.metadata["source"] == "external_runtime"
      assert message.metadata["runtime_id"] == ctx.runtime.runtime_id
      assert message.metadata["attachments_linked_by_id"] == true

      assert [%{id: ^attachment_id}] = Chat.list_attachments(message_id)
    end

    test "a reply without attachment_ids, or with an empty list, posts a plain message as before",
         ctx do
      socket = joined_socket(ctx)
      attachment_id = ready_upload!(ctx)

      for {params, content} <- [
            {%{}, "no ids"},
            {%{"attachment_ids" => []}, "empty ids"}
          ] do
        ref =
          push(
            socket,
            "reply",
            Map.merge(%{"space_id" => ctx.space.id, "content" => content}, params)
          )

        assert_reply ref, :ok, %{message_id: message_id}

        message = Repo.get!(Chat.Message, message_id)
        assert message.content == content
        refute Map.has_key?(message.metadata, "attachments_linked_by_id")
        assert Chat.list_attachments(message_id) == []
      end

      assert is_nil(Repo.get!(Chat.Attachment, attachment_id).message_id)
    end

    test "a reply with attachment_ids checks the runtime's scope: a chat.read deny answers not_found",
         ctx do
      socket = joined_socket(ctx)
      attachment_id = ready_upload!(ctx)

      {:ok, _} =
        Platform.Access.Grants.deny(%{
          principal: {:agent, ctx.agent.id},
          permission: "chat.read",
          resource: {:space, ctx.space.id}
        })

      ref =
        push(socket, "reply", %{
          "space_id" => ctx.space.id,
          "content" => "denied",
          "attachment_ids" => [attachment_id]
        })

      assert_reply ref, :error, %{code: "attachment_not_found", recoverable: true}
      assert is_nil(Repo.get!(Chat.Attachment, attachment_id).message_id)
      refute Enum.any?(Chat.list_messages(ctx.space.id, limit: 10), &(&1.content == "denied"))
    end

    test "a reply naming a pending or unknown attachment id is refused recoverably, posting nothing",
         ctx do
      socket = joined_socket(ctx)

      {:ok, started} =
        Platform.Chat.Attachments.ToolHandlers.upload_start(
          %{
            "space_id" => ctx.space.id,
            "filename" => "clip.mp4",
            "content_type" => "video/mp4",
            "byte_size" => 10
          },
          %{
            space_id: ctx.space.id,
            agent_id: ctx.agent.id,
            agent_participant_id: ctx.agent_participant.id
          }
        )

      before = length(Chat.list_messages(ctx.space.id, limit: 50))

      ref =
        push(socket, "reply", %{
          "space_id" => ctx.space.id,
          "content" => "x",
          "attachment_ids" => [started.id]
        })

      assert_reply ref, :error, %{code: "attachment_not_ready", recoverable: true, error: error}
      assert error =~ "finish the presigned POST first"

      ref =
        push(socket, "reply", %{
          "space_id" => ctx.space.id,
          "content" => "x",
          "attachment_ids" => [Ecto.UUID.generate()]
        })

      assert_reply ref, :error, %{code: "attachment_not_found", recoverable: true}

      assert length(Chat.list_messages(ctx.space.id, limit: 50)) == before
    end
  end

  # The wire half of task 019ff292 stage 2. The queue-side anchoring is
  # covered in `Platform.Meetings.IntentQueue.AckWindowMarginTest`; what
  # is only reachable here is that a runtime saying "I have surfaced
  # this to my agent" actually lands on the row. Delete the
  # `handle_in("intent_delivered", ...)` clause and this fails on
  # `delivered_at` still being nil — the catch-all `handle_in/3` would
  # otherwise swallow the event and look exactly like success.
  describe "intent_delivered receipt" do
    test "a runtime's receipt anchors the responder's window on the queue row", ctx do
      meeting_id = Platform.Types.UUIDv7.generate()

      # Long windows: this test is about the receipt landing, not about
      # anything expiring underneath it.
      {:ok, _pid} = IntentQueue.ensure_started(meeting_id, ack_timeout_ms: 60_000)
      on_exit(fn -> IntentQueue.stop(meeting_id) end)

      {:ok, row} =
        IntentQueue.enqueue(meeting_id, %{
          classified_intent: "open_question",
          target_role: "engineering",
          chunk_excerpt: "who is picking up the billing bug?",
          dedupe_key: "dk-#{System.unique_integer([:positive])}"
        })

      {:ok, _} = IntentQueue.claim_next(meeting_id)
      {:ok, dispatched} = IntentQueue.transition(meeting_id, row.id, :dispatched)
      assert is_nil(dispatched.delivered_at)

      :ok = Platform.Meetings.PubSub.subscribe_intents(meeting_id)

      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "intent_delivered", %{"intent_id" => row.id})

      intent_id = row.id
      assert_receive {:intent_delivered, %{id: ^intent_id} = delivered}, 2_000
      assert %DateTime{} = delivered.delivered_at

      # First contact is not acceptance. The row is still waiting on an
      # `intent_ack` to say what the responder is doing about it.
      assert delivered.status == :dispatched
      assert IntentQueue.cursor(meeting_id) == intent_id
    end

    test "a receipt for an intent id nobody owns is ignored, not a crash", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "intent_delivered", %{"intent_id" => Platform.Types.UUIDv7.generate()})

      # The channel has to survive it: an intent whose meeting ended
      # between dispatch and receipt is routine, not exceptional.
      ref = push(socket, "pong", %{})
      assert is_reference(ref)
      assert Process.alive?(socket.channel_pid)
    end
  end

  # Task 01a06686 stage 2: a `meeting_join` is now routed to the agent's
  # VOICE runtime row, so the ack comes back over that row's socket. The
  # handler reads `socket.assigns.agent_id`, which `RuntimeSocket.connect/3`
  # sets from `runtime.agent_id` — and `register_voice_runtime/3` binds the
  # voice row by `agent_id` — so the receipt lands on the agent, not on the
  # row. This pins that: a voice-row socket's failing ack reaches the room
  # topic naming the agent, exactly as the brain's would.
  describe "meeting_join_ack from a voice runtime row" do
    test "is attributed to the agent the voice row belongs to", ctx do
      {:ok, voice, voice_token} = Federation.register_voice_runtime(ctx.user.id, ctx.agent)
      assert voice.id != ctx.runtime.id
      assert voice.agent_id == ctx.agent.id

      {:ok, room} = Platform.Meetings.ensure_room(ctx.space.id)
      {:ok, room} = Platform.Meetings.activate_room(room)
      :ok = Platform.Meetings.PubSub.subscribe_room(room.id)

      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => voice.runtime_id,
          "token" => voice_token
        })

      assert socket.assigns.agent_id == ctx.agent.id

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{voice.runtime_id}", %{
          "client_info" => %{"product" => "openclaw", "features" => ["meeting_voice"]}
        })

      push(socket, "meeting_join_ack", %{
        "room_name" => room.livekit_room_name,
        "status" => "error"
      })

      assert_receive {:agent_join_failed, info}, 2_000
      assert info.agent_id == ctx.agent.id
      assert info.agent_name == ctx.agent.name
      assert info.room_name == room.livekit_room_name
      assert info.status == "error"
    end
  end

  describe "meeting_say_ack receipt" do
    # The ack is a receipt for `Meetings.say/4`'s rendezvous: whoever is
    # waiting on `"meetings:say:<utterance_id>"` must hear it, in the
    # `{:meeting_say_ack, id, %{status: _}}` shape `say/4` receives on.
    test "is relayed to the utterance's ack topic with the runtime's agent", ctx do
      utterance_id = Platform.Types.UUIDv7.generate()
      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, "meetings:say:#{utterance_id}")

      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "meeting_say_ack", %{
        "utterance_id" => utterance_id,
        "room_name" => "space-test",
        "status" => "spoken",
        "duration_s" => 2.5
      })

      assert_receive {:meeting_say_ack, ^utterance_id,
                      %{status: "spoken", duration_s: 2.5, room_name: "space-test"}},
                     2_000
    end

    test "an ack with no utterance_id is ignored, not a crash", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "meeting_say_ack", %{"status" => "spoken"})

      ref = push(socket, "pong", %{})
      assert is_reference(ref)
      assert Process.alive?(socket.channel_pid)
    end
  end

  describe "execution_event" do
    test "records runtime execution events and acknowledges them", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      {:ok, project} = Tasks.create_project(%{name: "Runtime channel project"})
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Runtime channel task"})
      {:ok, space} = ExecutionSpace.find_or_create(task.id)

      push(socket, "execution_event", %{
        "task_id" => task.id,
        "phase" => "execution",
        "event_type" => "execution.started",
        "execution_space_id" => space.id,
        "idempotency_key" => "runtime-channel-started-#{task.id}"
      })

      assert_receive %Phoenix.Socket.Message{
        event: "execution_event_ack",
        payload: %{idempotency_key: _, status: "ok"}
      }

      lease = Platform.Orchestration.current_lease_for_task(task.id)
      assert lease.runtime_id == ctx.runtime.runtime_id
      assert lease.status == "active"

      messages = ExecutionSpace.list_messages_with_participants(space.id)
      assert Enum.any?(messages, &String.contains?(&1.content, "started execution"))
    end
  end

  describe "usage_event" do
    # Regression: a runtime sent `space_id: "higgins"` (a slug). Ecto's
    # `cast/4` waves non-UUID binaries through for `:binary_id`, so the
    # failure surfaced as a raised Ecto.ChangeError inside `Repo.insert` —
    # not the `{:error, changeset}` this handler expects — and the channel
    # process died. Observed live against `alex-home-openclaw`.
    test "a non-UUID space_id does not crash the channel and still records the event", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      # `level: :warning` drops anything below warning, so a Logger.debug or
      # Logger.info here would produce an empty capture — this asserts the
      # SEVERITY, not just the text, without depending on the log format.
      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          push(socket, "usage_event", %{
            "space_id" => "higgins",
            "model" => "anthropic/claude-sonnet-4-6",
            "provider" => "anthropic",
            "session_key" => "sess-slug-space-id",
            "input_tokens" => 120,
            "output_tokens" => 34
          })

          # A synchronous call into the channel process: it both flushes the
          # async push above and proves the process is still answering. If
          # the usage_event killed the channel, this exits.
          :sys.get_state(socket.channel_pid)
        end)

      assert Process.alive?(socket.channel_pid)

      # The client bug must be loud, not swallowed.
      assert log =~ "usage_event"
      assert log =~ "higgins"
      assert log =~ ctx.runtime.runtime_id

      # The cost record survives — that is the whole point of the table.
      event =
        Platform.Repo.one!(
          from(e in Platform.Analytics.UsageEvent,
            where: e.session_key == "sess-slug-space-id"
          )
        )

      assert event.space_id == nil
      assert event.model == "anthropic/claude-sonnet-4-6"
      assert event.provider == "anthropic"
      assert event.total_tokens == 154
      # agent_id is enriched from the socket and is a real UUID — untouched.
      assert event.agent_id == ctx.agent.id
    end

    test "a valid UUID space_id is preserved", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "usage_event", %{
        "space_id" => ctx.space.id,
        "model" => "anthropic/claude-sonnet-4-6",
        "provider" => "anthropic",
        "session_key" => "sess-valid-space-id",
        "input_tokens" => 10,
        "output_tokens" => 5
      })

      # Synchronous call into the channel: flushes the async push above.
      :sys.get_state(socket.channel_pid)

      event =
        Platform.Repo.one!(
          from(e in Platform.Analytics.UsageEvent,
            where: e.session_key == "sess-valid-space-id"
          )
        )

      assert event.space_id == ctx.space.id
    end
  end

  describe "reply_with_media" do
    test "posts message with base64 attachments", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      # Create a small test PNG (1x1 pixel)
      png_data = Base.encode64("fake-image-data-for-test")

      push(socket, "reply_with_media", %{
        "space_id" => ctx.space.id,
        "content" => "Here is the diagram",
        "attachments" => [
          %{
            "filename" => "diagram.png",
            "content_type" => "image/png",
            "data" => png_data
          }
        ]
      })

      Process.sleep(200)

      messages = Chat.list_messages(ctx.space.id, limit: 10)
      msg = Enum.find(messages, fn m -> m.content == "Here is the diagram" end)
      assert msg
      assert msg.metadata["has_media"] == true

      attachments = Chat.list_attachments(msg.id)
      assert length(attachments) == 1
      assert hd(attachments).filename == "diagram.png"
      assert hd(attachments).content_type == "image/png"
    end

    test "posts message with multiple attachments", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "reply_with_media", %{
        "space_id" => ctx.space.id,
        "content" => "Two files attached",
        "attachments" => [
          %{
            "filename" => "file1.txt",
            "content_type" => "text/plain",
            "data" => Base.encode64("hello")
          },
          %{
            "filename" => "file2.txt",
            "content_type" => "text/plain",
            "data" => Base.encode64("world")
          }
        ]
      })

      Process.sleep(200)

      messages = Chat.list_messages(ctx.space.id, limit: 10)
      msg = Enum.find(messages, fn m -> m.content == "Two files attached" end)
      assert msg

      attachments = Chat.list_attachments(msg.id)
      assert length(attachments) == 2
    end

    test "rejects oversized attachments", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      # Create data that exceeds 10MB when decoded
      # 10MB * 4/3 for base64 ≈ 13.3MB of base64 text
      large_data = String.duplicate("A", 14_000_000)

      push(socket, "reply_with_media", %{
        "space_id" => ctx.space.id,
        "content" => "Too big",
        "attachments" => [
          %{
            "filename" => "huge.bin",
            "content_type" => "application/octet-stream",
            "data" => large_data
          }
        ]
      })

      assert_push "error", %{error: error}
      assert error =~ "size limits exceeded"
    end

    # Positive control for the two refusal tests below: without it, a handler
    # that refused EVERY reply_with_media frame would pass both of them.
    test "a permitted reply_with_media replies :ok with the persisted message id", ctx do
      socket = joined_socket(ctx)

      ref =
        push(socket, "reply_with_media", %{
          "space_id" => ctx.space.id,
          "content" => "Authorized media",
          "attachments" => [
            %{
              "filename" => "ok.txt",
              "content_type" => "text/plain",
              "data" => Base.encode64("hello")
            }
          ]
        })

      assert_reply ref, :ok, %{message_id: message_id, space_id: space_id}, 2000
      assert space_id == ctx.space.id

      message = Repo.get!(Chat.Message, message_id)
      assert message.content == "Authorized media"
      assert message.metadata["has_media"] == true
      assert [attachment] = Chat.list_attachments(message.id)
      assert attachment.filename == "ok.txt"
    end

    test "an existing space with no participant row is refused on the push ref", ctx do
      socket = joined_socket(ctx)

      other_space =
        create_space(%{name: "Other", slug: "other-#{System.unique_integer([:positive])}"})

      ref =
        push(socket, "reply_with_media", %{
          "space_id" => other_space.id,
          "content" => "Unauthorized",
          "attachments" => []
        })

      assert_reply ref, :error, %{error: error, recoverable: false}
      assert error == "Access denied: agent is not a participant in space #{other_space.id}"
      assert_push "error", %{error: ^error}

      refute Enum.any?(
               Chat.list_messages(other_space.id, limit: 10),
               &(&1.content == "Unauthorized")
             )
    end

    # MEASURED against a mutant that restores the pre-fix shape (the frame
    # calling a helper that returns `{:ok, get_agent_participant_id(...)}`,
    # nil and all, on 2026-09-16): this test DOES die, but not the way the
    # unguarded-handler story predicts. It dies on the exact-string compare
    # with left: "Failed to post message: #Ecto.Changeset<... errors:
    # [participant_id: {"can't be blank", ...}]>" — the Message changeset's
    # required-participant validation rejects the insert BEFORE the
    # `chat_messages_space_id_fkey` FK is ever reached, so no
    # Ecto.ConstraintError occurs here.
    #
    # The exact-equality assertion (not a `=~`) is what makes that
    # discriminating: a crash-shaped error string is visibly not a refusal.
    # The no-participant-row case above remains the stronger fixture because
    # it also asserts nothing was persisted.
    test "an unknown space_id is refused, naming the id", ctx do
      socket = joined_socket(ctx)
      unknown_space_id = Ecto.UUID.generate()

      ref =
        push(socket, "reply_with_media", %{
          "space_id" => unknown_space_id,
          "content" => "x",
          "attachments" => []
        })

      assert_reply ref, :error, %{error: error, recoverable: false}
      assert error =~ unknown_space_id
      assert error == "Access denied: agent is not a participant in space #{unknown_space_id}"
    end

    # The size-limit branch lives strictly inside the authorized arm, so an
    # unauthorized caller learns nothing about its own payload. An oversized
    # attachment aimed at a space the agent cannot write gets the ACCESS
    # wording, never the size wording.
    test "an unauthorized oversized payload is refused for access, not for size", ctx do
      socket = joined_socket(ctx)

      other_space =
        create_space(%{name: "Other", slug: "other-#{System.unique_integer([:positive])}"})

      ref =
        push(socket, "reply_with_media", %{
          "space_id" => other_space.id,
          "content" => "Too big and unauthorized",
          "attachments" => [
            %{
              "filename" => "huge.bin",
              "content_type" => "application/octet-stream",
              "data" => String.duplicate("A", 14_000_000)
            }
          ]
        })

      assert_reply ref, :error, %{error: error}, 2000
      assert error == "Access denied: agent is not a participant in space #{other_space.id}"
      refute error =~ "size limits exceeded"
    end
  end

  describe "reply_chunk authorization" do
    # Positive control: a chunk into a space the agent participates in is
    # acked AND actually broadcast.
    test "a permitted chunk replies :ok and broadcasts", ctx do
      socket = joined_socket(ctx)
      Platform.Chat.PubSub.subscribe(ctx.space.id)

      ref =
        push(socket, "reply_chunk", %{
          "space_id" => ctx.space.id,
          "chunk_id" => "c1",
          "text" => "partial",
          "done" => false
        })

      assert_reply ref, :ok
      assert_receive {:agent_reply_chunk, %{chunk_id: "c1", text: "partial", done: false}}, 1000
    end

    test "an existing space with no participant row is refused on the push ref", ctx do
      socket = joined_socket(ctx)

      other_space =
        create_space(%{name: "Other", slug: "other-#{System.unique_integer([:positive])}"})

      Platform.Chat.PubSub.subscribe(other_space.id)

      ref =
        push(socket, "reply_chunk", %{
          "space_id" => other_space.id,
          "chunk_id" => "c2",
          "text" => "partial",
          "done" => false
        })

      assert_reply ref, :error, %{error: error, recoverable: false}
      assert error == "Access denied: agent is not a participant in space #{other_space.id}"
      assert_push "error", %{error: ^error}
      refute_receive {:agent_reply_chunk, _}, 200
    end

    # Pins the id in the wording. Its mutation signal is WEAK and is recorded
    # as such: under the pre-fix mutant it dies as "no matching message after
    # 100ms" on the assert_reply, which is what a handler that simply never
    # answers looks like too. It cannot tell "refused" from "silent". The
    # no-participant-row case above is the discriminating fixture — it also
    # asserts the broadcast did NOT go out.
    test "an unknown space_id is refused, naming the id", ctx do
      socket = joined_socket(ctx)
      unknown_space_id = Ecto.UUID.generate()

      ref =
        push(socket, "reply_chunk", %{
          "space_id" => unknown_space_id,
          "chunk_id" => "c3",
          "text" => "partial",
          "done" => true
        })

      assert_reply ref, :error, %{error: error, recoverable: false}
      assert error =~ unknown_space_id
      assert error == "Access denied: agent is not a participant in space #{unknown_space_id}"
    end
  end

  describe "typing authorization" do
    test "a permitted typing frame replies :ok and broadcasts", ctx do
      socket = joined_socket(ctx)
      Platform.Chat.PubSub.subscribe(ctx.space.id)

      ref = push(socket, "typing", %{"space_id" => ctx.space.id, "typing" => true})

      assert_reply ref, :ok
      assert_receive {:agent_typing, %{typing: true}}, 1000
    end

    test "an existing space with no participant row is refused on the push ref", ctx do
      socket = joined_socket(ctx)

      other_space =
        create_space(%{name: "Other", slug: "other-#{System.unique_integer([:positive])}"})

      Platform.Chat.PubSub.subscribe(other_space.id)

      ref = push(socket, "typing", %{"space_id" => other_space.id, "typing" => true})

      assert_reply ref, :error, %{error: error, recoverable: false}
      assert error == "Access denied: agent is not a participant in space #{other_space.id}"
      assert_push "error", %{error: ^error}
      refute_receive {:agent_typing, _}, 200
    end

    # Same weak signal as reply_chunk's: under the pre-fix mutant this dies on
    # "no matching message after 100ms", indistinguishable from a handler that
    # never replies. The no-participant-row case above is what discriminates.
    test "an unknown space_id is refused, naming the id", ctx do
      socket = joined_socket(ctx)
      unknown_space_id = Ecto.UUID.generate()

      ref = push(socket, "typing", %{"space_id" => unknown_space_id, "typing" => true})

      assert_reply ref, :error, %{error: error, recoverable: false}
      assert error =~ unknown_space_id
      assert error == "Access denied: agent is not a participant in space #{unknown_space_id}"
    end
  end

  # Task 01a0ac54 stage 2. One foreign space, two transports' write paths: the
  # runtime `reply` frame (`authorize_space_write/2`) and the `send_media` tool
  # (`ToolSurface.execute/3`). Both build their refusal with
  # `ToolSurface.space_write_denied/1`. Parity alone would still pass if that
  # builder's text changed, so each string is also pinned to the literal.
  describe "space write refusal parity across reply and send_media" do
    test "a foreign space is refused with one byte-identical string on both paths", ctx do
      socket = joined_socket(ctx)

      foreign =
        create_space(%{name: "Foreign", slug: "foreign-#{System.unique_integer([:positive])}"})

      literal = "Access denied: agent is not a participant in space #{foreign.id}"

      ref = push(socket, "reply", %{"space_id" => foreign.id, "content" => "x"})
      assert_reply ref, :error, %{error: reply_error, recoverable: reply_recoverable}

      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "runtime-send-media-#{System.unique_integer([:positive])}.txt"
        )

      File.write!(tmp_path, "hello world")
      on_exit(fn -> File.rm(tmp_path) end)

      push(socket, "tool_call", %{
        "call_id" => "call-send-media-foreign",
        "tool" => "send_media",
        "args" => %{"space_id" => foreign.id, "file_path" => tmp_path, "content" => "x"}
      })

      assert_push "tool_result", %{
        call_id: "call-send-media-foreign",
        status: "error",
        error: media_error
      }

      assert reply_error == media_error.error
      assert reply_error == literal
      assert media_error.error == literal
      assert reply_recoverable == false
      assert media_error.recoverable == false

      assert Chat.list_messages(foreign.id, limit: 10) == []
    end
  end

  describe "tool_call" do
    test "executes tool and returns result", ctx do
      # `canvas` is NOT in AgentRuntime.default_tool_profile/0, and
      # `tool_call` is now gated on the same authorization path as /mcp, so
      # the grant has to be explicit. Fixing the fixture rather than widening
      # the default grant is the point of the change.
      {:ok, _granted} = set_runtime_profile(ctx.runtime, ["canvas"])

      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      document = %{
        "version" => 1,
        "revision" => 1,
        "root" => %{
          "id" => "root",
          "type" => "stack",
          "props" => %{"gap" => 12},
          "children" => [
            %{
              "id" => "t",
              "type" => "table",
              "props" => %{
                "columns" => ["Name"],
                "rows" => [%{"Name" => "One"}]
              },
              "children" => []
            }
          ]
        },
        "theme" => %{},
        "bindings" => %{},
        "meta" => %{}
      }

      push(socket, "tool_call", %{
        "call_id" => "call-1",
        "tool" => "canvas_create",
        "args" => %{
          "space_id" => ctx.space.id,
          "title" => "Runtime Canvas",
          "document" => document
        }
      })

      assert_push "tool_result", %{call_id: "call-1", status: "ok", result: result}
      assert result.kind == "stack"
      assert result.title == "Runtime Canvas"
    end

    test "task kind round-trips through the RuntimeChannel transport", ctx do
      {:ok, _granted} = set_runtime_profile(ctx.runtime, ["task"])
      project = create_project()
      socket = joined_socket(ctx)

      push(socket, "tool_call", %{
        "call_id" => "call-kind-create",
        "tool" => "task_create",
        "args" => %{
          "project_id" => project.id,
          "title" => "Runtime kind",
          "kind" => "chore"
        }
      })

      assert_push "tool_result", %{
        call_id: "call-kind-create",
        status: "ok",
        result: created
      }

      assert created.kind == "chore"

      push(socket, "tool_call", %{
        "call_id" => "call-kind-update",
        "tool" => "task_update",
        "args" => %{"task_id" => created.id, "kind" => "ops"}
      })

      assert_push "tool_result", %{
        call_id: "call-kind-update",
        status: "ok",
        result: updated
      }

      assert updated.kind == "ops"
      assert Tasks.get_task_record(created.id).kind == "ops"
    end

    # Task 01a0fcfa. `attachment_get_inline` marks an eligible image for an
    # MCP image block; that marker is `/mcp`-only. Over this socket the result
    # must be the handler's map without it, `data_base64` intact.
    test "attachment_get_inline on a PNG pushes data_base64 without the image marker", ctx do
      png =
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII="
        )

      storage_key = "chat/test/rt-png-#{Ecto.UUID.generate()}.png"
      target = Path.join(Application.fetch_env!(:platform, :chat_attachments_root), storage_key)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, png)

      {:ok, attachment} =
        Chat.create_attachment(%{
          space_id: ctx.space.id,
          filename: "dot.png",
          content_type: "image/png",
          byte_size: byte_size(png),
          storage_key: storage_key,
          state: "ready"
        })

      # Guard that the strip below has something to strip: the in-process
      # handler result DOES carry the marker for these bytes.
      {:ok, in_process} =
        ToolSurface.execute(
          "attachment_get_inline",
          %{"attachment_id" => attachment.id},
          %{agent_id: ctx.agent.id, agent_participant_id: ctx.agent_participant.id}
        )

      assert Map.has_key?(in_process, Platform.Federation.McpContent.marker_key())

      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "tool_call", %{
        "call_id" => "call-png",
        "tool" => "attachment_get_inline",
        "args" => %{"attachment_id" => attachment.id}
      })

      assert_push "tool_result", %{call_id: "call-png", status: "ok", result: result}

      assert result == %{
               content_type: "image/png",
               byte_size: byte_size(png),
               data_base64: Base.encode64(png),
               filename: "dot.png"
             }

      refute Map.has_key?(result, :__mcp_image__)
    end

    # The vulnerability this task closes: before the gate, the channel
    # executed anything it was asked to, so `tool_profile` was advisory
    # over WebSocket and a default-grant runtime could create tasks.
    test "denies a tool outside the runtime's granted bundles, before executing it", ctx do
      project = create_project()
      before_count = Repo.aggregate(Tasks.Task, :count)

      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      # `task` is not in the default grant. These args are otherwise valid —
      # the tool would have created a real row if it had been executed.
      push(socket, "tool_call", %{
        "call_id" => "call-denied",
        "tool" => "task_create",
        "args" => %{"project_id" => project.id, "title" => "should never exist"}
      })

      assert_push "tool_result", %{call_id: "call-denied", status: "error", error: error}

      # Shape matters: openclaw-suite-channel rejects with
      # `payload.error?.error`, so the message must be a string at error.error.
      assert error.error ==
               "tool 'task_create' requires permission 'tasks.write', which this agent does not hold or is capped at its owner"

      assert error.code == "forbidden"

      assert Repo.aggregate(Tasks.Task, :count) == before_count
      assert Repo.get_by(Tasks.Task, title: "should never exist") == nil
    end

    test "emits tool_call_denied telemetry on a refusal", ctx do
      handler_id = "tool-call-denied-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:platform, :federation, :tool_call_denied],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:tool_call_denied, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "tool_call", %{
        "call_id" => "call-telemetry",
        "tool" => "memory_delete",
        "args" => %{}
      })

      assert_receive {:tool_call_denied, measurements, metadata}
      assert is_integer(measurements.system_time)
      assert metadata.runtime_id == ctx.runtime.runtime_id
      assert metadata.tool == "memory_delete"
      assert metadata.reason == :forbidden
    end

    # The reason the gate re-reads the row per call instead of reusing the
    # join-time `:runtime` assign: openclaw sockets stay joined for days, so
    # a Control Center revocation has to bite on a LIVE socket rather than at
    # next reconnect.
    test "a bundle revoked mid-connection takes effect without a rejoin", ctx do
      {:ok, _granted} = set_runtime_profile(ctx.runtime, ["task"])

      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "tool_call", %{
        "call_id" => "call-before",
        "tool" => "task_list",
        "args" => %{}
      })

      assert_push "tool_result", %{call_id: "call-before", status: "ok"}

      # Revoke everything WITHOUT touching the socket — no rejoin, no
      # reconnect, same channel process.
      runtime = Federation.get_runtime(ctx.runtime.id)
      {:ok, _revoked} = set_runtime_profile(runtime, [])

      push(socket, "tool_call", %{
        "call_id" => "call-after",
        "tool" => "task_list",
        "args" => %{}
      })

      assert_push "tool_result", %{call_id: "call-after", status: "error", error: error}

      assert error.error ==
               "tool 'task_list' requires permission 'tasks.read', which this agent does not hold or is capped at its owner"

      assert error.code == "forbidden"
    end

    test "denies when the runtime row vanished after connect", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      Repo.delete!(ctx.runtime)

      push(socket, "tool_call", %{
        "call_id" => "call-gone",
        "tool" => "space_list",
        "args" => %{}
      })

      assert_push "tool_result", %{call_id: "call-gone", status: "error", error: error}

      assert error.error ==
               "tool 'space_list' requires permission 'chat.read', which this agent does not hold or is capped at its owner"

      assert error.code == "forbidden"
    end
  end

  # Task 01a089c8: the channel used to say `not in allowed bundles` for two
  # unrelated conditions — a real tool this runtime just lacks the grant
  # for, and a name absent from the catalogue entirely (typo, or the
  # dots-vs-underscores mismatch between `plan_update` and `plan.update`).
  # The default grant excludes the `plan` bundle, so `plan_update` here is
  # the real-but-ungranted case and `plan.update` is the undeclared one.
  describe "tool_call denial message distinguishes unknown-tool from missing-grant" do
    test "an undeclared name (separator mismatch) gets the unknown-tool message with a suggestion",
         ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "tool_call", %{
        "call_id" => "call-unknown",
        "tool" => "plan.update",
        "args" => %{}
      })

      assert_push "tool_result", %{call_id: "call-unknown", status: "error", error: error}
      assert error.error =~ "unknown tool 'plan.update'"
      assert error.error =~ "Closest declared name: 'plan_update'"
      refute error.error =~ "not in allowed bundles"
      assert error.code == "forbidden"
    end

    # Load-bearing: without this, rewording every denial to "unknown tool"
    # would also pass the test above.
    test "a real catalogue tool outside this runtime's profile names its permission",
         ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "tool_call", %{
        "call_id" => "call-forbidden",
        "tool" => "plan_update",
        "args" => %{}
      })

      assert_push "tool_result", %{call_id: "call-forbidden", status: "error", error: error}

      assert error.error ==
               "tool 'plan_update' requires permission 'tasks.write', which this agent does not hold or is capped at its owner"
    end

    test "the two denial messages differ for the two inputs", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "tool_call", %{"call_id" => "call-a", "tool" => "plan.update", "args" => %{}})
      assert_push "tool_result", %{call_id: "call-a", status: "error", error: unknown_error}

      push(socket, "tool_call", %{"call_id" => "call-b", "tool" => "plan_update", "args" => %{}})
      assert_push "tool_result", %{call_id: "call-b", status: "error", error: forbidden_error}

      # Not just "the strings differ" — the two tool spellings alone would
      # make that trivially true. Pin that the WORDING differs by reason:
      # one names itself a lookup miss and the other doesn't.
      assert unknown_error.error =~ "unknown tool"
      refute forbidden_error.error =~ "unknown tool"
      assert unknown_error.error != forbidden_error.error
    end

    # `effective_tools/1` resolves a nil/empty `tool_profile` column to an
    # empty list, so a no-bundles runtime and a narrow-bundles runtime look
    # identical from inside `authorize/2` — this pins that the no-bundles
    # case still gets the grant-denial wording for a real tool, not the
    # unknown-tool one.
    test "a runtime granted NO bundles still gets a denial for a real tool, not an unknown-tool answer",
         ctx do
      {:ok, _updated} = set_runtime_profile(ctx.runtime, [])

      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "tool_call", %{
        "call_id" => "call-nobundles",
        "tool" => "task_create",
        "args" => %{}
      })

      assert_push "tool_result", %{call_id: "call-nobundles", status: "error", error: error}

      assert error.error ==
               "tool 'task_create' requires permission 'tasks.write', which this agent does not hold or is capped at its owner"

      refute error.error =~ "unknown tool"
    end

    test "emits tool_call_denied telemetry with reason :unknown_tool for an undeclared name",
         ctx do
      handler_id = "channel-tool-call-denied-unknown-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:platform, :federation, :tool_call_denied],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:tool_call_denied, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "tool_call", %{
        "call_id" => "call-telemetry-unknown",
        "tool" => "plan.update",
        "args" => %{}
      })

      assert_receive {:tool_call_denied, _measurements, metadata}
      assert metadata.reason == :unknown_tool
      assert metadata.tool == "plan.update"
    end

    test "emits tool_call_denied telemetry with reason :forbidden for a real-but-ungranted tool",
         ctx do
      handler_id = "channel-tool-call-denied-forbidden-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:platform, :federation, :tool_call_denied],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:tool_call_denied, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "tool_call", %{
        "call_id" => "call-telemetry-forbidden",
        "tool" => "plan_update",
        "args" => %{}
      })

      assert_receive {:tool_call_denied, _measurements, metadata}
      assert metadata.reason == :forbidden
      assert metadata.tool == "plan_update"
    end
  end

  # Pins the refusal contract AT THE WIRE for both federation transports at
  # once. Asserting each side in its own file cannot catch a divergence — and
  # a divergence is exactly what shipped: `MCPController.error_content/1`
  # flattened `%{error:, code:, recoverable:, suggestion:}` to the sentence
  # alone while `execute_tool_call/4` here pushed the map intact, so a
  # documented `code` taxonomy was readable over WebSocket and invisible over
  # HTTP. The two transports front the same `ToolSurface.execute/3`; a caller
  # must not have to know which door it came through.
  describe "transport parity with POST /mcp" do
    setup ctx do
      # `task_design_decline` lives in the `task` bundle, which is not in the
      # default grant. Same token drives both transports.
      {:ok, runtime} = set_runtime_profile(ctx.runtime, ["task"])
      %{runtime: runtime}
    end

    test "the same refusal exposes the same four keys over both transports", ctx do
      # `"short"`, not `"   "` — a whitespace-only reason is intercepted by
      # `ToolArguments.validate/2` (blank counts as absent), which would make
      # this a parity test of the gate rather than of the handler envelope it
      # was written to follow. Present-but-too-short stays the handler's own
      # refusal, and the gate's parity is pinned separately below.
      args = %{"task_id" => Ecto.UUID.generate(), "reason" => "short"}

      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "tool_call", %{
        "call_id" => "call-parity",
        "tool" => "task_design_decline",
        "args" => args
      })

      assert_push "tool_result", %{call_id: "call-parity", status: "error", error: ws_error}

      http_body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "task_design_decline", "arguments" => args}
      }

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> ctx.raw_token)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.dispatch(@endpoint, :post, "/mcp", http_body)

      %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
        Phoenix.ConnTest.json_response(conn, 200)

      http_error = Jason.decode!(text)

      # WebSocket carries native terms (atom code); HTTP carries JSON (string
      # code). That is the only difference the two may have, and it is a
      # property of the encodings, not of the contract.
      assert http_error["error"] == ws_error.error
      assert http_error["code"] == to_string(ws_error.code)
      assert http_error["recoverable"] == ws_error.recoverable
      assert http_error["suggestion"] == ws_error.suggestion

      assert http_error["code"] == "missing_reason"
      assert http_error["recoverable"] == true
      assert Map.keys(http_error) |> Enum.sort() == ~w(code error recoverable suggestion)
    end
  end

  describe "the argument gate is mounted on both transports" do
    setup ctx do
      {:ok, runtime} = set_runtime_profile(ctx.runtime, ["plan"])
      %{runtime: runtime}
    end

    test "a missing required argument is refused identically over WebSocket and /mcp", ctx do
      # `validation_evaluate` without a validation_id used to raise
      # `Ecto.NoResultsError` from inside a `Repo.transaction`. Both doors
      # must now name the argument, and name it the same way — the gate lives
      # in one module precisely so they cannot diverge.
      #
      # This drove `stage_list` until stage 5 gave that tool a conditional
      # `plan_id` XOR `task_id` rule and took it out of the gate's scope.
      # Pointed there it would still pass, off the handler's own refusal,
      # while no longer exercising the gate's mounting on either transport.
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "tool_call", %{
        "call_id" => "call-gate",
        "tool" => "validation_evaluate",
        "args" => %{"status" => "passed"}
      })

      assert_push "tool_result", %{call_id: "call-gate", status: "error", error: ws_error}

      assert ws_error.code == :missing_validation_id
      assert ws_error.recoverable == true

      http_body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "validation_evaluate",
          "arguments" => %{"status" => "passed"}
        }
      }

      # `Phoenix.ConnTest.post/3` is a macro and cannot be called
      # fully-qualified from a ChannelCase; `dispatch/5` is a real function.
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> ctx.raw_token)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.dispatch(@endpoint, :post, "/mcp", http_body)

      %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
        Phoenix.ConnTest.json_response(conn, 200)

      http_error = Jason.decode!(text)

      assert http_error["error"] == ws_error.error
      assert http_error["code"] == to_string(ws_error.code)
      assert http_error["recoverable"] == ws_error.recoverable
      assert http_error["suggestion"] == ws_error.suggestion
    end

    test "a handler's own conditional refusal is identical over both transports too", ctx do
      # Parity is not a property of the gate — it is a property of the two
      # doors. `stage_list`'s `plan_id` XOR `task_id` rule lives in the
      # handler, below both, so it needs its own pin: a refusal that never
      # passes through `ToolArguments` must still reach an HTTP caller with
      # its `code` intact rather than flattened to a sentence.
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "tool_call", %{
        "call_id" => "call-conditional",
        "tool" => "stage_list",
        "args" => %{}
      })

      assert_push "tool_result", %{call_id: "call-conditional", status: "error", error: ws_error}

      assert ws_error.code == :missing_plan_reference

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> ctx.raw_token)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.dispatch(@endpoint, :post, "/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "stage_list", "arguments" => %{}}
        })

      %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
        Phoenix.ConnTest.json_response(conn, 200)

      http_error = Jason.decode!(text)

      assert http_error["error"] == ws_error.error
      assert http_error["code"] == to_string(ws_error.code)
      assert http_error["recoverable"] == ws_error.recoverable
      assert http_error["suggestion"] == ws_error.suggestion
    end
  end

  describe "task_list undeclared keys over the WebSocket (task 01a0acc3)" do
    setup ctx do
      {:ok, runtime} = set_runtime_profile(ctx.runtime, ["task"])
      %{runtime: runtime}
    end

    test "an undeclared key is refused and named, not silently dropped", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "tool_call", %{
        "call_id" => "call-unknown-param",
        "tool" => "task_list",
        "args" => %{"assignee" => Ecto.UUID.generate()}
      })

      assert_push "tool_result", %{call_id: "call-unknown-param", status: "error", error: error}

      assert error.code == :unknown_parameter
      assert to_string(error.code) == "unknown_parameter"
      assert error.error =~ "assignee"
      assert error.unknown_parameters == ["assignee"]
      assert error.recoverable == true
    end
  end

  defp create_project(attrs \\ %{}) do
    default = %{name: "Channel Test Project #{System.unique_integer([:positive])}"}
    {:ok, project} = Tasks.create_project(Map.merge(default, attrs))
    project
  end

  # Task 01a0d8de stage 2: the optional reply annotations. Unit coverage of
  # every drop reason is in Platform.Chat.ReplyContextTest; these pin the
  # wire half: what is stored, what the ack says, and that legacy frames are
  # untouched.
  defp post_as!(space_id, participant_id, content) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant_id,
        content_type: "text",
        content: content
      })

    msg
  end

  describe "reply annotations (in_reply_to_message_id, context)" do
    test "(a) same-space target and context are stored under reply_to_message_id / reply_context",
         ctx do
      socket = joined_socket(ctx)
      target = post_as!(ctx.space.id, ctx.agent_participant.id, "the question")

      ref =
        push(socket, "reply", %{
          "space_id" => ctx.space.id,
          "content" => "the answer",
          "in_reply_to_message_id" => target.id,
          "context" => "Answers the question\nabout stage 4"
        })

      assert_reply ref, :ok, ack
      # Nothing dropped, so no `dropped` key at all.
      assert ack == %{message_id: ack.message_id, space_id: ctx.space.id}

      message = Repo.get!(Chat.Message, ack.message_id)
      assert message.metadata["reply_to_message_id"] == target.id
      assert message.metadata["reply_context"] == "Answers the question about stage 4"
      assert message.metadata["source"] == "external_runtime"
    end

    test "(b) a target in another space the runtime can write to is dropped, the message posts",
         ctx do
      socket = joined_socket(ctx)
      other = create_space()
      {:ok, other_p} = Chat.add_agent_participant(other.id, ctx.agent, display_name: "x")
      foreign = post_as!(other.id, other_p.id, "in the other space")

      ref =
        push(socket, "reply", %{
          "space_id" => ctx.space.id,
          "content" => "cross-space probe",
          "in_reply_to_message_id" => foreign.id
        })

      assert_reply ref, :ok, ack

      assert ack == %{
               message_id: ack.message_id,
               space_id: ctx.space.id,
               dropped: [%{field: "in_reply_to_message_id", reason: "other_space"}]
             }

      message = Repo.get!(Chat.Message, ack.message_id)
      assert message.space_id == ctx.space.id
      assert message.content == "cross-space probe"
      refute Map.has_key?(message.metadata, "reply_to_message_id")
    end

    test "(c) each invalid target is dropped with its reason and the message still posts", ctx do
      socket = joined_socket(ctx)
      deleted = post_as!(ctx.space.id, ctx.agent_participant.id, "gone")
      {:ok, _} = Chat.delete_message(deleted)

      for {id, reason} <- [
            {"nope", "invalid_uuid"},
            {Ecto.UUID.generate(), "not_found"},
            {deleted.id, "deleted"}
          ] do
        ref =
          push(socket, "reply", %{
            "space_id" => ctx.space.id,
            "content" => "reply for " <> reason,
            "in_reply_to_message_id" => id
          })

        assert_reply ref, :ok, %{message_id: message_id, dropped: dropped}
        assert dropped == [%{field: "in_reply_to_message_id", reason: reason}]
        message = Repo.get!(Chat.Message, message_id)
        assert message.content == "reply for " <> reason
        refute Map.has_key?(message.metadata, "reply_to_message_id")
      end
    end

    test "(c) a target older than the agent's history grant is dropped as outside_grant", ctx do
      old = post_as!(ctx.space.id, ctx.agent_participant.id, "before the grant")

      {:ok, _} =
        Chat.update_participant(ctx.agent_participant, %{
          history_visible_from: DateTime.add(old.inserted_at, 1, :second)
        })

      socket = joined_socket(ctx)

      ref =
        push(socket, "reply", %{
          "space_id" => ctx.space.id,
          "content" => "bounded",
          "in_reply_to_message_id" => old.id
        })

      assert_reply ref, :ok, %{
        dropped: [%{field: "in_reply_to_message_id", reason: "outside_grant"}]
      }
    end

    test "(d) a 500-char context is capped at 200 and a non-string context is dropped", ctx do
      socket = joined_socket(ctx)

      ref =
        push(socket, "reply", %{
          "space_id" => ctx.space.id,
          "content" => "long",
          "context" => String.duplicate("x", 500)
        })

      assert_reply ref, :ok, ack
      refute Map.has_key?(ack, :dropped)
      stored = Repo.get!(Chat.Message, ack.message_id).metadata["reply_context"]
      assert String.length(stored) == 200

      ref =
        push(socket, "reply", %{"space_id" => ctx.space.id, "content" => "n", "context" => 7})

      assert_reply ref, :ok, %{
        message_id: id,
        dropped: [%{field: "context", reason: "not_string"}]
      }

      refute Map.has_key?(Repo.get!(Chat.Message, id).metadata, "reply_context")
    end

    test "(e) a mention token in context is stored with no at-bracket sequence", ctx do
      socket = joined_socket(ctx)
      opener = "@" <> "["

      ref =
        push(socket, "reply", %{
          "space_id" => ctx.space.id,
          "content" => "answer",
          "context" => "ask " <> opener <> ctx.agent.slug <> "] next"
        })

      assert_reply ref, :ok, %{message_id: id}
      stored = Repo.get!(Chat.Message, id).metadata["reply_context"]
      refute String.contains?(stored, opener)
      assert stored =~ ctx.agent.slug
    end

    test "(g) a legacy frame keeps its exact ack and metadata", ctx do
      socket = joined_socket(ctx)

      ref = push(socket, "reply", %{"space_id" => ctx.space.id, "content" => "legacy"})

      assert_reply ref, :ok, ack
      assert Map.keys(ack) |> Enum.sort() == [:message_id, :space_id]
      assert ack == %{message_id: ack.message_id, space_id: ctx.space.id}

      message = Repo.get!(Chat.Message, ack.message_id)

      assert message.metadata == %{
               "source" => "external_runtime",
               "runtime_id" => ctx.runtime.runtime_id
             }
    end

    test "(g) an unknown extra key is accepted and not stored", ctx do
      socket = joined_socket(ctx)

      ref =
        push(socket, "reply", %{
          "space_id" => ctx.space.id,
          "content" => "extra",
          "some_future_field" => "whatever"
        })

      assert_reply ref, :ok, ack
      assert ack == %{message_id: ack.message_id, space_id: ctx.space.id}

      assert Repo.get!(Chat.Message, ack.message_id).metadata == %{
               "source" => "external_runtime",
               "runtime_id" => ctx.runtime.runtime_id
             }
    end

    test "(h) reply_with_media stores the same fields and reports drops", ctx do
      socket = joined_socket(ctx)
      target = post_as!(ctx.space.id, ctx.agent_participant.id, "show me")

      ref =
        push(socket, "reply_with_media", %{
          "space_id" => ctx.space.id,
          "content" => "here",
          "in_reply_to_message_id" => target.id,
          "context" => "the diagram you asked for",
          "attachments" => [
            %{
              "filename" => "d.txt",
              "content_type" => "text/plain",
              "data" => Base.encode64("hi")
            }
          ]
        })

      assert_reply ref, :ok, ack
      assert ack == %{message_id: ack.message_id, space_id: ctx.space.id}
      message = Repo.get!(Chat.Message, ack.message_id)
      assert message.metadata["reply_to_message_id"] == target.id
      assert message.metadata["reply_context"] == "the diagram you asked for"
      assert message.metadata["has_media"] == true

      ref =
        push(socket, "reply_with_media", %{
          "space_id" => ctx.space.id,
          "content" => "bad",
          "in_reply_to_message_id" => "nope",
          "attachments" => []
        })

      assert_reply ref, :ok, %{
        message_id: id,
        dropped: [%{field: "in_reply_to_message_id", reason: "invalid_uuid"}]
      }

      refute Map.has_key?(Repo.get!(Chat.Message, id).metadata, "reply_to_message_id")
    end

    test "(h) a legacy reply_with_media keeps its exact ack", ctx do
      socket = joined_socket(ctx)

      ref =
        push(socket, "reply_with_media", %{
          "space_id" => ctx.space.id,
          "content" => "legacy media",
          "attachments" => []
        })

      assert_reply ref, :ok, ack
      assert ack == %{message_id: ack.message_id, space_id: ctx.space.id}

      assert Repo.get!(Chat.Message, ack.message_id).metadata == %{
               "source" => "external_runtime",
               "runtime_id" => ctx.runtime.runtime_id,
               "has_media" => true
             }
    end

    # Pins the stage-2 finding that a chunked reply's persisted row is the
    # plain `reply` a plugin sends at finalisation. If chunks ever start
    # persisting, this trips and the change has to decide where the reply
    # annotations go.
    test "(i) reply_chunk with done: true creates no message row", ctx do
      socket = joined_socket(ctx)

      count = fn ->
        Repo.aggregate(from(m in Chat.Message, where: m.space_id == ^ctx.space.id), :count)
      end

      before = count.()

      ref =
        push(socket, "reply_chunk", %{
          "space_id" => ctx.space.id,
          "chunk_id" => "final",
          "text" => "the whole answer",
          "done" => true,
          "in_reply_to_message_id" => Ecto.UUID.generate(),
          "context" => "ignored on chunks"
        })

      assert_reply ref, :ok
      assert count.() == before
    end
  end

  # Task 01a174f5 stage 1: a federated reply answers in the thread its
  # in_reply_to_message_id target sits in, and top-level otherwise.
  describe "federated reply placement" do
    defp thread_target!(ctx) do
      member =
        Chat.add_participant(ctx.space.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Member",
          joined_at: DateTime.utc_now()
        })
        |> elem(1)

      parent = post_as!(ctx.space.id, ctx.agent_participant.id, "the plan")
      {:ok, thread} = Chat.create_thread_for_message(ctx.space.id, parent.id)

      {:ok, in_thread} =
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: member.id,
          thread_id: thread.id,
          content_type: "text",
          content: "a follow-up"
        })

      {thread, in_thread, member}
    end

    test "a federated reply whose in_reply_to is a thread message posts into that thread", ctx do
      socket = joined_socket(ctx)
      {thread, in_thread, member} = thread_target!(ctx)

      ref =
        push(socket, "reply", %{
          "space_id" => ctx.space.id,
          "content" => "answer in thread",
          "in_reply_to_message_id" => in_thread.id
        })

      assert_reply ref, :ok, ack
      message = Repo.get!(Chat.Message, ack.message_id)
      assert message.thread_id == thread.id
      assert message.metadata["reply_to_message_id"] == in_thread.id

      # The top-level case stays top-level.
      top = post_as!(ctx.space.id, member.id, "a main-log question")

      ref =
        push(socket, "reply", %{
          "space_id" => ctx.space.id,
          "content" => "answer in the log",
          "in_reply_to_message_id" => top.id
        })

      assert_reply ref, :ok, ack
      message = Repo.get!(Chat.Message, ack.message_id)
      assert message.thread_id == nil
      assert message.metadata["reply_to_message_id"] == top.id

      # A dropped target posts top-level, as before.
      ref =
        push(socket, "reply", %{
          "space_id" => ctx.space.id,
          "content" => "bad target",
          "in_reply_to_message_id" => "nope"
        })

      assert_reply ref, :ok, ack
      assert Repo.get!(Chat.Message, ack.message_id).thread_id == nil
    end

    test "reply_with_media to a thread message posts into that thread", ctx do
      socket = joined_socket(ctx)
      {thread, in_thread, _member} = thread_target!(ctx)

      ref =
        push(socket, "reply_with_media", %{
          "space_id" => ctx.space.id,
          "content" => "here",
          "in_reply_to_message_id" => in_thread.id,
          "attachments" => []
        })

      assert_reply ref, :ok, ack
      assert Repo.get!(Chat.Message, ack.message_id).thread_id == thread.id

      ref =
        push(socket, "reply_with_media", %{
          "space_id" => ctx.space.id,
          "content" => "no target",
          "attachments" => []
        })

      assert_reply ref, :ok, ack
      assert Repo.get!(Chat.Message, ack.message_id).thread_id == nil
    end
  end
end
