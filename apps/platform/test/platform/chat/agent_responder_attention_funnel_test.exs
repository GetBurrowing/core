defmodule Platform.Chat.AgentResponderAttentionFunnelTest do
  @moduledoc """
  Task 019fb90f stage 3 — `Platform.Chat.AgentResponder`'s two attention
  broadcasts go through `Platform.Federation.AttentionDispatch`.

  ## The point is the invariant, so the no-op has to be asserted BY NAME

  Both sites are expected to change no behaviour. `load_context/1` already
  refuses to build a chat context unless `Chat.get_agent_participant/2`
  resolves, so the chat path only ever reaches the funnel for an agent that is
  already a member; and a `system_event` fire names no space at all.

  A test that asserted "the broadcast still arrives" and left it there would be
  satisfied by a responder that never called the funnel — which is exactly the
  half-application the source-scan guard exists to catch, and exactly what a
  future edit here is most likely to reintroduce. So each test pins the specific
  `outcome` atom the funnel reported (`:already_member`, `:direct_space`,
  `:no_space_named`) AND that the roster did not move. Naming the outcome is
  what makes "nothing happened" evidence rather than absence of evidence.

  ## `space_id: nil` on the system_event path is a decision, not an omission

  `build_system_event_signal/2` deliberately keeps `space_id` off the wire:
  `claude-code-suite-channel`'s `attention.ts` pins a pending permission
  prompt's answer space to the top-level `signal.space_id`, so a background
  responsibility fire carrying one would relocate a live approval prompt to a
  space nobody is watching. The funnel taking the space as an OPTION is what
  lets this path route through it without inventing one. The system_event test
  therefore asserts BOTH halves: the funnel reported `:no_space_named`, and the
  delivered payload still has no `space_id` key.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Chat.AgentResponder
  alias Platform.Chat.Participant
  alias Platform.Federation.RuntimePresence
  alias Platform.Repo

  @invite_event [:platform, :chat, :dispatch_auto_invite]

  setup do
    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)
    on_exit(fn -> Application.put_env(:platform, :chat_agent_dispatch_mode, previous_mode) end)

    runtime_pres = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
    Sandbox.allow(Repo, self(), runtime_pres)

    :ok
  end

  # ── Fixtures ───────────────────────────────────────────────────────────────

  defp online_agent do
    n = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        email: "arf-#{n}@example.com",
        name: "ARF Owner #{n}",
        oidc_sub: "oidc-arf-#{n}"
      })

    runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: owner.id,
        status: "active",
        runtime_id: "rt-arf-#{n}",
        display_name: "arf-runtime-#{n}"
      })

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "arf-agent-#{n}",
        name: "ARF Agent #{n}",
        status: "active",
        runtime_type: "external",
        runtime_id: runtime.id
      })
      |> Repo.insert!()

    runtime = runtime |> Ecto.Changeset.change(%{agent_id: agent.id}) |> Repo.update!()

    RuntimePresence.track(runtime.runtime_id)
    on_exit(fn -> RuntimePresence.untrack(runtime.runtime_id) end)

    PlatformWeb.Endpoint.subscribe("runtime:#{runtime.runtime_id}")

    %{agent: agent, runtime: runtime}
  end

  defp channel_with(agent) do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, space} =
      Chat.create_space(%{name: "ARF #{n}", slug: "arf-space-#{n}", kind: "channel"})

    {:ok, participant} = Chat.add_agent_participant(space.id, agent, display_name: agent.name)

    {:ok, human} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Human #{n}",
        joined_at: DateTime.utc_now()
      })

    %{space: space, agent_participant: participant, human: human}
  end

  defp post(space_id, participant_id, content) do
    {:ok, message} =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant_id,
        content_type: "text",
        content: content
      })

    message
  end

  defp chat_signal(space, agent_participant, message) do
    %{
      reason: :mention,
      space_id: space.id,
      participant_id: agent_participant.id,
      message_id: message.id
    }
  end

  defp roster(space_id) do
    Repo.all(
      from(p in Participant,
        where: p.space_id == ^space_id,
        select: {p.participant_type, p.participant_id}
      )
    )
    |> MapSet.new()
  end

  defp attach_invite_telemetry do
    ref = make_ref()
    pid = self()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      @invite_event,
      fn _event, measurements, metadata, _cfg ->
        send(pid, {:auto_invite, ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  # ── Chat path ──────────────────────────────────────────────────────────────

  describe "dispatch_to_external/2" do
    test "reports :already_member and moves no rows" do
      ref = attach_invite_telemetry()
      %{agent: agent} = online_agent()
      %{space: space, agent_participant: agent_participant, human: human} = channel_with(agent)

      before = roster(space.id)
      message = post(space.id, human.id, "@#{agent.slug} take a look")

      assert :ok = AgentResponder.respond(chat_signal(space, agent_participant, message))

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000

      # Named, not implied. `{:ok, _}` or a bare `{:skip, _}` would be satisfied
      # by a responder that stopped calling the funnel at all.
      assert_receive {:auto_invite, ^ref, %{count: 1},
                      %{outcome: :already_member, source: :agent_responder, space_kind: "channel"}},
                     1_000

      assert roster(space.id) == before
    end

    test "a DM dispatch is refused as :direct_space and still delivers" do
      ref = attach_invite_telemetry()
      %{agent: agent} = online_agent()

      user =
        Repo.insert!(%User{
          email: "arf-dm-#{System.unique_integer([:positive])}@example.com",
          name: "DM Human",
          oidc_sub: "oidc-arf-dm-#{System.unique_integer([:positive])}"
        })

      {:ok, dm} = Chat.find_or_create_dm(user.id, "agent", agent.id)

      agent_participant = Chat.get_agent_participant(dm.id, agent.id)
      refute is_nil(agent_participant)

      human =
        Repo.one!(
          from(p in Participant, where: p.space_id == ^dm.id and p.participant_type == "user")
        )

      before = roster(dm.id)
      message = post(dm.id, human.id, "are you there")

      assert :ok = AgentResponder.respond(chat_signal(dm, agent_participant, message))

      # A DM agent is already a member — that is how it got dispatched — so the
      # interesting half is WHICH refusal the funnel reports. `:direct_space`
      # rather than `:already_member` proves the privacy guard is evaluated
      # before the membership pre-check, i.e. that the funnel would refuse an
      # agent that was NOT already in the DM. Collapsed to one atom, an
      # auto-invite could become a lever into a private conversation and this
      # test would not notice.
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000
      assert_receive {:auto_invite, ^ref, _, %{outcome: :direct_space, space_kind: "dm"}}, 1_000

      assert roster(dm.id) == before
    end
  end

  # ── system_event path ──────────────────────────────────────────────────────

  describe "broadcast_system_event/3" do
    test "reports :no_space_named, creates no membership anywhere, and adds no space_id to the wire" do
      ref = attach_invite_telemetry()
      %{agent: agent} = online_agent()

      signal = %{
        reason: :system_event,
        metadata: %{
          feature: "architecture",
          agent_id: agent.id,
          agent_slug: agent.slug,
          responsibility_key: "architecture.audit_diff",
          trigger_kind: :event_topic
        }
      }

      assert :ok = AgentResponder.respond(signal)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention", payload: payload}, 1_000

      assert_receive {:auto_invite, ^ref, _,
                      %{outcome: :no_space_named, source: :agent_responder, space_kind: nil}},
                     1_000

      # The other half of the same decision: routing through the funnel must not
      # have put a space on the wire. Asserted as the RESIDUE of the signal's
      # own keys — `refute payload.signal[:space_id]` would also pass on a nil
      # value that a client still reads as present.
      refute Map.has_key?(payload.signal, :space_id)

      # And nowhere did a membership row appear for this agent, in any space.
      assert Repo.aggregate(
               from(p in Participant,
                 where: p.participant_type == "agent" and p.participant_id == ^agent.id
               ),
               :count
             ) == 0
    end

    test "a fire whose metadata NAMES a space invites the agent into it" do
      # THE DEFECT THIS CLOSES (2026-08-01, Rowan's DM). A mid-meeting
      # classified intent routes to a responsibility whose assignee is a
      # native agent, and the prompt tells it to create or patch a canvas
      # "in this meeting's space". `broadcast_system_event/3` passed
      # `space_id: nil` unconditionally, so `ensure_writable/3` took the
      # `:no_space_named` skip and the agent was never a participant —
      # `Canvas.ToolHandlers.create/2` requires a resolved
      # `agent_participant_id`, so every one of those dispatches was dead
      # on arrival. Traced on the production meeting
      # `019fb8ec-8644-75a4-b764-cc859d082dce`: six intents dispatched,
      # zero invites, two genuine items lost.
      ref = attach_invite_telemetry()
      %{agent: agent} = online_agent()

      {:ok, space} =
        Chat.create_space(%{
          name: "Meeting #{System.unique_integer([:positive])}",
          slug: "arf-meeting-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      refute Chat.get_agent_participant(space.id, agent),
             "the agent must NOT be a member before the fire, or the invite proves nothing"

      signal = %{
        reason: :system_event,
        metadata: %{
          feature: "meetings",
          agent_id: agent.id,
          agent_slug: agent.slug,
          responsibility_key: "meetings.action_items",
          trigger_kind: :event_topic,
          intent_id: Ecto.UUID.generate(),
          # The carrier. `Responsibilities.Router.put_dispatch_space/2`
          # writes this from the provider's `:dispatch_space_id`.
          space_id: space.id
        }
      }

      assert :ok = AgentResponder.respond(signal)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention", payload: payload}, 1_000

      # Named, not `{:ok, _}`: `:already_member` would mean the fixture
      # invited it, and `:no_space_named` is the bug.
      assert_receive {:auto_invite, ^ref, %{count: 1},
                      %{
                        outcome: :invited,
                        source: :agent_responder,
                        space_kind: "channel",
                        space_id: invited_space
                      }},
                     1_000

      assert invited_space == space.id

      # The row is what makes the dispatch live, so assert the row and not
      # only the telemetry.
      assert %Participant{} = Chat.get_agent_participant(space.id, agent)

      # ── THE INVARIANT ───────────────────────────────────────────────────
      # Top-level `signal.space_id` must STILL be absent. The option fed
      # the invite; the wire is a separate argument it never touches. A
      # regression that "simplified" this by lifting the space onto the
      # signal would satisfy every assertion above while silently
      # relocating whatever permission prompt the receiving client had
      # pending — `attention.ts` pins that space from the top level ONLY.
      # Asserted as key ABSENCE, since a nil-valued key still reads as
      # present to the client.
      refute Map.has_key?(payload.signal, :space_id)

      # And the carrier IS on the wire, in metadata, where the same client
      # resolves a reply target ("rides this list as a reply target only").
      # Without this the two refutations above would also be satisfied by a
      # responder that dropped the space entirely.
      assert payload.signal.metadata.space_id == space.id
    end

    test "a blank space in metadata is still :no_space_named, not :invalid_space_id" do
      # `""` is not a space that failed to resolve — it is a producer that
      # named none. Reporting it as `:invalid_space_id` would page an
      # operator toward a malformed id that does not exist.
      ref = attach_invite_telemetry()
      %{agent: agent} = online_agent()

      signal = %{
        reason: :system_event,
        metadata: %{
          feature: "meetings",
          agent_id: agent.id,
          agent_slug: agent.slug,
          responsibility_key: "meetings.brief_worthy",
          trigger_kind: :event_topic,
          space_id: ""
        }
      }

      assert :ok = AgentResponder.respond(signal)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_000
      assert_receive {:auto_invite, ^ref, _, %{outcome: :no_space_named}}, 1_000
    end
  end
end
