defmodule PlatformWeb.RuntimeChannelTest do
  use PlatformWeb.ChannelCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
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

  defp create_user do
    Repo.insert!(%User{
      email: "channel_test_#{System.unique_integer([:positive])}@example.com",
      name: "Channel Test User",
      oidc_sub: "oidc-channel-test-#{System.unique_integer([:positive])}"
    })
  end

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

  defp create_space(attrs \\ %{}) do
    default = %{name: "Test", slug: "test-#{System.unique_integer([:positive])}", kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
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

    test "join drains this runtime's dead letters, and the 30s retrack does NOT", ctx do
      # There are exactly two `RuntimePresence.track/1` call sites in this
      # module: join/3 and the periodic `:presence_retrack` self-heal. Only the
      # first is a reconnect. Hooking the second would re-drain every connected
      # runtime twice a minute forever, so this test pins BOTH halves — a
      # drain-on-join assertion alone would still pass with the hook in the
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

  # Regression guard for the bug this task fixes: the push used to be
  # `ToolSurface.tool_definitions()` — the whole catalogue — regardless
  # of the runtime's `allowed_bundles`. It must now be exactly the set
  # `ToolAuthorization.effective_tools/1` resolves, which is also what
  # `/mcp tools/list` returns for the same runtime.
  describe "capabilities push" do
    test "is scoped to the runtime's granted bundles, not the full catalogue", ctx do
      # register_runtime/2 yields AgentRuntime.default_allowed_bundles/0 —
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
      refute "canvas.create" in names
    end

    test "a federation-only runtime is pushed exactly federation_status", ctx do
      {:ok, runtime} = Federation.update_allowed_bundles(ctx.runtime, ["federation"])

      payload = join_and_capture_capabilities(runtime, ctx.raw_token)

      assert Enum.map(payload.tools, & &1.name) == ["federation_status"]
      assert payload.tool_count == 1
    end

    test "a runtime with no bundles is pushed zero tools", ctx do
      {:ok, runtime} = Federation.update_allowed_bundles(ctx.runtime, [])

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
      {:ok, runtime} = Federation.update_allowed_bundles(ctx.runtime, ["federation"])

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

      assert_receive {:capabilities_pushed, %{tool_count: 1}, metadata}
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
               features: []
             }

      reloaded = Repo.get(Platform.Agents.AgentRuntime, ctx.runtime.id)
      # Client DID declare something, just garbage — we persist the
      # defensive "unknown" so we have a record of the failed declaration.
      assert reloaded.metadata["client_info"]["product"] == "unknown"
      assert reloaded.metadata["client_info"]["version"] == nil
      assert is_binary(reloaded.metadata["client_info"]["last_seen_at"])
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
    # process died. Observed live against `rowan-home-openclaw`.
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

    test "rejects when agent not participant in space", ctx do
      other_space =
        create_space(%{name: "Other", slug: "other-#{System.unique_integer([:positive])}"})

      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "reply_with_media", %{
        "space_id" => other_space.id,
        "content" => "Unauthorized",
        "attachments" => []
      })

      # The agent IS auto-joined via ensure_agent_participant, so let's
      # test with a nil space_id instead
      push(socket, "reply_with_media", %{
        "space_id" => nil,
        "content" => "No space",
        "attachments" => []
      })

      assert_push "error", %{error: "Agent is not a participant in this space"}
    end
  end

  describe "tool_call" do
    test "executes tool and returns result", ctx do
      # `canvas` is NOT in AgentRuntime.default_allowed_bundles/0, and
      # `tool_call` is now gated on the same authorization path as /mcp, so
      # the grant has to be explicit. Fixing the fixture rather than widening
      # the default grant is the point of the change.
      {:ok, _granted} = Federation.update_allowed_bundles(ctx.runtime, ["canvas"])

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
        "tool" => "canvas.create",
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

    # The vulnerability this task closes: before the gate, the channel
    # executed anything it was asked to, so `allowed_bundles` was advisory
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
      assert error.error == "tool 'task_create' not in allowed bundles"
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
      {:ok, _granted} = Federation.update_allowed_bundles(ctx.runtime, ["task"])

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
      {:ok, _revoked} = Federation.update_allowed_bundles(runtime, [])

      push(socket, "tool_call", %{
        "call_id" => "call-after",
        "tool" => "task_list",
        "args" => %{}
      })

      assert_push "tool_result", %{call_id: "call-after", status: "error", error: error}
      assert error.error == "tool 'task_list' not in allowed bundles"
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
      assert error.error == "tool 'space_list' not in allowed bundles"
      assert error.code == "forbidden"
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
      {:ok, runtime} = Federation.update_allowed_bundles(ctx.runtime, ["task"])
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
      {:ok, runtime} = Federation.update_allowed_bundles(ctx.runtime, ["plan"])
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

  defp create_project(attrs \\ %{}) do
    default = %{name: "Channel Test Project #{System.unique_integer([:positive])}"}
    {:ok, project} = Tasks.create_project(Map.merge(default, attrs))
    project
  end
end
