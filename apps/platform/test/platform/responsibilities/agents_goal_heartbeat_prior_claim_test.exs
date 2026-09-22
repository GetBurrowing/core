defmodule Platform.Responsibilities.AgentsGoalHeartbeatPriorClaimTest do
  @moduledoc """
  The last-beat claim bridge (task `01a0ca24` stage 3), driven through
  the FULL `Router.fire/2` native path with the capture-dispatcher
  harness from `agents_goal_heartbeat_fire_test.exs`.

  ## Why nothing here calls `handle_output/3`

  On the heartbeat's native path `Router.dispatch_native/6` never invokes
  `invoke_handle_output/3`, and AgentResponder has no return channel, so
  the only place the leader's words exist in production is a chat message
  it posts in the goal space. Every test therefore posts that message
  with `Chat.post_message/2` as the leader's agent participant and reads
  the claim back from the NEXT fire's prompt. A test that fed
  `handle_output/3` directly would pass against a bridge production never
  runs.

  ## Literals, never re-derived

  The prior-claim sentences are typed out, not built by calling
  `prior_claim_instruction/1`: a test that asks the function under test
  what it should have said passes against any wording.

  `async: false` -- the Router reads the native dispatcher from
  application env.
  """

  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.AgentsGoalHeartbeat, as: Handler
  alias Platform.Responsibilities.Router
  alias Platform.Roles
  alias Platform.Roles.Role
  alias Platform.Roles.RoleResponsibility

  @key "agents.goal_heartbeat"
  @role_key "agents_leader"
  @goal "Close backlog items in Suite"

  @first_beat "This is the first beat; there is no prior claim to check."
  @no_reply "Last beat got no reply from you in this space."
  @no_next_line "Last beat your reply named no next action."
  @claim_prefix "Last beat you said you would: "
  @claim_suffix ". Did it ship? Say yes or no and what changed."

  defmodule CaptureDispatcher do
    @moduledoc false
    def maybe_dispatch(signal) do
      pid = Application.get_env(:platform, :goal_heartbeat_prior_claim_capture_pid)
      if is_pid(pid), do: send(pid, {:captured_signal, signal})
      :ok
    end
  end

  setup do
    Application.put_env(:platform, :goal_heartbeat_prior_claim_capture_pid, self())

    on_exit(fn ->
      Application.delete_env(:platform, :goal_heartbeat_prior_claim_capture_pid)
    end)

    Application.put_env(
      :platform,
      :responsibility_router_native_dispatcher,
      {CaptureDispatcher, :maybe_dispatch}
    )

    on_exit(fn ->
      Application.delete_env(:platform, :responsibility_router_native_dispatcher)
    end)

    [spec] = Handler.register()
    {:ok, _row} = Responsibilities.upsert_by_key(spec)

    leader = wire_leader!()
    space = backlog_space!(leader)
    leader_participant = participant!(space, leader)

    %{leader: leader, space: space, leader_participant: leader_participant}
  end

  # ── fixtures ─────────────────────────────────────────────────────────

  defp wire_leader! do
    Repo.insert!(
      %Role{
        key: @role_key,
        name: "Agents Leader",
        description: "test fixture",
        icon: "hero-bolt"
      },
      on_conflict: :nothing,
      conflict_target: :key
    )

    %RoleResponsibility{}
    |> RoleResponsibility.changeset(%{role_key: @role_key, responsibility_key: @key})
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:role_key, :responsibility_key])

    agent = agent!("Claim Leader")
    {:ok, _} = Roles.assign_role(@role_key, agent.id)
    agent
  end

  defp agent!(name) do
    n = System.unique_integer([:positive])

    %Agent{}
    |> Agent.changeset(%{
      slug: "prior-claim-#{String.downcase(String.replace(name, " ", "-"))}-#{n}",
      name: "#{name} #{n}",
      status: "active",
      kind: "native",
      runtime_type: "external",
      workspace_id: nil
    })
    |> Repo.insert!()
  end

  defp backlog_space!(agent) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Agents prior-claim #{System.unique_integer([:positive])}",
        slug: "agents-prior-claim-#{System.unique_integer([:positive])}",
        kind: "channel",
        goal: @goal,
        leader_agent_id: agent.id
      })

    space
  end

  defp participant!(space, agent) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        display_name: agent.name,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp post!(space, participant, content) do
    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      })

    message
  end

  # Returns the captured signal. `{:ok, :dispatched}`, `assert_receive`
  # and the agent_id / goal asserts are the positive controls: without
  # them every `refute` below passes on a fire that never happened.
  defp fire!(leader) do
    {result, _log} =
      with_log([level: :info], fn ->
        Router.fire(@key, %{kind: :cron, fired_at: DateTime.utc_now()})
      end)

    assert {:ok, :dispatched} = result
    assert_receive {:captured_signal, signal}
    assert signal.metadata.agent_id == leader.id
    assert signal.metadata.prompt =~ @goal

    signal
  end

  defp fire_prompt!(leader), do: fire!(leader).metadata.prompt

  defp measured_at!(space) do
    %{"goal_heartbeat" => %{"measured_at" => stamp}} = Chat.get_space(space.id).metadata
    {:ok, at, _} = DateTime.from_iso8601(stamp)
    at
  end

  # ── the round trip ──────────────────────────────────────────────────

  test "round trip: fire 1 is the first beat, fire 2 puts the leader's Next: line back to it",
       %{leader: leader, space: space, leader_participant: lp} do
    assert fire_prompt!(leader) =~ @first_beat

    post!(space, lp, "Working it.\nNext: triage the 5 oldest backlog tasks")

    prompt = fire_prompt!(leader)

    assert prompt =~
             "Last beat you said you would: triage the 5 oldest backlog tasks. Did it ship?"

    refute prompt =~ @first_beat
    refute prompt =~ @no_reply
  end

  test "three fires: the claim is served once, the other agent's line never, then no reply",
       %{leader: leader, space: space, leader_participant: lp} do
    other = agent!("Other Agent")
    other_participant = participant!(space, other)

    assert fire_prompt!(leader) =~ @first_beat

    post!(space, other_participant, "Next: rewrite the router")
    post!(space, lp, "Picked the oldest backlog row.\nNext: close the 3 stale deploy tasks")

    prompt2 = fire_prompt!(leader)

    assert prompt2 =~
             "Last beat you said you would: close the 3 stale deploy tasks. Did it ship?"

    refute prompt2 =~ "rewrite the router"

    prompt3 = fire_prompt!(leader)

    assert prompt3 =~ @no_reply
    refute prompt3 =~ "close the 3 stale deploy tasks"
  end

  # ── the empty outcomes stay distinct ────────────────────────────────

  test "fire 2 with no leader reply says so, not first beat and not a claim",
       %{leader: leader} do
    assert fire_prompt!(leader) =~ @first_beat

    prompt = fire_prompt!(leader)

    assert prompt =~ @no_reply
    refute prompt =~ @first_beat
    refute prompt =~ @claim_prefix
  end

  test "fire 2 after a reply with no Next: line says the reply named no next action",
       %{leader: leader, space: space, leader_participant: lp} do
    assert fire_prompt!(leader) =~ @first_beat

    post!(space, lp, "Looked at the backlog. Nothing obvious to pick this hour.")

    prompt = fire_prompt!(leader)

    assert prompt =~ @no_next_line
    refute prompt =~ @no_reply
    refute prompt =~ @first_beat
    refute prompt =~ @claim_prefix
  end

  # ── the author filter ───────────────────────────────────────────────

  test "author filter: another agent's Next: line in the goal space is not the leader's claim",
       %{leader: leader, space: space} do
    other = agent!("Other Agent")
    other_participant = participant!(space, other)

    assert fire_prompt!(leader) =~ @first_beat

    post!(space, other_participant, "Next: rewrite the router")

    prompt = fire_prompt!(leader)

    refute prompt =~ "rewrite the router"
    assert prompt =~ @no_reply
  end

  # ── the window ──────────────────────────────────────────────────────

  test "window: a leader Next: message inserted before fire 1's measured_at is not read at fire 2",
       %{leader: leader, space: space, leader_participant: lp} do
    assert fire_prompt!(leader) =~ @first_beat
    fire1_at = measured_at!(space)

    # Posted after fire 1, then stamped a second BEFORE it, so only the
    # `inserted_at > since` bound can keep it out (not insertion order).
    message = post!(space, lp, "Next: ship the stale claim")
    backdated = DateTime.add(fire1_at, -1, :second)

    {1, _} =
      Repo.update_all(from(m in Message, where: m.id == ^message.id),
        set: [inserted_at: backdated]
      )

    prompt = fire_prompt!(leader)

    refute prompt =~ "ship the stale claim"
    assert prompt =~ @no_reply
  end

  # ── parsing ─────────────────────────────────────────────────────────

  test "the LAST Next: line of the reply is the claim, and it is capped at 280 characters",
       %{leader: leader, space: space, leader_participant: lp} do
    assert fire_prompt!(leader) =~ @first_beat

    long = String.duplicate("x", 400)
    post!(space, lp, "Next: the first plan\nChanged my mind.\n  next:   #{long}  ")

    prompt = fire_prompt!(leader)

    refute prompt =~ "the first plan"
    assert prompt =~ @claim_prefix <> String.duplicate("x", 280) <> @claim_suffix
    refute prompt =~ String.duplicate("x", 281)
  end

  # ── the space the reply lands in ────────────────────────────────────

  test "the signal names the goal space in metadata.space_id, not at the top level",
       %{leader: leader, space: space} do
    signal = fire!(leader)

    assert signal.metadata.space_id == space.id
    refute Map.has_key?(signal, :space_id)
  end

  # ── prior_claim_instruction/1 unit literals ─────────────────────────

  describe "prior_claim_instruction/1" do
    test "each state renders its own exact sentence" do
      assert Handler.prior_claim_instruction(%{status: :claimed, claim: "do X"}) ==
               "Last beat you said you would: do X. Did it ship? Say yes or no and what changed."

      assert Handler.prior_claim_instruction(%{status: :no_next_line}) == @no_next_line
      assert Handler.prior_claim_instruction(%{status: :no_reply}) == @no_reply
      assert Handler.prior_claim_instruction(%{status: :first_beat}) == @first_beat
    end

    test "the five renders are pairwise distinct, and :unavailable claims none of the four" do
      renders =
        [
          %{status: :claimed, claim: "do X"},
          %{status: :no_next_line},
          %{status: :no_reply},
          %{status: :first_beat},
          %{status: :unavailable}
        ]
        |> Enum.map(&Handler.prior_claim_instruction/1)

      assert length(Enum.uniq(renders)) == 5

      unavailable = List.last(renders)
      refute unavailable =~ @claim_prefix
      refute unavailable =~ @no_reply
      refute unavailable =~ @first_beat
      refute unavailable =~ @no_next_line
    end
  end
end
