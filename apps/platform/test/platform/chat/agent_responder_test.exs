defmodule Platform.Chat.AgentResponderTest do
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Chat.AgentResponder
  alias Platform.Chat.AttentionRouter
  alias Platform.Federation.RuntimePresence
  alias Platform.Repo

  defmodule StubAgentChat do
    def chat(message, opts) do
      if pid = Application.get_env(:platform, :chat_agent_test_pid) do
        send(pid, {:agent_chat_called, message, opts})
      end

      {:ok, %{content: "Zip reply: #{message}", model: "stub", usage: %{}}}
    end
  end

  setup do
    previous_module = Application.get_env(:platform, :chat_agent_module)
    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
    previous_pid = Application.get_env(:platform, :chat_agent_test_pid)

    Application.put_env(:platform, :chat_agent_module, StubAgentChat)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)
    Application.put_env(:platform, :chat_agent_test_pid, self())

    on_exit(fn ->
      Application.put_env(:platform, :chat_agent_module, previous_module)
      Application.put_env(:platform, :chat_agent_dispatch_mode, previous_mode)
      Application.put_env(:platform, :chat_agent_test_pid, previous_pid)
    end)

    router =
      Process.whereis(AttentionRouter) ||
        start_supervised!({AttentionRouter, []})

    Sandbox.allow(Repo, self(), router)

    :ok
  end

  defp create_space(attrs \\ %{}) do
    default = %{name: "Test", slug: unique_slug(), kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp create_participant(space_id, attrs \\ %{}) do
    default = %{
      participant_type: "user",
      participant_id: Ecto.UUID.generate(),
      display_name: "Alice",
      joined_at: DateTime.utc_now()
    }

    {:ok, participant} = Chat.add_participant(space_id, Map.merge(default, attrs))
    participant
  end

  defp create_agent(attrs \\ %{}) do
    defaults = %{
      slug: "main",
      name: "Zip",
      status: "active",
      max_concurrent: 1,
      sandbox_mode: "off",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    }

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    agent
  end

  # Register an external runtime, mark it present, point an agent at it, and
  # subscribe to its runtime topic. `Sandbox.allow/3` on the presence process is
  # required or the presence lookup fails under the ownership sandbox.
  defp federated_runtime(slug) do
    runtime_pres = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
    Sandbox.allow(Repo, self(), runtime_pres)

    unique = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        email: "ar-env-#{unique}@example.com",
        name: "AR Envelope Owner",
        oidc_sub: "oidc-ar-env-#{unique}"
      })

    runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: owner.id,
        status: "active",
        runtime_id: "rt-env-#{unique}",
        display_name: "#{slug}-runtime"
      })

    RuntimePresence.track(runtime.runtime_id)
    on_exit(fn -> RuntimePresence.untrack(runtime.runtime_id) end)

    agent =
      create_agent(%{
        slug: "#{slug}-#{unique}",
        name: "Envelope Agent",
        runtime_type: "external",
        runtime_id: runtime.id
      })

    topic = "runtime:#{runtime.runtime_id}"
    :ok = PlatformWeb.Endpoint.subscribe(topic)

    {agent, topic}
  end

  defp create_message(space_id, participant_id, attrs \\ %{}) do
    defaults = %{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "text",
      content: "hello"
    }

    # Go through Chat.post_message so author_* snapshots get populated
    # (ADR 0038). Historical tests that asserted on prefixed history
    # content depended on the snapshot being set.
    {:ok, message} = Platform.Chat.post_message(Map.merge(defaults, attrs))
    message
  end

  defp unique_slug do
    "test-#{System.unique_integer([:positive])}"
  end

  describe "attention-triggered agent replies" do
    test "routes a case-insensitive @zip mention into an agent reply" do
      space = create_space()
      user = create_participant(space.id)
      agent = create_agent()

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      message = create_message(space.id, user.id, %{content: "hey @zip can you help?"})

      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :mention}]} =
               AttentionRouter.route(message)

      assert_receive {:agent_chat_called, "hey @zip can you help?", opts}, 500
      assert opts[:history] == []

      replies = Chat.list_messages(space.id, limit: 10)
      reply = Enum.find(replies, &(&1.participant_id == agent_participant.id))

      assert reply
      assert reply.content == "Zip reply: hey @zip can you help?"
      assert reply.metadata["trigger"] == "mention"

      assert :ok = GenServer.call(AttentionRouter, :__drain__)
    end

    test "includes recent same-scope history and ignores non-mentions" do
      space = create_space()
      user = create_participant(space.id)
      agent = create_agent(%{slug: "main-2", name: "Zip"})

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      _older_user = create_message(space.id, user.id, %{content: "Earlier context"})
      _older_agent = create_message(space.id, agent_participant.id, %{content: "Previous reply"})
      message = create_message(space.id, user.id, %{content: "No summon here"})

      assert {:ok, []} = AttentionRouter.route(message)
      refute_receive {:agent_chat_called, _, _}, 200

      mention = create_message(space.id, user.id, %{content: "@zip pick this up"})
      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :mention}]} =
               AttentionRouter.route(mention)

      assert_receive {:agent_chat_called, "@zip pick this up", opts}, 500

      assert opts[:history] == [
               %{role: "user", content: "Alice: Earlier context", attachments: []},
               %{role: "assistant", content: "Previous reply", attachments: []},
               %{role: "user", content: "Alice: No summon here", attachments: []}
             ]

      assert :ok = GenServer.call(AttentionRouter, :__drain__)
    end
  end

  describe "external runtime payload attachments" do
    test "history entries carry attachment metadata; entries with none get []" do
      space = create_space()
      user = create_participant(space.id)
      agent = create_agent(%{slug: "main-attach", name: "Zip"})

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      older_with =
        create_message(space.id, user.id, %{content: "Image attached"})

      {:ok, _att} =
        Chat.create_attachment(%{
          space_id: space.id,
          message_id: older_with.id,
          filename: "shot.png",
          content_type: "image/png",
          byte_size: 4,
          storage_key: "chat/test/shot-#{Ecto.UUID.generate()}.png",
          state: "ready"
        })

      _older_text = create_message(space.id, agent_participant.id, %{content: "Got it"})
      mention = create_message(space.id, user.id, %{content: "@zip pick this up"})

      assert {:ok, _} = AttentionRouter.route(mention)
      assert_receive {:agent_chat_called, "@zip pick this up", opts}, 500

      history = opts[:history]
      assert is_list(history)
      assert length(history) == 2

      [first, second] = history

      assert first.role == "user"
      assert first.content == "Alice: Image attached"

      assert [%{filename: "shot.png", content_type: "image/png", byte_size: 4, url: url}] =
               first.attachments

      assert url =~ ~r|^/chat/attachments/[0-9a-fA-F-]{36}$|

      assert second.role == "assistant"
      assert second.attachments == []

      assert :ok = GenServer.call(AttentionRouter, :__drain__)
    end

    test "external dispatch payload carries trigger and history attachments" do
      space = create_space()
      user = create_participant(space.id)

      # Register an external runtime + presence so dispatch_to_external proceeds
      runtime_pres = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
      Sandbox.allow(Repo, self(), runtime_pres)

      owner =
        Repo.insert!(%User{
          email: "ar-test-#{System.unique_integer([:positive])}@example.com",
          name: "AR Owner",
          oidc_sub: "oidc-ar-#{System.unique_integer([:positive])}"
        })

      runtime_token = "rt-#{System.unique_integer([:positive])}"

      runtime =
        Repo.insert!(%AgentRuntime{
          owner_user_id: owner.id,
          status: "active",
          runtime_id: runtime_token,
          display_name: "ext-rt"
        })

      RuntimePresence.track(runtime.runtime_id)

      agent =
        create_agent(%{
          slug: "ext-agent",
          name: "Ext",
          runtime_type: "external",
          runtime_id: runtime.id
        })

      {:ok, _agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Ext")

      # History message with an attachment, plus one without.
      older_with = create_message(space.id, user.id, %{content: "earlier with file"})

      {:ok, _att_history} =
        Chat.create_attachment(%{
          space_id: space.id,
          message_id: older_with.id,
          filename: "report.pdf",
          content_type: "application/pdf",
          byte_size: 12,
          storage_key: "chat/test/r-#{Ecto.UUID.generate()}.pdf",
          state: "ready"
        })

      _older_no_att = create_message(space.id, user.id, %{content: "earlier no file"})

      # Trigger message itself has an attachment + an @mention.
      trigger = create_message(space.id, user.id, %{content: "@ext look at this"})

      {:ok, trigger_att} =
        Chat.create_attachment(%{
          space_id: space.id,
          message_id: trigger.id,
          filename: "shot.png",
          content_type: "image/png",
          byte_size: 7,
          storage_key: "chat/test/s-#{Ecto.UUID.generate()}.png",
          state: "ready"
        })

      topic = "runtime:#{runtime.runtime_id}"
      :ok = PlatformWeb.Endpoint.subscribe(topic)

      assert {:ok, _} = AttentionRouter.route(trigger)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "attention",
                       payload: payload
                     },
                     1500

      assert payload.message.content =~ "look at this"
      assert payload.message.author == "Alice"

      assert [%{url: url, filename: "shot.png", content_type: "image/png", byte_size: 7}] =
               payload.message.attachments

      assert url == "/chat/attachments/#{trigger_att.id}"

      # History should contain entries; the entry whose content matches
      # "earlier with file" must include the report.pdf attachment, the
      # other should have an empty list.
      with_attach =
        Enum.find(payload.history, fn h ->
          is_binary(h.content) and h.content =~ "earlier with file"
        end)

      without_attach =
        Enum.find(payload.history, fn h ->
          is_binary(h.content) and h.content =~ "earlier no file"
        end)

      assert [%{filename: "report.pdf", content_type: "application/pdf", byte_size: 12}] =
               with_attach.attachments

      assert without_attach.attachments == []

      assert :ok = GenServer.call(AttentionRouter, :__drain__)

      RuntimePresence.untrack(runtime.runtime_id)
      _ = AgentRuntime
    end
  end

  # Chatless system_event signals — the shape the Responsibilities.Router
  # builds for cron / webhook / event_topic responsibility fires. Before
  # the fix these tripped a FunctionClauseError inside `load_context/1`
  # because the only clause required `participant_id + message_id + space_id`,
  # which cron-fired signals don't carry.
  describe "cron / responsibility-triggered system_event signals" do
    test "load_context accepts the cron shape and returns a chat-less context" do
      agent = create_agent(%{slug: "higgins-cron", name: "Higgins"})

      signal = %{
        reason: :system_event,
        metadata: %{
          feature: "memory",
          agent_id: agent.id,
          agent_slug: "higgins-cron",
          responsibility_key: "memory.dreaming",
          trigger_kind: :cron
        }
      }

      # respond/1 → load_context/1 → dispatch_system_event/2 — no runtime
      # linked so we exercise the built-in / no-runtime branch (log-and-skip).
      # The important assertion is that this does NOT raise — pre-fix the
      # call chain crashed with FunctionClauseError before ever hitting
      # any dispatch path.
      assert :ok = AgentResponder.respond(signal)
    end

    test "missing agent_id maps to :ignore (does not crash)" do
      signal = %{
        reason: :system_event,
        metadata: %{
          feature: "memory",
          responsibility_key: "memory.dreaming",
          trigger_kind: :cron
        }
      }

      assert :ok = AgentResponder.respond(signal)
    end

    test "unknown agent_id maps to :ignore (does not crash)" do
      signal = %{
        reason: :system_event,
        metadata: %{
          feature: "memory",
          agent_id: Ecto.UUID.generate(),
          agent_slug: "ghost",
          responsibility_key: "memory.dreaming",
          trigger_kind: :cron
        }
      }

      assert :ok = AgentResponder.respond(signal)
    end

    test "broadcasts a bare signal envelope to the federated agent's runtime" do
      # Register an external runtime + presence so dispatch_system_event's
      # federated branch proceeds through the broadcast.
      runtime_pres = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
      Sandbox.allow(Repo, self(), runtime_pres)

      owner =
        Repo.insert!(%User{
          email: "ar-cron-#{System.unique_integer([:positive])}@example.com",
          name: "AR Cron Owner",
          oidc_sub: "oidc-ar-cron-#{System.unique_integer([:positive])}"
        })

      runtime_token = "rt-cron-#{System.unique_integer([:positive])}"

      runtime =
        Repo.insert!(%AgentRuntime{
          owner_user_id: owner.id,
          status: "active",
          runtime_id: runtime_token,
          display_name: "higgins-runtime"
        })

      RuntimePresence.track(runtime.runtime_id)

      agent =
        create_agent(%{
          slug: "higgins",
          name: "Higgins",
          runtime_type: "external",
          runtime_id: runtime.id
        })

      topic = "runtime:#{runtime.runtime_id}"
      :ok = PlatformWeb.Endpoint.subscribe(topic)

      signal = %{
        reason: :system_event,
        metadata: %{
          feature: "memory",
          agent_id: agent.id,
          agent_slug: "higgins",
          responsibility_key: "memory.dreaming",
          trigger_kind: :cron
        }
      }

      assert :ok = AgentResponder.respond(signal)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "attention",
                       payload: %{signal: broadcast_signal} = payload
                     },
                     1500

      assert broadcast_signal.reason == :system_event
      assert broadcast_signal.agent_id == agent.id
      assert broadcast_signal.agent_slug == "higgins"
      assert broadcast_signal.responsibility_key == "memory.dreaming"
      assert broadcast_signal.feature == "memory"
      assert broadcast_signal.trigger_kind == :cron

      # This fire carries no rendered prompt, so the envelope stays bare: no
      # `message` key at all rather than one with an empty body. The four
      # positive assertions above are the control — they prove this really is
      # the delivered payload and not a nil that satisfies `refute` trivially.
      refute Map.has_key?(payload, :message)
      refute Map.has_key?(broadcast_signal, :prompt)

      RuntimePresence.untrack(runtime.runtime_id)
      _ = AgentRuntime
    end

    # THE SHAPE GUARANTEED TO A CONSUMER.
    #
    # These assert the payload as it leaves the server on `runtime:<id>` —
    # deliberately not what the Router builds, which was correct throughout this
    # bug. The envelope is BARE (`%{signal: ...}`), the body has exactly one
    # home (`signal.prompt`), and the correlation ids are lifted to the signal
    # root so a woken runtime knows which task it was woken for. The clients'
    # misread of this shape is fixed client-side under `019fa618-ca92`; the
    # server does not mirror the body into a second key to compensate.
    test "system_event envelope carries the prompt at signal.prompt and lifts the correlation ids" do
      {agent, topic} = federated_runtime("higgins")

      prompt = "Review plan 7 for task Ship the envelope. Two stages await sign-off."
      task_id = Ecto.UUID.generate()
      plan_id = Ecto.UUID.generate()
      stage_id = Ecto.UUID.generate()
      project_id = Ecto.UUID.generate()
      space_id = Ecto.UUID.generate()

      signal = %{
        reason: :system_event,
        metadata: %{
          feature: "architecture",
          agent_id: agent.id,
          agent_slug: agent.slug,
          responsibility_key: "architecture.review_plan",
          trigger_kind: :event_topic,
          prompt: prompt,
          task_id: task_id,
          plan_id: plan_id,
          stage_id: stage_id,
          project_id: project_id,
          space_id: space_id
        }
      }

      assert :ok = AgentResponder.respond(signal)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "attention",
                       payload: payload
                     },
                     1500

      broadcast_signal = payload.signal

      # The body, at its one and only key.
      assert broadcast_signal.prompt == prompt

      # And the envelope around it is bare EVEN THOUGH a body rendered. This
      # is the general contract, not a no-prompt special case: the assertion
      # directly above is the positive control proving a real body-bearing
      # dispatch arrived, so this refute is about the shim's absence and not
      # about an empty fire.
      refute Map.has_key?(payload, :message)
      assert Map.keys(payload) == [:signal]

      # Correlation ids at the TOP level (the lift), pinned to the seeded
      # values rather than merely asserted non-nil.
      assert broadcast_signal.task_id == task_id
      assert broadcast_signal.plan_id == plan_id
      assert broadcast_signal.stage_id == stage_id
      assert broadcast_signal.project_id == project_id

      # ...and STILL in metadata. Lifting is additive; a consumer reading
      # `signal.metadata.task_id` today keeps working.
      assert broadcast_signal.metadata.task_id == task_id
      assert broadcast_signal.metadata.plan_id == plan_id
      assert broadcast_signal.metadata.stage_id == stage_id
      assert broadcast_signal.metadata.project_id == project_id
      assert broadcast_signal.metadata.prompt == prompt

      # THE PERMISSION-RELAY ASYMMETRY, and the reason this test seeds a
      # `space_id` it then asserts is missing. `claude-code-suite-channel` pins
      # the space a pending permission prompt is answered in from the TOP-LEVEL
      # `signal.space_id` only, and resolves a reply target more permissively
      # from metadata. Replying is safe; re-pinning is not. A background
      # responsibility fire that lifted its space_id would silently move a live
      # approval to a space nobody is watching.
      #
      # The four `assert`s directly above are the positive control for this
      # `refute`: they prove the lift ran over THIS metadata map and chose not
      # to take `space_id`, rather than the refute passing because no lift
      # happened at all.
      refute Map.has_key?(broadcast_signal, :space_id)
      assert broadcast_signal.metadata.space_id == space_id
    end

    test "a system_event with no rendered prompt has no prompt key and the same bare envelope" do
      {agent, topic} = federated_runtime("higgins-quiet")

      signal = %{
        reason: :system_event,
        metadata: %{
          feature: "memory",
          agent_id: agent.id,
          agent_slug: agent.slug,
          responsibility_key: "memory.daily_summary",
          trigger_kind: :cron,
          task_id: nil
        }
      }

      assert :ok = AgentResponder.respond(signal)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "attention",
                       payload: payload
                     },
                     1500

      # Positive control first: this is a real delivered envelope, so the
      # refutes below are about absence rather than about nothing arriving.
      assert payload.signal.responsibility_key == "memory.daily_summary"
      assert payload.signal.agent_id == agent.id

      refute Map.has_key?(payload, :message)
      refute Map.has_key?(payload, :history)
      refute Map.has_key?(payload, :context)
      refute Map.has_key?(payload.signal, :prompt)

      # A nil id in metadata still produces NO key rather than a nil one —
      # `maybe_put/3`'s contract, which is what keeps "absent" meaningful.
      refute Map.has_key?(payload.signal, :task_id)
    end

    test "an empty-string prompt does not vary the envelope shape" do
      {agent, topic} = federated_runtime("higgins-empty")

      # `maybe_put/3` only drops nil, so an empty prompt DOES reach the signal
      # as `prompt: ""`. The envelope is unchanged by that: still bare, with
      # the emptiness visible at `signal.prompt` where a client can see it,
      # rather than smuggled into a second body key.
      signal = %{
        reason: :system_event,
        metadata: %{
          feature: "memory",
          agent_id: agent.id,
          agent_slug: agent.slug,
          responsibility_key: "memory.dreaming",
          trigger_kind: :cron,
          prompt: ""
        }
      }

      assert :ok = AgentResponder.respond(signal)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "attention",
                       payload: payload
                     },
                     1500

      assert payload.signal.prompt == ""
      refute Map.has_key?(payload, :message)
    end

    test "the lifted correlation whitelist is exactly the Router's native trigger scalars" do
      # Pin, not restate. These two lists diverging is precisely how an id ends
      # up reaching a runtime on the chat path and not on the responsibility
      # path — the asymmetry that made two independently written clients wrong.
      assert AgentResponder.correlation_id_keys() ==
               Platform.Responsibilities.Router.native_trigger_scalar_keys()

      # Control against the pin passing trivially on two empty lists, and
      # against `space_id` creeping in later.
      assert AgentResponder.correlation_id_keys() == [:task_id, :plan_id, :stage_id, :project_id]
      refute :space_id in AgentResponder.correlation_id_keys()
    end

    test "federated agent with offline runtime dead-letters instead of crashing" do
      runtime_pres = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
      Sandbox.allow(Repo, self(), runtime_pres)

      owner =
        Repo.insert!(%User{
          email: "ar-cron-off-#{System.unique_integer([:positive])}@example.com",
          name: "AR Cron Offline Owner",
          oidc_sub: "oidc-ar-cron-off-#{System.unique_integer([:positive])}"
        })

      runtime_token = "rt-cron-off-#{System.unique_integer([:positive])}"

      runtime =
        Repo.insert!(%AgentRuntime{
          owner_user_id: owner.id,
          status: "active",
          runtime_id: runtime_token,
          display_name: "higgins-runtime-offline"
        })

      # NOT tracked — presence is empty for this runtime.

      agent =
        create_agent(%{
          slug: "higgins-off",
          name: "Higgins Offline",
          runtime_type: "external",
          runtime_id: runtime.id
        })

      signal = %{
        reason: :system_event,
        metadata: %{
          feature: "memory",
          agent_id: agent.id,
          agent_slug: "higgins-off",
          responsibility_key: "memory.dreaming",
          trigger_kind: :cron
        }
      }

      # The offline-runtime branch returns {:error, :runtime_offline}
      # from dispatch_system_event/2; the important behaviour is that
      # the pipeline reaches that structured error instead of raising.
      assert {:error, :runtime_offline} = AgentResponder.respond(signal)
    end
  end
end
