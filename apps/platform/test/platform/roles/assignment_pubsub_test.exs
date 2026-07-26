defmodule Platform.Roles.AssignmentPubSubTest do
  @moduledoc """
  Tests for the `roles:assignments` broadcast added by task 019f70b8
  stage 7.

  The intents-collapse bar is DOM-absent when `meeting_producer` is
  unassigned (AC13). Without a notification, a producer appointed
  mid-meeting would not see the panel until they reloaded — which, for
  a live meeting surface, is the same as never. This is the seam that
  makes the fade-in possible; `PlatformWeb.MeetingLiveTest` pins the
  behaviour it enables.
  """
  use Platform.DataCase, async: true

  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Roles

  setup do
    Roles.subscribe_assignments()
    on_exit(&Roles.unsubscribe_assignments/0)
    :ok
  end

  defp create_agent! do
    Repo.insert!(%Agent{
      slug: "roles-pubsub-#{System.unique_integer([:positive])}",
      name: "Roles PubSub Agent",
      status: "active"
    })
  end

  test "assign_role/2 broadcasts the post-state" do
    agent = create_agent!()

    {:ok, _} = Roles.assign_role("meeting_producer", agent.id)

    # Pinned to this agent's id inside the pattern rather than asserted
    # after the match: the topic is suite-wide, so a bare binding would
    # happily capture a sibling test's broadcast and then fail on the
    # comparison.
    agent_id = agent.id

    assert_receive {:role_assignment_changed,
                    %{role_key: "meeting_producer", agent_id: ^agent_id}}
  end

  test "unassign_role/1 broadcasts a nil agent_id" do
    agent = create_agent!()
    {:ok, _} = Roles.assign_role("meeting_producer", agent.id)
    assert_receive {:role_assignment_changed, %{role_key: "meeting_producer"}}

    :ok = Roles.unassign_role("meeting_producer")

    assert_receive {:role_assignment_changed, %{role_key: "meeting_producer", agent_id: nil}}
  end

  test "the payload carries the CURRENT assignment, not the caller's intent" do
    # Decision 1 (one-agent-per-role) means a second assign is rejected.
    # Broadcasting the caller's argument would tell every subscriber the
    # role moved when it did not — so the broadcast reads the row back.
    first = create_agent!()
    second = create_agent!()

    first_id = first.id

    {:ok, _} = Roles.assign_role("meeting_producer", first.id)
    assert_receive {:role_assignment_changed, %{agent_id: ^first_id}}

    assert {:error, _changeset} = Roles.assign_role("meeting_producer", second.id)

    # A rejected insert publishes nothing at all — there is no change.
    #
    # Scoped to `second`, not a bare wildcard: `roles:assignments` is a
    # process-group broadcast and does NOT respect the Ecto sandbox, so
    # any other async test assigning `meeting_producer` at the same
    # moment lands in this mailbox. A wildcard refute makes this test a
    # function of the whole suite's scheduling — it failed exactly that
    # way once the stage-7 UI tests added more producer fixtures. The
    # claim under test was always about THIS agent.
    second_id = second.id
    refute_receive {:role_assignment_changed, %{agent_id: ^second_id}}, 100
  end

  test "unassigning a role nobody holds is still an idempotent :ok" do
    assert :ok = Roles.unassign_role("meeting_producer")

    assert_receive {:role_assignment_changed, %{role_key: "meeting_producer", agent_id: nil}}
  end

  test "a subscriber only hears about roles, not every agent write" do
    # Scoped to the agent this test created, for the same reason as
    # above: the topic is suite-wide, so a wildcard refute would be
    # asserting that no OTHER test assigned a role in this 100ms — a
    # claim about the scheduler, not about `Roles`.
    agent = create_agent!()
    agent_id = agent.id
    refute_receive {:role_assignment_changed, %{agent_id: ^agent_id}}, 100
  end
end
