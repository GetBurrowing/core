defmodule Platform.Chat.AgentResponderSystemEventPayloadTest do
  # ─────────────────────────────────────────────────────────────────────────────
  # ENVELOPE-RECORD 1/3 — system_event attention envelope
  # DECIDED: the system_event attention envelope is BARE — `%{signal: ...}` and
  #   nothing else. `signal.prompt` is the sole named interface for the body,
  #   and the payload carries NO `:message` key. The assertions in this file are
  #   what hold that contract in place.
  # WHY: adding `message` here would paper over the client defect rather than
  #   fix it, and this test is what makes that a deliberate, visible choice.
  # WHAT WOULD RETIRE THIS: the condition record 2/3 states — the argument above
  #   rests on a client that silently DROPS this envelope and swallows the
  #   throw, so a server-side `message` mirror would have hidden an invisible
  #   client defect. Once a client no longer drops the envelope and no longer
  #   swallows the throw, the papering-over argument no longer applies, and
  #   "should the server also emit `message`?" is reopenable on its merits.
  # RETIREMENT STATUS 2026-07-31: MET — `019fa618-ca92` has landed. The sibling
  #   repo `openclaw-suite-channel` is at v0.6.9 (`429dfd5`), which contains fix
  #   commit `3f014a1`; its `dist/src/inbound.js` now reads
  #   `const author = payload.message?.author;` — optional-chained, where it
  #   previously read `payload.message.author` bare — and
  #   `openclaw-gateway.service` has run that build since 2026-07-31 12:40:00
  #   CDT.
  #   THE ASSERTIONS IN THIS FILE ARE UNCHANGED AND THEY STAY. Nothing about
  #   this status line makes this test optional, weaker, or safe to delete: the
  #   task that stamped it changed comments and one helper name and touched no
  #   assertion. A met condition makes the question ASKABLE; it does not answer
  #   it. Retiring these assertions is a separate decision requiring its own
  #   argument and its own ticket — annotating a guard is not retiring one.
  # SIBLING RECORDS:
  #   2/3 core:apps/platform/lib/platform/chat/agent_responder.ex § build_system_event_payload/1 (019fa510)
  #   3/3 claude-code-suite-channel:src/attention.ts § makeEmitAttention (019fa618-c860)
  # ─────────────────────────────────────────────────────────────────────────────
  # CHARACTERIZATION — the "attention" envelope asymmetry (019fa56b stage 1).
  #
  # Core broadcasts `"attention"` on `runtime:<id>` from THREE sites, and they
  # do NOT agree on where the human-readable body lives:
  #
  #   1. core:apps/platform/lib/platform/orchestration/task_router.ex
  #      § dispatch_attention/5
  #      → `payload.message.content`   (pinned in `task_router_test.exs`)
  #   2. core:apps/platform/lib/platform/chat/agent_responder.ex
  #      § dispatch_to_external/2
  #      → `payload.message.content`   (pinned here)
  #   3. core:apps/platform/lib/platform/chat/agent_responder.ex
  #      § broadcast_system_event/3
  #      → `payload.signal.prompt`, and there is NO `:message` key at all
  #                                   (pinned here)
  #
  # The Claude Code bridge READ `payload.message?.content ?? ""` at
  # `claude-code-suite-channel@4691bdb`, which is the read this file was written
  # against. Sites 1 and 2 satisfied that read; site 3 did not, so its body was
  # silently discarded and a broken runtime still rendered task dispatches
  # perfectly. That was the whole defect, and it was invisible precisely because
  # two of three shapes worked. As of `claude-code-suite-channel@4edd170` the
  # bridge reads `payload.message?.content ?? payload.signal?.prompt ?? ""` in
  # `claude-code-suite-channel:src/attention.ts § makeEmitAttention` — the
  # fallback landed, so site 3's body is recovered there now. The envelope
  # contract asserted below is unchanged by that; see the retirement status
  # above.
  #
  # WHY THESE ASSERTIONS ARE SHAPED THE WAY THEY ARE: a test that only says
  # "the prompt is reachable somewhere in the payload" passes on all three
  # shapes and therefore pins nothing. Every case below asserts the CONCRETE
  # key path against a per-test sentinel string, and the one absence assertion
  # (`refute Map.has_key?(payload, :message)`) never stands alone — it always
  # sits next to a positive assertion on the same received payload, so it
  # cannot pass on a dispatch that never fired.
  #
  # `pre_fix_bridge_content/1` below is a literal transcription of the bridge's
  # read AS IT WAS at `claude-code-suite-channel@4691bdb`
  # (`payload.message?.content ?? ""`). It exists so the asymmetry itself — not
  # just the two shapes — is the thing under test. The live read now lives in
  # `claude-code-suite-channel:src/attention.ts § makeEmitAttention` and carries
  # a `signal.prompt` fallback; the helper deliberately does NOT track it,
  # because what it models is the pre-fix read that this asymmetry breaks.
  # ─────────────────────────────────────────────────────────────────────────────
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

  setup do
    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)
    on_exit(fn -> Application.put_env(:platform, :chat_agent_dispatch_mode, previous_mode) end)

    router =
      Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})

    Sandbox.allow(Repo, self(), router)

    presence =
      Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)

    Sandbox.allow(Repo, self(), presence)

    :ok
  end

  describe "site 3 — broadcast_system_event/3 (chatless responsibility fire)" do
    test "body lives at signal.prompt and the payload carries NO :message key" do
      sentinel = "SENTINEL-WAKE-#{Ecto.UUID.generate()}"
      %{runtime: runtime, agent: agent} = federated_agent("higgins-sysev")

      topic = "runtime:#{runtime.runtime_id}"
      :ok = PlatformWeb.Endpoint.subscribe(topic)

      assert :ok =
               AgentResponder.respond(%{
                 reason: :system_event,
                 metadata: %{
                   agent_id: agent.id,
                   agent_slug: agent.slug,
                   responsibility_key: "design.task_direction",
                   feature: "design",
                   trigger_kind: :cron,
                   prompt: sentinel
                 }
               })

      payload = assert_attention(topic)

      # PRESENCE first — the load-bearing half. Everything below is only
      # meaningful because this dispatch demonstrably fired with a body.
      assert payload.signal.prompt == sentinel

      # The Router's original stash still round-trips untouched alongside the
      # lifted copy. `build_system_event_signal/2` keeps `metadata` whole
      # (core:apps/platform/lib/platform/chat/agent_responder.ex §
      # build_system_event_signal/2), so a runtime reading either path agrees.
      assert payload.signal.metadata.prompt == sentinel

      assert payload.signal.reason == :system_event
      assert payload.signal.responsibility_key == "design.task_direction"
      assert payload.signal.feature == "design"
      assert payload.signal.trigger_kind == :cron
      assert payload.signal.agent_id == agent.id
      assert payload.signal.agent_slug == agent.slug

      # ABSENCE — asserted ONLY alongside the presence assertions above, on the
      # same received payload. This is the half a bridge reading
      # `payload.message.content` falls off.
      refute Map.has_key?(payload, :message)

      # The system_event envelope is BARE: `%{signal: ...}` and nothing else
      # (core:apps/platform/lib/platform/chat/agent_responder.ex §
      # build_system_event_payload/1). Site 2's `history` / `context` / `tools` keys
      # are absent here too. Pinned so a future "normalize the attention
      # payload" refactor cannot quietly widen this envelope — adding
      # `message` here would paper over the client defect rather than fix it,
      # and this test is what makes that a deliberate, visible choice.
      assert Map.keys(payload) == [:signal]

      RuntimePresence.untrack(runtime.runtime_id)
      _ = AgentRuntime
    end

    test "a bridge reading payload.message.content recovers NOTHING from this shape" do
      sentinel = "SENTINEL-WAKE-#{Ecto.UUID.generate()}"
      %{runtime: runtime, agent: agent} = federated_agent("higgins-sysev-bridge")

      topic = "runtime:#{runtime.runtime_id}"
      :ok = PlatformWeb.Endpoint.subscribe(topic)

      assert :ok =
               AgentResponder.respond(%{
                 reason: :system_event,
                 metadata: %{
                   agent_id: agent.id,
                   agent_slug: agent.slug,
                   responsibility_key: "design.task_direction",
                   prompt: sentinel
                 }
               })

      payload = assert_attention(topic)

      # The body IS present in the envelope…
      assert payload.signal.prompt == sentinel
      # …and the pre-fix bridge read still yields the empty string. Both halves
      # in one test: the drop is a client-side read gap, not a missing body.
      assert pre_fix_bridge_content(payload) == ""

      RuntimePresence.untrack(runtime.runtime_id)
      _ = AgentRuntime
    end
  end

  describe "site 2 — dispatch_to_external/2 (chat-triggered attention)" do
    test "body lives at message.content and the bridge read recovers it" do
      sentinel = "SENTINEL-CHAT-#{Ecto.UUID.generate()}"
      %{runtime: runtime, agent: agent} = federated_agent("ext-chat")

      space = create_space()
      user = create_participant(space.id)
      {:ok, _} = Chat.add_agent_participant(space.id, agent, display_name: "Ext")

      topic = "runtime:#{runtime.runtime_id}"
      :ok = PlatformWeb.Endpoint.subscribe(topic)

      trigger = create_message(space.id, user.id, %{content: "@#{agent.slug} #{sentinel}"})
      assert {:ok, _} = AttentionRouter.route(trigger)

      payload = assert_attention(topic)

      # The contrast case. Same event name, same topic, DIFFERENT key path.
      assert payload.message.content =~ sentinel
      assert payload.message.author == "Alice"
      assert pre_fix_bridge_content(payload) =~ sentinel

      # And the mirror image of site 3's absence: the chat envelope has no
      # `signal.prompt`, so a client that ONLY learned to read `signal.prompt`
      # would break this path. Pinning both directions is what stops stage 4's
      # client fix from being a swap instead of a fallback.
      refute Map.has_key?(payload.signal, :prompt)

      # The chat envelope is the wide one — these keys are exactly what
      # site 3 lacks.
      assert Map.has_key?(payload, :history)
      assert Map.has_key?(payload, :context)
      assert Map.has_key?(payload, :tools)

      assert :ok = GenServer.call(AttentionRouter, :__drain__)
      RuntimePresence.untrack(runtime.runtime_id)
      _ = AgentRuntime
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # Transcription of the PRE-FIX bridge read, as it stood in
  # `claude-code-suite-channel:src/index.ts` at commit `4691bdb`:
  #   const text = payload.message?.content ?? "";
  #
  # Named `pre_fix_` because that read is history. The live bridge read moved
  # FILE — it is now in `claude-code-suite-channel:src/attention.ts §
  # makeEmitAttention` and reads
  # `payload.message?.content ?? payload.signal?.prompt ?? ""`. This helper
  # intentionally still models the narrow pre-fix read: it is the read that the
  # site-3 envelope defeats, and that defeat is the property under test.
  defp pre_fix_bridge_content(payload) do
    case payload do
      %{message: %{content: content}} when is_binary(content) -> content
      _ -> ""
    end
  end

  defp assert_attention(topic) do
    assert_receive %Phoenix.Socket.Broadcast{
                     topic: ^topic,
                     event: "attention",
                     payload: payload
                   },
                   1500

    payload
  end

  defp federated_agent(slug) do
    n = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        email: "sysev-#{n}@example.com",
        name: "SysEv Owner",
        oidc_sub: "oidc-sysev-#{n}"
      })

    runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: owner.id,
        status: "active",
        runtime_id: "rt-sysev-#{n}",
        display_name: "#{slug}-runtime"
      })

    RuntimePresence.track(runtime.runtime_id)

    agent =
      create_agent(%{
        slug: slug,
        name: "SysEv",
        runtime_type: "external",
        runtime_id: runtime.id
      })

    %{runtime: runtime, agent: agent}
  end

  defp create_agent(attrs) do
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

  defp create_space do
    {:ok, space} =
      Chat.create_space(%{
        name: "SysEv Payload",
        slug: "sysev-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp create_participant(space_id) do
    {:ok, participant} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Alice",
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp create_message(space_id, participant_id, attrs) do
    {:ok, message} =
      Chat.post_message(
        Map.merge(
          %{space_id: space_id, participant_id: participant_id, content_type: "text"},
          attrs
        )
      )

    message
  end
end
