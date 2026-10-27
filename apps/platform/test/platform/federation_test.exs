defmodule Platform.FederationTest do
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Access.RuntimeProfiles
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Repo

  defp create_user do
    Repo.insert!(%User{
      email: "fed_test_#{System.unique_integer([:positive])}@example.com",
      name: "Fed Test User",
      oidc_sub: "oidc-fed-test-#{System.unique_integer([:positive])}"
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

  # ── Auto-invite fixtures (task 019fb90f stage 2) ────────────────────────────
  #
  # The three `dispatch_*_attention/2` functions now broadcast through
  # `Platform.Federation.AttentionDispatch`, which invites the target agent into
  # the space the payload names BEFORE the signal goes out. These helpers let
  # the existing describe blocks assert that half.

  @invite_event [:platform, :chat, :dispatch_auto_invite]

  defp attach_invite_telemetry do
    handler_id = {__MODULE__, :invite, System.unique_integer([:positive])}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      @invite_event,
      fn _event, measurements, metadata, _ ->
        send(test_pid, {:auto_invite, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp create_space! do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, space} =
      Chat.create_space(%{name: "Fed Meeting #{n}", slug: "fed-meeting-#{n}", kind: "meeting"})

    space
  end

  defp agent_participant_count(space_id, agent_id) do
    Repo.aggregate(
      from(p in Platform.Chat.Participant,
        where:
          p.space_id == ^space_id and p.participant_type == "agent" and
            p.participant_id == ^agent_id
      ),
      :count
    )
  end

  defp link_runtime!(agent, prefix) do
    user = create_user()
    runtime_id = "#{prefix}-#{System.unique_integer([:positive])}"
    {:ok, runtime} = Federation.register_runtime(user.id, %{runtime_id: runtime_id})
    {:ok, _linked} = Federation.link_agent(runtime, agent)
    PlatformWeb.Endpoint.subscribe("runtime:#{runtime_id}")
    runtime_id
  end

  describe "register_runtime/2" do
    test "creates a runtime with pending status" do
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      assert runtime.status == "pending"
      assert runtime.owner_user_id == user.id
      assert runtime.transport == "websocket"
      assert runtime.trust_level == "participant"
    end
  end

  describe "activate_runtime/1" do
    test "changes status to active and returns token" do
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      {:ok, activated, raw_token} = Federation.activate_runtime(runtime)

      assert activated.status == "active"
      assert is_binary(raw_token)
      assert activated.auth_token_hash != nil
      # Verify token validates
      assert AgentRuntime.verify_token(raw_token, activated.auth_token_hash)
    end
  end

  describe "RuntimeProfiles.set_tool_profile/2" do
    test "replaces the ordered module profile when all values are valid" do
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      {:ok, updated} = RuntimeProfiles.set_tool_profile(runtime, ~w(federation space task plan))

      assert updated.tool_profile == ~w(federation space task plan)
    end

    test "rejects bundle values outside the valid set" do
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      assert {:error, :invalid_module} =
               RuntimeProfiles.set_tool_profile(runtime, ~w(federation not_a_bundle))
    end

    test "accepts an empty list (denies all bundles)" do
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      {:ok, updated} = RuntimeProfiles.set_tool_profile(runtime, [])
      assert updated.tool_profile == []
    end
  end

  describe "link_agent/2" do
    test "associates an agent with the runtime" do
      user = create_user()
      agent = create_agent()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      {:ok, linked_agent} = Federation.link_agent(runtime, agent)
      assert linked_agent.runtime_type == "external"
      assert linked_agent.runtime_id == runtime.id
    end

    test "auto-adds the federated agent to every non-archived channel space in its workspace" do
      alias Platform.Chat.Space

      workspace_id = Ecto.UUID.generate()

      {:ok, general} =
        %Space{}
        |> Space.changeset(%{
          workspace_id: workspace_id,
          name: "General",
          slug: "general-#{System.unique_integer([:positive])}",
          kind: "channel"
        })
        |> Repo.insert()

      {:ok, random} =
        %Space{}
        |> Space.changeset(%{
          workspace_id: workspace_id,
          name: "Random",
          slug: "random-#{System.unique_integer([:positive])}",
          kind: "channel"
        })
        |> Repo.insert()

      # Archived space should NOT get the agent rostered.
      {:ok, archived} =
        %Space{}
        |> Space.changeset(%{
          workspace_id: workspace_id,
          name: "Archived",
          slug: "archived-#{System.unique_integer([:positive])}",
          kind: "channel",
          archived_at: DateTime.utc_now()
        })
        |> Repo.insert()

      agent = create_agent(%{workspace_id: workspace_id})
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      {:ok, _} = Federation.link_agent(runtime, agent)

      general_entry = Chat.get_space_agent(general.id, agent.id)
      assert general_entry.role == "member"

      random_entry = Chat.get_space_agent(random.id, agent.id)
      assert random_entry.role == "member"

      refute Chat.get_space_agent(archived.id, agent.id)
    end

    test "auto-roster adds nil-workspace agents to nil-workspace channel spaces (single-tenant)" do
      alias Platform.Chat.Space

      # Single-tenant / default-org setup: both agents and spaces have
      # workspace_id: nil. Auto-roster must still match them together.
      {:ok, general} =
        %Space{}
        |> Space.changeset(%{
          workspace_id: nil,
          name: "General",
          slug: "general-#{System.unique_integer([:positive])}",
          kind: "channel"
        })
        |> Repo.insert()

      agent = create_agent()
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      {:ok, linked} = Federation.link_agent(runtime, agent)
      assert is_nil(linked.workspace_id)

      assert %{role: "member"} = Chat.get_space_agent(general.id, agent.id)
    end

    test "auto-roster does NOT leak across workspaces" do
      alias Platform.Chat.Space

      # Agent in workspace A should NOT be rostered into workspace B's spaces.
      workspace_a = Ecto.UUID.generate()
      workspace_b = Ecto.UUID.generate()

      {:ok, space_a} =
        %Space{}
        |> Space.changeset(%{
          workspace_id: workspace_a,
          name: "A",
          slug: "a-#{System.unique_integer([:positive])}",
          kind: "channel"
        })
        |> Repo.insert()

      {:ok, space_b} =
        %Space{}
        |> Space.changeset(%{
          workspace_id: workspace_b,
          name: "B",
          slug: "b-#{System.unique_integer([:positive])}",
          kind: "channel"
        })
        |> Repo.insert()

      agent_a = create_agent(%{workspace_id: workspace_a})
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      {:ok, _} = Federation.link_agent(runtime, agent_a)

      assert Chat.get_space_agent(space_a.id, agent_a.id)
      refute Chat.get_space_agent(space_b.id, agent_a.id)
    end

    test "auto-roster is idempotent when called again on an already-rostered agent" do
      alias Platform.Chat.Space

      workspace_id = Ecto.UUID.generate()

      {:ok, general} =
        %Space{}
        |> Space.changeset(%{
          workspace_id: workspace_id,
          name: "General",
          slug: "general-#{System.unique_integer([:positive])}",
          kind: "channel"
        })
        |> Repo.insert()

      agent = create_agent(%{workspace_id: workspace_id})

      :ok = Federation.auto_roster_federated_agent(agent)
      :ok = Federation.auto_roster_federated_agent(agent)

      # Idempotent: a second auto_roster call does not create a second row.
      entries =
        Chat.list_space_agents(general.id) |> Enum.filter(&(&1.agent_id == agent.id))

      assert length(entries) == 1
    end
  end

  describe "generate_runtime_token/1" do
    test "returns a valid token" do
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      {:ok, updated, raw_token} = Federation.generate_runtime_token(runtime)

      assert is_binary(raw_token)
      assert AgentRuntime.verify_token(raw_token, updated.auth_token_hash)
    end
  end

  describe "get_runtime_by_token/1" do
    test "finds an active runtime by its token" do
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      {:ok, _activated, raw_token} = Federation.activate_runtime(runtime)

      found = Federation.get_runtime_by_token(raw_token)
      assert found != nil
      assert found.id == runtime.id
    end

    test "returns nil for invalid token" do
      assert Federation.get_runtime_by_token("bogus-token") == nil
    end
  end

  describe "suspend_runtime/1 and revoke_runtime/1" do
    test "suspend changes status" do
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      {:ok, activated, _token} = Federation.activate_runtime(runtime)
      {:ok, suspended} = Federation.suspend_runtime(activated)
      assert suspended.status == "suspended"
    end

    test "revoke clears the token hash" do
      user = create_user()

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{
          runtime_id: "test-runtime-#{System.unique_integer([:positive])}"
        })

      {:ok, activated, _token} = Federation.activate_runtime(runtime)
      {:ok, revoked} = Federation.revoke_runtime(activated)
      assert revoked.status == "revoked"
      assert revoked.auth_token_hash == nil
    end
  end

  describe "dispatch_scribe_attention/2" do
    @scribe_event [:platform, :meetings, :scribe_dispatch, :assignee_unresolvable]

    setup do
      # Detach any historian telemetry handler so tests observing the fallback
      # event do not race with the audit-trail writer.
      handler_id = "test-scribe-dispatch-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        @scribe_event,
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      attach_invite_telemetry()
      :ok
    end

    test "invites the scribe into the named space BEFORE the signal goes out" do
      # The behavioural half of task 019fb90f stage 2.
      # `Meetings.maybe_dispatch_scribe_attention/1` already puts
      # `transcript.space_id` in this payload, so wiring the funnel makes the
      # scribe writable in the meeting's chat space with no payload change.
      agent = create_agent()
      space = create_space!()
      _runtime_id = link_runtime!(agent, "scribe-invite-rt")

      # Negative control. Without it, "there is a row afterwards" is equally
      # consistent with "there was always a row".
      assert agent_participant_count(space.id, agent.id) == 0

      assert :ok =
               Federation.dispatch_scribe_attention(agent.id, %{
                 reason: "meeting_scribe_completion",
                 space_id: space.id,
                 room_id: "space-scribe-invite",
                 transcript_id: Ecto.UUID.generate()
               })

      # Positional read: the invite must land before the broadcast, not merely
      # alongside it. A runtime can act on the signal within milliseconds.
      assert_receive first, 500
      assert {:auto_invite, %{count: 1}, %{outcome: :invited, source: :meeting_scribe}} = first

      assert_receive second, 500
      assert %Phoenix.Socket.Broadcast{event: "attention"} = second

      assert %Platform.Chat.Participant{attention_mode: "mention", role: "member"} =
               Chat.get_agent_participant(space.id, agent.id)
    end

    test "a nil space_id still delivers, invites nobody, and says :no_space_named" do
      # `transcript.space_id` is nullable (`@optional_fields` on the Transcript
      # schema), so this is a live production path, not a defensive one. The
      # outcome atom is what keeps it distinguishable from a deleted space.
      agent = create_agent()
      runtime_id = link_runtime!(agent, "scribe-nilspace-rt")

      assert :ok =
               Federation.dispatch_scribe_attention(agent.id, %{
                 reason: "meeting_scribe_completion",
                 space_id: nil,
                 room_id: "space-scribe-nil",
                 transcript_id: Ecto.UUID.generate()
               })

      assert_receive %Phoenix.Socket.Broadcast{topic: topic, event: "attention"}, 500
      assert topic == "runtime:#{runtime_id}"
      assert_receive {:auto_invite, _, %{outcome: :no_space_named, source: :meeting_scribe}}, 500

      assert Repo.aggregate(
               from(p in Platform.Chat.Participant,
                 where: p.participant_type == "agent" and p.participant_id == ^agent.id
               ),
               :count
             ) == 0
    end

    test "broadcasts an attention signal to the linked runtime and returns :ok" do
      user = create_user()
      agent = create_agent()

      runtime_id = "scribe-runtime-#{System.unique_integer([:positive])}"

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{runtime_id: runtime_id})

      {:ok, _linked_agent} = Federation.link_agent(runtime, agent)

      PlatformWeb.Endpoint.subscribe("runtime:#{runtime_id}")

      transcript_id = Ecto.UUID.generate()
      space_id = Ecto.UUID.generate()

      payload = %{
        reason: "meeting_scribe_completion",
        space_id: space_id,
        room_id: "space-scribe",
        transcript_id: transcript_id
      }

      assert :ok = Federation.dispatch_scribe_attention(agent.id, payload)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{
                         signal: %{
                           reason: "meeting_scribe_completion",
                           space_id: ^space_id,
                           room_id: "space-scribe",
                           transcript_id: ^transcript_id
                         }
                       }
                     },
                     500

      refute_received {:telemetry, @scribe_event, _, _}

      # This payload names a space that has no `chat_spaces` row. That was
      # incidental before the funnel existed; now it is the `:space_not_found`
      # path, and pinning it here keeps a deleted space distinguishable from a
      # dispatch that named none.
      assert_received {:auto_invite, _, %{outcome: :space_not_found}}
    end

    test "emits :agent_not_found telemetry and returns an error when the agent id is unknown" do
      missing_id = Ecto.UUID.generate()

      assert {:error, :agent_not_found} =
               Federation.dispatch_scribe_attention(missing_id, %{
                 reason: "meeting_scribe_completion"
               })

      assert_receive {:telemetry, @scribe_event, %{count: 1},
                      %{
                        agent_id: ^missing_id,
                        reason: :agent_not_found,
                        actor_type: "system",
                        resource_type: "agent",
                        resource_id: ^missing_id
                      }},
                     500

      # Resolution failures short-circuit BEFORE the funnel, so no auto-invite
      # is attempted. Asserting this keeps `assignee_unresolvable` and
      # `dispatch_auto_invite` reporting on two genuinely different situations
      # rather than double-counting one.
      refute_received {:auto_invite, _, _}
    end

    test "emits :runtime_unresolvable telemetry when the agent has no linked runtime" do
      agent = create_agent()

      assert {:error, :runtime_unresolvable} =
               Federation.dispatch_scribe_attention(agent.id, %{
                 reason: "meeting_scribe_completion"
               })

      assert_receive {:telemetry, @scribe_event, %{count: 1},
                      %{
                        agent_id: agent_id,
                        reason: :runtime_unresolvable,
                        actor_type: "system",
                        resource_type: "agent",
                        resource_id: resource_id
                      }},
                     500

      assert agent_id == agent.id
      assert resource_id == agent.id
      refute_received {:auto_invite, _, _}
    end
  end

  describe "dispatch_triage_attention/2" do
    @triage_event [:platform, :meetings, :triage_dispatch, :assignee_unresolvable]

    setup do
      # Detach any historian telemetry handler so tests observing the fallback
      # event do not race with the audit-trail writer.
      handler_id = "test-triage-dispatch-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        @triage_event,
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      attach_invite_telemetry()
      :ok
    end

    test "invites the triage officer into the named space, attributed to :meeting_triage" do
      # Scribe and triage dispatch into the SAME meeting space, so `:source` is
      # the only thing that makes an auto-invite attributable. A funnel that
      # dropped `:source`, or passed the scribe's, would leave an operator
      # unable to tell which dispatcher resurrected a dismissed agent — the
      # ADR-0038 tradeoff stage 1 accepted only because it stays observable.
      agent = create_agent()
      space = create_space!()
      _runtime_id = link_runtime!(agent, "triage-invite-rt")

      assert agent_participant_count(space.id, agent.id) == 0

      assert :ok =
               Federation.dispatch_triage_attention(agent.id, %{
                 reason: "meeting_triage_dispatch",
                 space_id: space.id,
                 room_id: "space-triage-invite",
                 transcript_id: Ecto.UUID.generate(),
                 canvas_id: Ecto.UUID.generate()
               })

      assert_receive first, 500
      assert {:auto_invite, %{count: 1}, %{outcome: :invited, source: :meeting_triage}} = first

      assert_receive second, 500
      assert %Phoenix.Socket.Broadcast{event: "attention"} = second

      assert agent_participant_count(space.id, agent.id) == 1
    end

    test "broadcasts an attention signal to the linked runtime and returns :ok" do
      user = create_user()
      agent = create_agent()

      runtime_id = "triage-runtime-#{System.unique_integer([:positive])}"

      {:ok, runtime} =
        Federation.register_runtime(user.id, %{runtime_id: runtime_id})

      {:ok, _linked_agent} = Federation.link_agent(runtime, agent)

      PlatformWeb.Endpoint.subscribe("runtime:#{runtime_id}")

      transcript_id = Ecto.UUID.generate()
      canvas_id = Ecto.UUID.generate()
      space_id = Ecto.UUID.generate()

      payload = %{
        reason: "meeting_triage_dispatch",
        space_id: space_id,
        room_id: "space-triage",
        transcript_id: transcript_id,
        canvas_id: canvas_id
      }

      assert :ok = Federation.dispatch_triage_attention(agent.id, payload)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{
                         signal: %{
                           reason: "meeting_triage_dispatch",
                           space_id: ^space_id,
                           room_id: "space-triage",
                           transcript_id: ^transcript_id,
                           canvas_id: ^canvas_id
                         }
                       }
                     },
                     500

      refute_received {:telemetry, @triage_event, _, _}

      # This payload names a space that has no `chat_spaces` row. That was
      # incidental before the funnel existed; now it is the `:space_not_found`
      # path, and pinning it here keeps a deleted space distinguishable from a
      # dispatch that named none.
      assert_received {:auto_invite, _, %{outcome: :space_not_found}}
    end

    test "emits :agent_not_found telemetry and returns an error when the agent id is unknown" do
      missing_id = Ecto.UUID.generate()

      assert {:error, :agent_not_found} =
               Federation.dispatch_triage_attention(missing_id, %{
                 reason: "meeting_triage_dispatch"
               })

      assert_receive {:telemetry, @triage_event, %{count: 1},
                      %{
                        agent_id: ^missing_id,
                        reason: :agent_not_found,
                        actor_type: "system",
                        resource_type: "agent",
                        resource_id: ^missing_id
                      }},
                     500

      refute_received {:auto_invite, _, _}
    end

    test "emits :runtime_unresolvable telemetry when the agent has no linked runtime" do
      agent = create_agent()

      assert {:error, :runtime_unresolvable} =
               Federation.dispatch_triage_attention(agent.id, %{
                 reason: "meeting_triage_dispatch"
               })

      assert_receive {:telemetry, @triage_event, %{count: 1},
                      %{
                        agent_id: agent_id,
                        reason: :runtime_unresolvable,
                        actor_type: "system",
                        resource_type: "agent",
                        resource_id: resource_id
                      }},
                     500

      assert agent_id == agent.id
      assert resource_id == agent.id
      refute_received {:auto_invite, _, _}
    end
  end
end
