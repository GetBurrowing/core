defmodule Platform.Responsibilities.AgentsGoalHeartbeatDriveTest do
  @moduledoc """
  The delegate roster and the zero/N drive branch (task `01a0ca24`
  stage 2), driven through the FULL `Router.fire/2` native path with the
  capture-dispatcher harness from `agents_goal_heartbeat_fire_test.exs`.

  ## Why every excluded agent here is CONNECTED

  The exclusion seed (`20260918150100_seed_known_delegation_exclusions.exs`)
  writes rows only for slugs that exist on the install, and a test DB has
  none of them; asserting that a named live agent is absent from the
  roster would pass with the filter deleted. Every absence asserted here
  is of a fixture agent this file itself connected, so it would be
  PRESENT if the filter it tests were gone:

    * the leader has a connected work runtime -> leader rejection;
    * an excluded agent has a connected work runtime and a
      `DelegationExclusion` row -> `eligible_agents/0`'s exclusion;
    * a voice-only agent has a connected `["meeting_voice"]` runtime ->
      `eligible_agents/0`'s voice filter.

  ## Literals, never re-derived

  The drive sentences below are typed out, not built by calling
  `drive_instruction/1`: a test that asks the function under test what
  it should have said passes against any wording.

  `async: false` -- `RuntimePresence` is a single named process.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Agents.DelegationExclusion
  alias Platform.Chat
  alias Platform.Federation.RuntimePresence
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

  @solo "You are the only agent working this goal. There is no one to delegate to; " <>
          "this is yours. Pick the single open item that most moves the measurement and " <>
          "work it this turn. Report what you picked and what changed."

  @delegate_drive "Pick the single open item that most moves the measurement. Assign it to " <>
                    "one of these agents by creating or assigning a task, or work it yourself " <>
                    "this turn. Report what you picked, who has it, and what changed.\n" <>
                    "Agents you can delegate to: "

  @roster_label "Agents you can delegate to"

  @reason "Excluded for the duration of this test with a sentence long enough to be a reason."

  defmodule CaptureDispatcher do
    @moduledoc false
    def maybe_dispatch(signal) do
      pid = Application.get_env(:platform, :goal_heartbeat_drive_capture_pid)
      if is_pid(pid), do: send(pid, {:captured_signal, signal})
      :ok
    end
  end

  setup do
    Application.put_env(:platform, :goal_heartbeat_drive_capture_pid, self())
    on_exit(fn -> Application.delete_env(:platform, :goal_heartbeat_drive_capture_pid) end)

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

    %{leader: leader, space: space}
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

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "goal-heartbeat-drive-leader-#{System.unique_integer([:positive])}",
        name: "Drive Leader #{System.unique_integer([:positive])}",
        status: "active",
        kind: "native",
        runtime_type: "external",
        workspace_id: nil
      })
      |> Repo.insert!()

    {:ok, _} = Roles.assign_role(@role_key, agent.id)

    agent
  end

  defp backlog_space!(agent) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Agents drive-test #{System.unique_integer([:positive])}",
        slug: "agents-drive-#{System.unique_integer([:positive])}",
        kind: "channel",
        goal: @goal,
        leader_agent_id: agent.id
      })

    space
  end

  # Mirrors `delegation_test.exs`.
  defp agent!(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "drive-#{String.downcase(String.replace(name, " ", "-"))}-#{n}",
      name: "#{name} #{n}",
      status: "active"
    })
  end

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      email: "drive-#{n}@example.com",
      name: "Drive Owner #{n}",
      oidc_sub: "oidc-drive-#{n}"
    })
  end

  defp runtime!(agent, features) do
    n = System.unique_integer([:positive])
    runtime_id = "drive-runtime-#{n}"

    Repo.insert!(%AgentRuntime{
      runtime_id: runtime_id,
      agent_id: agent.id,
      owner_user_id: user!().id,
      display_name: "Drive Runtime #{n}",
      status: "active",
      auth_token_hash: "hash-#{n}",
      metadata: %{"client_info" => %{"features" => features}}
    })

    RuntimePresence.track(runtime_id)
    on_exit(fn -> RuntimePresence.untrack(runtime_id) end)

    runtime_id
  end

  defp exclude!(agent) do
    %DelegationExclusion{}
    |> DelegationExclusion.changeset(%{
      agent_id: agent.id,
      reason_kind: "capability_judgement",
      reason: @reason,
      decided_by: "test"
    })
    |> Repo.insert!()
  end

  # Returns the captured prompt. `{:ok, :dispatched}`, `assert_receive`
  # and the agent_id / goal asserts are the positive controls: without
  # them every `refute` below passes on a fire that never happened.
  defp fire_prompt!(leader) do
    {result, _log} =
      with_log([level: :info], fn ->
        Router.fire(@key, %{kind: :cron, fired_at: DateTime.utc_now()})
      end)

    assert {:ok, :dispatched} = result
    assert_receive {:captured_signal, signal}
    assert signal.metadata.agent_id == leader.id
    assert signal.metadata.prompt =~ @goal

    signal.metadata.prompt
  end

  # The roster line only: the text after the label, up to the line end.
  defp roster_line(prompt) do
    case String.split(prompt, @roster_label <> ": ", parts: 2) do
      [_, rest] -> rest |> String.split("\n", parts: 2) |> hd()
      _ -> nil
    end
  end

  # ── zero / one / N ──────────────────────────────────────────────────

  test "0 delegates: the connected leader is not its own delegate, so the solo drive renders",
       %{leader: leader} do
    # The leader IS connected, so an unfiltered roster would be [leader]
    # and render the delegate drive. This is what makes the leader
    # rejection observable rather than vacuous.
    runtime!(leader, ["system_event_prompt"])

    prompt = fire_prompt!(leader)

    assert prompt =~ @solo
    refute prompt =~ @roster_label
    refute prompt =~ "(#{leader.id})"
  end

  test "1 delegate: the roster names it with its id and the solo drive is absent",
       %{leader: leader} do
    runtime!(leader, [])
    alpha = agent!("Delegate Alpha")
    runtime!(alpha, ["system_event_prompt"])

    prompt = fire_prompt!(leader)

    assert prompt =~ @delegate_drive <> "#{alpha.name} (#{alpha.id})"
    refute prompt =~ "You are the only agent working this goal"
    refute prompt =~ "There is no one to delegate to"
  end

  test "2 delegates: excluded, voice-only and leader agents are all connected and all absent",
       %{leader: leader} do
    runtime!(leader, ["system_event_prompt"])

    alpha = agent!("Delegate Alpha")
    beta = agent!("Delegate Beta")
    gamma = agent!("Excluded Gamma")
    delta = agent!("Voice Delta")

    runtime!(alpha, ["system_event_prompt"])
    runtime!(beta, [])
    runtime!(gamma, ["system_event_prompt"])
    exclude!(gamma)
    runtime!(delta, ["meeting_voice"])

    prompt = fire_prompt!(leader)

    refute prompt =~ "You are the only agent working this goal"

    line = roster_line(prompt)
    assert is_binary(line), "no roster line in prompt"

    # Name order ("Delegate Alpha" < "Delegate Beta"), exact entries.
    assert line == "#{alpha.name} (#{alpha.id}), #{beta.name} (#{beta.id})"

    refute line =~ gamma.name
    refute line =~ gamma.id
    refute line =~ delta.name
    refute line =~ delta.id
    refute line =~ leader.name
    refute line =~ leader.id
  end

  test "a role assignee distinct from the space leader is excluded too", %{
    leader: assignee,
    space: space
  } do
    # The Router dispatches to the role assignee; the space names its own
    # leader. Both are connected, neither may be offered to itself.
    space_leader = agent!("Space Leader")
    {:ok, _} = Chat.update_space(space, %{leader_agent_id: space_leader.id})

    runtime!(assignee, [])
    runtime!(space_leader, [])

    prompt = fire_prompt!(assignee)

    assert prompt =~ @solo
    refute prompt =~ @roster_label
  end

  test "the roster is re-read on every fire, not cached", %{leader: leader} do
    runtime!(leader, [])
    alpha = agent!("Delegate Alpha")
    beta = agent!("Delegate Beta")
    runtime!(alpha, [])
    beta_runtime = runtime!(beta, [])

    assert roster_line(fire_prompt!(leader)) ==
             "#{alpha.name} (#{alpha.id}), #{beta.name} (#{beta.id})"

    RuntimePresence.untrack(beta_runtime)

    assert roster_line(fire_prompt!(leader)) == "#{alpha.name} (#{alpha.id})"
  end

  # ── drive_instruction/1 unit literals ───────────────────────────────

  describe "drive_instruction/1" do
    test "[] is the solo sentence, exactly" do
      assert Handler.drive_instruction([]) == @solo
    end

    test "a roster is the delegate drive plus Name (id) entries joined with \", \"" do
      assert Handler.drive_instruction([
               %{agent_id: "id-a", name: "A"},
               %{agent_id: "id-b", name: "B"}
             ]) == @delegate_drive <> "A (id-a), B (id-b)"
    end

    test ":unavailable claims neither solitude nor a roster" do
      text = Handler.drive_instruction(:unavailable)

      assert text =~ "The delegate roster could not be read this hour"
      refute text =~ "There is no one to delegate to"
      refute text =~ @roster_label
    end
  end
end
