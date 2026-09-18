defmodule Platform.Chat.SpaceGoalLeaderTest do
  @moduledoc """
  Changeset contract for the `goal` / `leader_agent_id` columns added to
  `chat_spaces` in task `01a0b491-0718-7001-8bba-bf50f119bb13` stage 1.

  Covers the round trip through `Platform.Chat.Space.changeset/2` to the
  database, the 500-character ceiling on `goal`, and — as the positive
  control for that ceiling — that a 500-character goal is ACCEPTED. A
  length validation that rejected everything would pass the rejection
  assertion alone.

  Also pins the absence: a space created without either field comes back
  with both nil rather than a default, because the stage-4 render is
  conditional on "no goal declared" being readable as nil.
  """
  use Platform.DataCase, async: true

  alias Platform.Chat.Space
  alias Platform.Repo

  defp base_attrs(extra) do
    slug = "goal-test-#{System.unique_integer([:positive])}"

    Map.merge(
      %{kind: "channel", name: "Goal Test", slug: slug},
      extra
    )
  end

  defp insert_agent do
    Repo.insert!(%Platform.Agents.Agent{
      name: "Leader #{System.unique_integer([:positive])}",
      slug: "leader-#{System.unique_integer([:positive])}",
      status: "active"
    })
  end

  test "goal and leader_agent_id round-trip through the changeset" do
    agent = insert_agent()

    {:ok, space} =
      %Space{}
      |> Space.changeset(
        base_attrs(%{goal: "Close backlog items in Suite", leader_agent_id: agent.id})
      )
      |> Repo.insert()

    reloaded = Repo.get!(Space, space.id)

    assert reloaded.goal == "Close backlog items in Suite"
    assert reloaded.leader_agent_id == agent.id
  end

  test "a space created without a goal or leader has nil in both, not a default" do
    {:ok, space} = %Space{} |> Space.changeset(base_attrs(%{})) |> Repo.insert()

    reloaded = Repo.get!(Space, space.id)

    assert is_nil(reloaded.goal)
    assert is_nil(reloaded.leader_agent_id)
  end

  test "a goal over 500 characters is rejected, and exactly 500 is accepted" do
    too_long = String.duplicate("a", 501)

    changeset = Space.changeset(%Space{}, base_attrs(%{goal: too_long}))

    refute changeset.valid?
    assert {_msg, opts} = changeset.errors[:goal]
    assert opts[:count] == 500

    # Positive control: the ceiling is a ceiling, not a blanket refusal.
    at_limit = String.duplicate("a", 500)

    ok = Space.changeset(%Space{}, base_attrs(%{goal: at_limit}))

    assert ok.valid?
  end
end
