defmodule Platform.Goals.ReadingSchemaTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  alias Platform.Goals.{Entry, Reading}
  alias Platform.Repo

  setup do
    enable_goals!()
    org = org_id!()
    owner = member!(org)
    %{owner: owner, goal: goal!(owner, org)}
  end

  defp reading(c) do
    %Reading{
      goal_id: c.goal.id,
      source_key: "self_reported",
      population: "self_reported",
      author_type: "user",
      author_user_id: c.owner.id
    }
  end

  defp attrs, do: %{value: "12.5", measured_at: DateTime.utc_now(), origin: "manual"}

  test "non-numeric values and future dates return changeset errors", c do
    for value <- ["abc", nil, %{}] do
      assert {:error, changeset} =
               reading(c) |> Reading.changeset(Map.put(attrs(), :value, value)) |> Repo.insert()

      assert Keyword.has_key?(changeset.errors, :value)
    end

    assert %{valid?: false} =
             Reading.changeset(
               reading(c),
               Map.put(attrs(), :measured_at, DateTime.add(DateTime.utc_now(), 60))
             )
  end

  test "provenance attrs are ignored", c do
    changeset =
      Reading.changeset(
        reading(c),
        Map.merge(attrs(), %{
          goal_id: Ecto.UUID.generate(),
          source_key: "spoof",
          population: "spoof",
          unit: "spoof",
          author_type: "agent",
          author_user_id: Ecto.UUID.generate(),
          author_agent_id: Ecto.UUID.generate()
        })
      )

    row = Ecto.Changeset.apply_changes(changeset)
    assert row.goal_id == c.goal.id
    assert row.source_key == "self_reported"
    assert row.population == "self_reported"
    assert row.author_user_id == c.owner.id
    assert row.author_type == "user"
    assert row.author_agent_id == nil
    assert row.unit == nil
  end

  test "both database checks become changeset errors", c do
    for {field, invalid} <- [origin: "bogus", author_type: "bogus"] do
      base = reading(c) |> Reading.changeset(attrs()) |> Ecto.Changeset.apply_changes()
      changeset = base |> Ecto.Changeset.change(%{field => invalid}) |> Reading.changeset(%{})
      # Bypass inclusion validation for origin, to prove the named database constraint.
      changeset = %{changeset | errors: [], valid?: true}
      assert {:error, rejected} = Repo.insert(changeset)
      assert Keyword.has_key?(rejected.errors, field)
    end
  end

  test "deleting a reading nullifies its entry link and deleting a goal cascades", c do
    row = reading(c) |> Reading.changeset(attrs()) |> Repo.insert!()

    {:ok, entry} =
      Platform.Goals.add_entry(c.owner, c.goal.id, %{kind: "wait", reading_id: row.id})

    Repo.delete!(row)
    assert %{reading_id: nil} = Repo.get!(Entry, entry.id)
    remaining = reading(c) |> Reading.changeset(attrs()) |> Repo.insert!()
    Repo.delete!(c.goal)
    refute Repo.get(Reading, remaining.id)
  end
end
