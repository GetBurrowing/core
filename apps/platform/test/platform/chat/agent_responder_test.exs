defmodule Platform.Chat.AgentResponderTest do
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Chat.AgentResponder
  alias Platform.Chat.AttentionRouter
  alias Platform.Federation.DeadLetter
  alias Platform.Federation.DeadLetters
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
      #
      # `:intent_id` joined 2026-07-31 so a meeting intent dispatched to a
      # NATIVE assignee carries the handle it must `intent_ack` with —
      # without it the row could only leave `:dispatched` via the 90s
      # timeout, holding the meeting's serial cursor for the whole window.
      assert AgentResponder.correlation_id_keys() == [
               :task_id,
               :plan_id,
               :stage_id,
               :project_id,
               :intent_id
             ]

      refute :space_id in AgentResponder.correlation_id_keys()
    end

    test "federated agent with offline runtime persists a replayable dead letter" do
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
      refute RuntimePresence.online?(runtime.runtime_id)

      agent =
        create_agent(%{
          slug: "higgins-off",
          name: "Higgins Offline",
          runtime_type: "external",
          runtime_id: runtime.id
        })

      stage_id = Ecto.UUID.generate()
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      signal = %{
        reason: :system_event,
        metadata: %{
          feature: "architecture",
          agent_id: agent.id,
          agent_slug: "higgins-off",
          responsibility_key: "architecture.audit_diff",
          trigger_kind: :event_topic,
          task_id: task_id,
          plan_id: plan_id,
          stage_id: stage_id
        }
      }

      assert {:error, :runtime_offline} = AgentResponder.respond(signal)

      # The structured error is the LEAST interesting half. What this test
      # exists to pin is that the fire was CAPTURED with everything a replay
      # needs — before this stage the recorded map carried no payload, no
      # responsibility_key and no subject, so the assertion above passed
      # while replay was flatly impossible.
      assert [letter] = Repo.all(DeadLetter)
      assert letter.runtime_id == runtime.runtime_id
      assert letter.runtime_pk == runtime.id
      assert letter.agent_id == agent.id
      assert letter.agent_slug == "higgins-off"
      assert letter.disposition == "pending"
      assert letter.source == "system_event"
      assert letter.responsibility_key == "architecture.audit_diff"
      assert letter.feature == "architecture"
      assert letter.trigger_kind == "event_topic"
      assert letter.subject_type == "stage"
      assert letter.subject_id == stage_id
      assert letter.reason == "runtime_offline"
      assert letter.attempts == 0

      assert letter.payload["signal"]["metadata"]["stage_id"] == stage_id
      assert letter.payload["signal"]["metadata"]["plan_id"] == plan_id
      assert letter.payload["signal"]["metadata"]["task_id"] == task_id
      assert letter.payload["signal"]["responsibility_key"] == "architecture.audit_diff"

      # And the stored envelope rebuilds into exactly what would have gone
      # onto the wire, atoms and all.
      envelope = DeadLetters.to_envelope(letter)
      assert envelope.signal.reason == :system_event
      assert envelope.signal.trigger_kind == :event_topic
      assert envelope.signal.metadata.stage_id == stage_id
    end

    test "federated agent with an ONLINE runtime broadcasts and writes zero dead letters" do
      # The negative control for the test above: same signal, same code path,
      # presence flipped. Without this pair, a `record/1` that fired on every
      # dispatch would still make the offline test green.
      runtime_pres = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
      Sandbox.allow(Repo, self(), runtime_pres)

      owner =
        Repo.insert!(%User{
          email: "ar-cron-on-#{System.unique_integer([:positive])}@example.com",
          name: "AR Cron Online Owner",
          oidc_sub: "oidc-ar-cron-on-#{System.unique_integer([:positive])}"
        })

      runtime_token = "rt-cron-on-#{System.unique_integer([:positive])}"

      runtime =
        Repo.insert!(%AgentRuntime{
          owner_user_id: owner.id,
          status: "active",
          runtime_id: runtime_token,
          display_name: "higgins-runtime-online"
        })

      RuntimePresence.track(runtime.runtime_id)

      agent =
        create_agent(%{
          slug: "higgins-on",
          name: "Higgins Online",
          runtime_type: "external",
          runtime_id: runtime.id
        })

      topic = "runtime:#{runtime.runtime_id}"
      :ok = PlatformWeb.Endpoint.subscribe(topic)

      stage_id = Ecto.UUID.generate()

      signal = %{
        reason: :system_event,
        metadata: %{
          feature: "architecture",
          agent_id: agent.id,
          agent_slug: "higgins-on",
          responsibility_key: "architecture.audit_diff",
          trigger_kind: :event_topic,
          stage_id: stage_id
        }
      }

      assert :ok = AgentResponder.respond(signal)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "attention",
                       payload: %{signal: broadcast_signal}
                     },
                     1500

      assert broadcast_signal.responsibility_key == "architecture.audit_diff"
      assert broadcast_signal.metadata.stage_id == stage_id
      assert Repo.aggregate(DeadLetter, :count) == 0

      RuntimePresence.untrack(runtime.runtime_id)
    end
  end

  describe "external signal forwarding" do
    test "forwards message_id and omits responsibility keys on chat signals" do
      space = create_space()
      user = create_participant(space.id)

      runtime_pres = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
      Sandbox.allow(Repo, self(), runtime_pres)

      owner =
        Repo.insert!(%User{
          email: "sig-test-#{System.unique_integer([:positive])}@example.com",
          name: "Sig Owner",
          oidc_sub: "oidc-sig-#{System.unique_integer([:positive])}"
        })

      runtime =
        Repo.insert!(%AgentRuntime{
          owner_user_id: owner.id,
          status: "active",
          runtime_id: "rt-#{System.unique_integer([:positive])}",
          display_name: "sig-rt"
        })

      RuntimePresence.track(runtime.runtime_id)

      agent =
        create_agent(%{
          slug: "sig-agent",
          name: "Sig",
          runtime_type: "external",
          runtime_id: runtime.id
        })

      {:ok, _agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Sig")

      trigger = create_message(space.id, user.id, %{content: "@sig ping"})

      topic = "runtime:#{runtime.runtime_id}"
      :ok = PlatformWeb.Endpoint.subscribe(topic)

      assert {:ok, _} = AttentionRouter.route(trigger)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "attention",
                       payload: payload
                     },
                     1500

      # Without this a federated runtime has no stable per-firing id and must
      # key isolated dispatch sessions on arrival time, so a reconnect
      # redelivery spawns a duplicate session for the same dispatch.
      assert payload.signal.message_id == trigger.id

      # Chat signals aren't responsibility firings — the keys must be absent,
      # not nil, so runtimes can test presence.
      refute Map.has_key?(payload.signal, :responsibility_key)
      refute Map.has_key?(payload.signal, :trigger_kind)

      # `dispatch_parallel/3` stores the frozen history snapshot under
      # `:metadata`. It is already delivered under `payload.history`; echoing it
      # inside the signal would duplicate an unbounded payload.
      refute Map.has_key?(payload.signal, :metadata)

      assert :ok = GenServer.call(AttentionRouter, :__drain__)

      RuntimePresence.untrack(runtime.runtime_id)
      _ = AgentRuntime
    end
  end

  # Task 01a174f5 stage 1: an agent answers a member's reply relative to the
  # trigger: a main-log reply gets a main-log answer, a thread post an
  # in-thread one.
  describe "answering a reply" do
    defp answers(space_id, agent_participant_id) do
      from(m in Platform.Chat.Message,
        where: m.space_id == ^space_id and m.participant_id == ^agent_participant_id,
        where: fragment("?->>'source' = 'agent_responder'", m.metadata)
      )
      |> Repo.all()
    end

    test "a native agent answers a reply in the main log, quoting the reply" do
      space = create_space()
      user = create_participant(space.id, %{display_name: "Member"})
      agent = create_agent(%{slug: "reply-b", name: "Agent B"})
      {:ok, b} = Chat.add_agent_participant(space.id, agent, display_name: "Agent B")
      b_id = b.id

      b_message = create_message(space.id, b.id, %{content: "The viewer fix is in review."})

      reply =
        create_message(space.id, user.id, %{
          content: "When does it ship?",
          reply_to_message_id: b_message.id
        })

      assert reply.metadata["reply_to_message_id"] == b_message.id
      assert is_nil(reply.thread_id)

      assert {:ok, [%{participant_id: ^b_id, reason: :reply}]} = AttentionRouter.route(reply)

      assert_receive {:agent_chat_called, body, _opts}, 1000

      assert body ==
               "(Replying to Agent B: \"The viewer fix is in review.\")\n\nWhen does it ship?"

      assert :ok = GenServer.call(AttentionRouter, :__drain__)

      assert [answer | _] = answers(space.id, b.id)
      assert answer.thread_id == nil
      assert answer.metadata["trigger"] == "reply"
      assert answer.metadata["reply_to_message_id"] == reply.id

      # No chat_threads row exists for the agent's message after the exchange.
      assert Chat.get_thread_for_message(b_message.id) == nil
      assert Chat.get_thread_for_message(reply.id) == nil
    end

    test "a native answer to a thread post stays in that thread" do
      space = create_space()
      user = create_participant(space.id, %{display_name: "Member"})
      agent = create_agent(%{slug: "reply-a", name: "Agent A"})
      {:ok, a} = Chat.add_agent_participant(space.id, agent, display_name: "Agent A")
      a_id = a.id

      a_message = create_message(space.id, a.id, %{content: "The plan."})
      {:ok, thread} = Chat.create_thread_for_message(space.id, a_message.id)
      post = create_message(space.id, user.id, %{content: "a follow-up", thread_id: thread.id})

      assert {:ok, [%{participant_id: ^a_id, reason: :reply}]} = AttentionRouter.route(post)
      assert_receive {:agent_chat_called, "a follow-up", _opts}, 1000
      assert :ok = GenServer.call(AttentionRouter, :__drain__)

      assert [answer | _] = answers(space.id, a.id)
      assert answer.thread_id == thread.id
      assert answer.metadata["reply_to_message_id"] == post.id
    end

    test "the external payload carries message.reply_to and message.thread_id" do
      space = create_space()
      user = create_participant(space.id, %{display_name: "Member"})
      {agent, topic} = federated_runtime("reply-ext")
      {:ok, b} = Chat.add_agent_participant(space.id, agent, display_name: "Agent B")

      long = String.duplicate("word ", 80)
      b_message = create_message(space.id, b.id, %{content: long})

      reply =
        create_message(space.id, user.id, %{
          content: "and then?",
          reply_to_message_id: b_message.id
        })

      assert {:ok, [%{reason: :reply}]} = AttentionRouter.route(reply)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "attention",
                       payload: payload
                     },
                     1500

      assert payload.message.thread_id == nil
      assert payload.message.reply_to.message_id == b_message.id
      assert payload.message.reply_to.author == "Agent B"
      # Capped like a ReplyContext preview.
      assert payload.message.reply_to.content == Platform.Chat.ReplyContext.excerpt(long)
      assert String.length(payload.message.reply_to.content) == 200

      {:ok, thread} = Chat.create_thread_for_message(space.id, b_message.id)
      post = create_message(space.id, user.id, %{content: "in thread", thread_id: thread.id})
      assert {:ok, [%{reason: :reply}]} = AttentionRouter.route(post)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "attention",
                       payload: %{message: %{content: "in thread"}} = thread_payload
                     },
                     1500

      assert thread_payload.message.thread_id == thread.id
      assert thread_payload.message.reply_to == nil
    end
  end

  # Task 01a1b1ae: a `kind: "external"` agent (Agents > Add > External Agent)
  # keeps `runtime_type: "built_in"`, so its chat used to reach QuickAgent
  # (the `:chat_agent_module` stub here) and never its own endpoint.
  describe "kind external agents reply through their HTTP endpoint" do
    @req_stub :agent_responder_external_http_test
    @base_url "https://api.example.test/v1"
    @api_secret "sk-agent-responder-external-test"

    setup do
      {:ok, _} = Application.ensure_all_started(:req)
      previous_client = Application.get_env(:platform, :external_agents_dispatcher_req_client)

      Application.put_env(
        :platform,
        :external_agents_dispatcher_req_client,
        Req.new(plug: {Req.Test, @req_stub})
      )

      on_exit(fn ->
        if previous_client,
          do:
            Application.put_env(
              :platform,
              :external_agents_dispatcher_req_client,
              previous_client
            ),
          else: Application.delete_env(:platform, :external_agents_dispatcher_req_client)
      end)

      # Posting a message routes it through the AttentionRouter's telemetry
      # handler (the production path), and dispatch mode is :sync, so the
      # router process makes the HTTP call and must be allowed onto the stub.
      # These tests post and drain rather than also calling
      # `AttentionRouter.route/1`, which would dispatch the message a second
      # time and make "exactly one POST" unassertable.
      Req.Test.allow(@req_stub, self(), Process.whereis(AttentionRouter))

      :ok
    end

    defp create_external_http_agent do
      unique = System.unique_integer([:positive])
      vault_key = "agent-responder-ext-#{unique}"

      agent =
        create_agent(%{
          slug: "relay-#{unique}",
          name: "Relay",
          kind: "external",
          endpoint_kind: "openai_compat",
          base_url: @base_url,
          model: "Example/Model",
          vault_key: vault_key
        })

      assert agent.runtime_type == "built_in"

      {:ok, _} =
        Platform.Vault.put(vault_key, :api_key, @api_secret, scope: {:agent, agent.id})

      agent
    end

    defp stub_completion(status, content) do
      test_pid = self()

      Req.Test.stub(@req_stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        send(
          test_pid,
          {:external_http_request, conn.method, conn.host, conn.request_path,
           Plug.Conn.get_req_header(conn, "authorization"), Jason.decode!(raw)}
        )

        conn
        |> Plug.Conn.put_status(status)
        |> Req.Test.json(%{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}]
        })
      end)
    end

    test "a chat mention POSTs once to <base_url>/chat/completions and persists the reply" do
      space = create_space()
      user = create_participant(space.id)
      agent = create_external_http_agent()

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Relay")

      stub_completion(200, "Endpoint says hello")

      message = create_message(space.id, user.id, %{content: "@relay are you there?"})
      assert :ok = GenServer.call(AttentionRouter, :__drain__)

      assert_receive {:external_http_request, "POST", "api.example.test", "/v1/chat/completions",
                      ["Bearer " <> secret], body},
                     1500

      assert secret == @api_secret
      assert body["model"] == "Example/Model"

      assert %{"role" => "user", "content" => "@relay are you there?"} =
               List.last(body["messages"])

      refute_receive {:external_http_request, _, _, _, _, _}, 200
      refute_received {:agent_chat_called, _, _}

      reply =
        space.id
        |> Chat.list_messages(limit: 10)
        |> Enum.find(&(&1.participant_id == agent_participant.id))

      assert reply
      assert reply.content == "Endpoint says hello"
      assert reply.metadata["trigger"] == "mention"

      assert :ok = GenServer.call(AttentionRouter, :__drain__)
    end

    test "a 500 from the endpoint persists no reply and posts the couldn't-reply notice" do
      space = create_space()
      user = create_participant(space.id)
      agent = create_external_http_agent()

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Relay")

      stub_completion(500, "should never be persisted")

      message = create_message(space.id, user.id, %{content: "@relay status?"})
      assert :ok = GenServer.call(AttentionRouter, :__drain__)

      assert_receive {:external_http_request, "POST", _, "/v1/chat/completions", _, _}, 1500
      assert :ok = GenServer.call(AttentionRouter, :__drain__)

      messages = Chat.list_messages(space.id, limit: 20)
      refute Enum.any?(messages, &(&1.participant_id == agent_participant.id))
      refute Enum.any?(messages, &(&1.content =~ "should never be persisted"))
      refute_received {:agent_chat_called, _, _}

      notice = Enum.find(messages, &Platform.Chat.ReplyFailure.notice?/1)
      assert notice, "no couldn't-reply notice was posted"
      assert notice.content =~ Platform.Chat.ReplyFailure.headline("Relay")
      assert notice.metadata["agent_id"] == agent.id
      assert notice.metadata["message_id"] == message.id
    end

    test "the request carries the same prior turns the built-in path sends" do
      # More prior turns than the history window holds, so the cap is part of
      # what must match.
      prior = for n <- 1..14, do: "prior turn #{n}"

      seed = fn agent, display_name ->
        space = create_space()
        user = create_participant(space.id)

        {:ok, agent_participant} =
          Chat.add_agent_participant(space.id, agent, display_name: display_name)

        prior
        |> Enum.with_index()
        |> Enum.each(fn {text, i} ->
          author = if rem(i, 3) == 2, do: agent_participant.id, else: user.id
          create_message(space.id, author, %{content: text})
        end)

        {space, user}
      end

      # Built-in path: what QuickAgent receives.
      built_in = create_agent(%{slug: "history-builtin-#{System.unique_integer([:positive])}"})
      {space_a, user_a} = seed.(built_in, "Zip")
      mention_a = create_message(space_a.id, user_a.id, %{content: "@zip summarise"})
      assert :ok = GenServer.call(AttentionRouter, :__drain__)
      assert_receive {:agent_chat_called, "@zip summarise", opts}, 1500

      expected_prior = Enum.map(opts[:history], &%{"role" => &1.role, "content" => &1.content})

      # External path, same fixture.
      external = create_external_http_agent()
      {space_b, user_b} = seed.(external, "Relay")
      stub_completion(200, "summary")
      mention_b = create_message(space_b.id, user_b.id, %{content: "@relay summarise"})
      assert :ok = GenServer.call(AttentionRouter, :__drain__)

      assert_receive {:external_http_request, "POST", _, _, _, %{"messages" => sent}}, 1500
      {sent_prior, [last]} = Enum.split(sent, -1)

      assert last == %{"role" => "user", "content" => "@relay summarise"}
      # 12-message window minus the triggering message itself.
      assert length(expected_prior) == 11
      assert sent_prior == expected_prior
      # Role + content only: attachment metadata never reaches the endpoint.
      assert Enum.all?(sent, &(Map.keys(&1) |> Enum.sort() == ["content", "role"]))
      refute Enum.any?(sent, &(&1["content"] =~ "prior turn 1\n"))

      assert :ok = GenServer.call(AttentionRouter, :__drain__)
    end

    test "regression: a built_in agent still calls the chat agent module, not HTTP" do
      space = create_space()
      user = create_participant(space.id)
      agent = create_agent(%{slug: "regress-builtin-#{System.unique_integer([:positive])}"})
      {:ok, _} = Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      stub_completion(200, "must not be called")
      message = create_message(space.id, user.id, %{content: "@zip ping"})
      assert :ok = GenServer.call(AttentionRouter, :__drain__)

      assert_receive {:agent_chat_called, "@zip ping", _opts}, 1500
      refute_received {:external_http_request, _, _, _, _, _}
      assert :ok = GenServer.call(AttentionRouter, :__drain__)
    end

    test "regression: runtime_type external still goes to the runtime channel, not HTTP" do
      {agent, topic} = federated_runtime("regress-runtime")
      space = create_space()
      user = create_participant(space.id)
      {:ok, _} = Chat.add_agent_participant(space.id, agent, display_name: "Envoy")

      stub_completion(200, "must not be called")
      message = create_message(space.id, user.id, %{content: "@envoy ping"})
      assert :ok = GenServer.call(AttentionRouter, :__drain__)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "attention",
                       payload: %{message: %{content: "@envoy ping"}}
                     },
                     1500

      assert :ok = GenServer.call(AttentionRouter, :__drain__)
      refute_received {:external_http_request, _, _, _, _, _}
      refute_received {:agent_chat_called, _, _}
    end
  end
end
