defmodule Platform.Goals.RetroSchemaTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  alias Platform.Goals
  alias Platform.Goals.{BriefItem, WakeUp}
  @now ~U[2026-02-04 07:00:00.000000Z]
  setup do
    enable_goals!()
    org = org_id!()
    owner = member!(org)
    %{owner: owner, other: member!(org), goal: goal!(owner, org)}
  end

  test "retro frequency range is a changeset error", c do
    for value <- [1, 61],
        do:
          assert(
            {:error, %Ecto.Changeset{}} =
              Goals.update_goal(c.owner, c.goal.id, %{retro_every: value})
          )

    for value <- [nil, 4],
        do: assert({:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{retro_every: value}))
  end

  test "wake kind and outcome agree while old check-in outcomes remain valid", c do
    for {kind, outcome, valid} <- [
          {"check_in", "retro", false},
          {"retro", "do", false},
          {"retro", "retro", true},
          {"check_in", "do", true},
          {"check_in", "ask", true},
          {"check_in", "wait", true}
        ] do
      attrs = %{
        kind: kind,
        outcome: outcome,
        status: "closed",
        due_at: DateTime.add(@now, unique()),
        fired_at: @now,
        respond_by: @now
      }

      result = %WakeUp{goal_id: c.goal.id} |> WakeUp.changeset(attrs) |> Repo.insert()

      if valid,
        do: assert(match?({:ok, _}, result)),
        else: assert(match?({:error, %Ecto.Changeset{}}, result))
    end
  end

  test "notes require one entry and reach each reader only once", c do
    {:ok, entry} =
      Goals.add_entry(c.owner, c.goal.id, %{kind: "retro", title: "Retro", occurred_at: @now})

    attrs = %{kind: "note", digest_date: ~D[2026-02-04]}
    item = %BriefItem{user_id: c.owner.id, goal_id: c.goal.id}
    assert {:error, _} = item |> BriefItem.changeset(attrs) |> Repo.insert()

    assert {:error, _} =
             %{item | entry_id: entry.id}
             |> BriefItem.changeset(%{attrs | kind: "report"})
             |> Repo.insert()

    assert {:ok, _} = %{item | entry_id: entry.id} |> BriefItem.changeset(attrs) |> Repo.insert()

    assert {:error, _} =
             %{item | entry_id: entry.id} |> BriefItem.changeset(attrs) |> Repo.insert()

    assert {:ok, _} =
             %{item | user_id: c.other.id, entry_id: entry.id}
             |> BriefItem.changeset(attrs)
             |> Repo.insert()

    assert {:ok, _} = item |> BriefItem.changeset(%{attrs | kind: "report"}) |> Repo.insert()
  end
end
