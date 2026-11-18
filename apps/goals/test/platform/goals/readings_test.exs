defmodule Platform.Goals.ReadingsTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  import Platform.Goals.NumberAssertions
  alias Platform.Goals
  alias Platform.Goals.Reading
  alias Platform.Tasks.{Project, Task}

  defmodule RaisingSource do
    @behaviour Platform.Goals.Source
    def key, do: "raising"
    def label, do: "Broken source"
    def kind, do: :measured
    def population(_), do: raise("not available")
    def measure(_), do: raise("not available")
  end

  defmodule BrokenMeasure do
    @behaviour Platform.Goals.Source
    def key, do: "broken_measure"
    def label, do: "Broken measure"
    def kind, do: :measured
    def population(_), do: {:ok, "broken_measure"}
    def measure(_), do: Application.get_env(:goals, :broken_result).()
  end

  setup do
    enable_goals!()
    org = org_id!()
    owner = member!(org)
    coach = agent!()
    goal = goal!(owner, org, %{source_key: "self_reported", unit: "km", coach_agent_id: coach.id})
    sources = Application.fetch_env(:goals, :sources)
    Application.put_env(:goals, :sources, Goals.Sources.all() ++ [RaisingSource, BrokenMeasure])

    on_exit(fn ->
      case sources do
        {:ok, value} -> Application.put_env(:goals, :sources, value)
        :error -> Application.delete_env(:goals, :sources)
      end

      Application.delete_env(:goals, :broken_result)
    end)

    %{org: org, owner: owner, coach: coach, goal: goal}
  end

  test "first, negative and decimal deltas; a backdated value never replaces latest", c do
    assert {:ok, first} = Goals.log_reading(c.owner, c.goal.id, %{value: "10.5"})
    assert {:ok, {:reading, number}} = Goals.goal_number(c.owner, c.goal.id)
    assert number.latest.id == first.id
    assert number.previous == nil and number.delta == nil
    assert number.baseline == nil and number.change_since == nil
    assert {:ok, second} = Goals.log_reading(c.owner, c.goal.id, %{value: "8.25"})
    assert {:ok, {:reading, number}} = Goals.goal_number(c.owner, c.goal.id)
    assert number.previous.id == first.id
    assert Decimal.equal?(number.delta, Decimal.new("-2.25"))

    assert {:ok, _} =
             Goals.log_reading(c.owner, c.goal.id, %{
               value: 100,
               measured_at: DateTime.add(first.measured_at, -60)
             })

    assert {:ok, {:reading, number}} = Goals.goal_number(c.owner, c.goal.id)
    assert number.latest.id == second.id
    assert number.previous.id == first.id
    refute number_free?({:reading, number})
  end

  test "since selects the newest baseline at or before its timestamp", c do
    {:ok, first} =
      Goals.log_reading(c.owner, c.goal.id, %{
        value: 4,
        measured_at: DateTime.add(DateTime.utc_now(), -120)
      })

    {:ok, second} =
      Goals.log_reading(c.owner, c.goal.id, %{
        value: 7,
        measured_at: DateTime.add(DateTime.utc_now(), -60)
      })

    {:ok, _} = Goals.log_reading(c.owner, c.goal.id, %{value: 9})

    assert {:ok, {:reading, number}} =
             Goals.goal_number(c.owner, c.goal.id, since: second.measured_at)

    assert number.baseline.id == second.id
    assert Decimal.equal?(number.change_since, 2)

    assert {:ok, {:reading, number}} =
             Goals.goal_number(c.owner, c.goal.id, since: DateTime.add(first.measured_at, -1))

    assert number.baseline == nil and number.change_since == nil
  end

  test "ties are ordered by measured_at then inserted_at then id", c do
    {:ok, first} = Goals.log_reading(c.owner, c.goal.id, %{value: 4})

    {:ok, second} =
      Goals.log_reading(c.owner, c.goal.id, %{value: 7, measured_at: first.measured_at})

    assert {:ok, {:reading, number}} = Goals.goal_number(c.owner, c.goal.id)
    assert number.latest.id == second.id
    first |> Ecto.Changeset.change(inserted_at: second.inserted_at) |> Repo.update!()
    assert {:ok, {:reading, number}} = Goals.goal_number(c.owner, c.goal.id)
    assert number.latest.id == Enum.max([first.id, second.id])
  end

  test "provenance and unit come from goal and actor, practice and string attrs round trip", c do
    {:ok, reading} =
      Goals.log_reading(c.coach, c.goal.id, %{
        "value" => "4.5",
        "origin" => "practice",
        "author_type" => "user",
        "author_user_id" => c.owner.id,
        "population" => "forged",
        "source_key" => "forged",
        "goal_id" => Ecto.UUID.generate(),
        "unit" => "forged"
      })

    assert reading.author_type == "agent" and reading.author_agent_id == c.coach.id
    assert reading.author_user_id == nil and reading.goal_id == c.goal.id
    assert reading.origin == "practice" and reading.unit == "km"
    assert reading.source_key == "self_reported" and reading.population == "self_reported"

    {:ok, reading} =
      Goals.log_reading(c.owner, c.goal.id, %{value: 1, author_agent_id: c.coach.id})

    assert reading.author_type == "user" and reading.author_user_id == c.owner.id
    assert reading.author_agent_id == nil and reading.origin == "manual"
  end

  test "bad attrs and measured origin refuse with changesets and no writes", c do
    for attrs <- [
          %{},
          %{value: "abc"},
          %{value: %{}},
          %{value: nil},
          %{value: 1, origin: nil},
          %{value: 1, details: nil},
          %{value: 1, origin: "measured"},
          %{value: 1, measured_at: DateTime.add(DateTime.utc_now(), 60)},
          %{value: 1, origin: "wrong"}
        ] do
      assert {:error, %Ecto.Changeset{valid?: false}} =
               Goals.log_reading(c.owner, c.goal.id, attrs)
    end

    assert count() == 0
  end

  test "logged measure is read only and list_sources describes registrations", c do
    refusal(Goals.measure_goal(c.coach, c.goal.id), :no_reading_yet)
    {:ok, reading} = Goals.log_reading(c.owner, c.goal.id, %{value: 3})
    assert {:ok, {:reading, %{latest: %{id: id}}}} = Goals.measure_goal(c.coach, c.goal.id)
    assert id == reading.id and count() == 1
    assert {:ok, descriptions} = Goals.list_sources(c.owner)
    assert Enum.any?(descriptions, &(&1.key == "self_reported" and &1.kind == :logged))
  end

  test "measuring task count stores once per call and subtracts comparable readings", c do
    {goal, project} = counted_goal(c)
    task = task!(project)
    task!(project)

    assert {:ok, {:reading, %{latest: first, previous: nil, delta: nil}}} =
             Goals.measure_goal(c.coach, goal.id)

    assert Decimal.equal?(first.value, 2)
    assert first.origin == "measured" and first.author_agent_id == c.coach.id
    assert first.unit == "km"
    task |> Ecto.Changeset.change(status: "done") |> Repo.update!()
    assert {:ok, {:reading, number}} = Goals.measure_goal(c.owner, goal.id)
    assert number.previous.id == first.id and Decimal.equal?(number.delta, -1)
    assert number.latest.author_user_id == c.owner.id
    assert count() == 2
  end

  test "archiving refuses both reads and measures despite stored readings", c do
    {goal, project} = counted_goal(c)
    task!(project)
    assert {:ok, {:reading, _}} = Goals.measure_goal(c.owner, goal.id)
    project |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update!()
    refusal(Goals.measure_goal(c.owner, goal.id), :unknown_project)
    refusal(Goals.goal_number(c.owner, goal.id), :unknown_project)
    assert count() == 1
    assert {:ok, [_]} = Goals.list_readings(c.owner, goal.id)
  end

  test "changing count or project starts a population with no previous or baseline", c do
    {goal, project} = counted_goal(c)
    task!(project)
    {:ok, _} = Goals.measure_goal(c.owner, goal.id)

    {:ok, _} =
      Goals.update_goal(c.owner, goal.id, %{
        source_settings: %{"project_id" => project.id, "count" => "completed"}
      })

    refusal(Goals.goal_number(c.owner, goal.id), :no_reading_yet)
    assert {:ok, {:reading, number}} = Goals.measure_goal(c.owner, goal.id)
    assert number.previous == nil and number.delta == nil
    assert number.latest.population == "task_count:#{project.id}:completed"

    assert {:ok, {:reading, number}} =
             Goals.goal_number(c.owner, goal.id,
               since: DateTime.add(number.latest.measured_at, -1)
             )

    assert number.baseline == nil and number.change_since == nil
    second_project = project!(c.org)

    {:ok, _} =
      Goals.update_goal(c.owner, goal.id, %{
        source_settings: %{"project_id" => second_project.id, "count" => "completed"}
      })

    assert {:ok, {:reading, %{previous: nil, delta: nil}}} = Goals.measure_goal(c.owner, goal.id)
    assert {:ok, history} = Goals.list_readings(c.owner, goal.id)
    assert length(history) == 3
  end

  test "switching source never uses old source readings", c do
    {:ok, _} = Goals.log_reading(c.owner, c.goal.id, %{value: 4})
    {goal, _} = counted_goal(c)
    refusal(Goals.goal_number(c.owner, goal.id), :no_reading_yet)
    assert {:error, :source_not_logged} = Goals.log_reading(c.owner, goal.id, %{value: 5})
    assert count() == 1
  end

  test "nil, unknown and raising sources refuse without numbers and never insert", c do
    for {key, reason} <- [
          {nil, :no_source},
          {"unknown", :unknown_source},
          {"raising", :source_failed}
        ] do
      {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{source_key: key})
      refusal(Goals.goal_number(c.owner, c.goal.id), reason)
      refusal(Goals.measure_goal(c.owner, c.goal.id), reason)
      assert {:error, :source_not_logged} = Goals.log_reading(c.owner, c.goal.id, %{value: 2})
    end

    assert count() == 0
  end

  test "off-contract and raising measures are source_failed, with no stale number", c do
    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{source_key: "broken_measure"})

    for fun <- [
          fn -> raise "failed" end,
          fn -> {:ok, %{value: "abc", unit: nil, population: "broken_measure"}} end,
          fn -> {:ok, %{value: 1, unit: nil, population: "different"}} end,
          fn -> {:cannot_measure, :count_failed, 0} end,
          fn -> :error end
        ] do
      Application.put_env(:goals, :broken_result, fun)
      refusal(Goals.measure_goal(c.owner, c.goal.id), :source_failed)
    end

    Application.put_env(:goals, :broken_result, fn -> {:cannot_measure, :count_failed} end)
    refusal(Goals.measure_goal(c.owner, c.goal.id), :count_failed)
    assert count() == 0
  end

  test "invalid measured settings refuse with no row", c do
    {goal, project} = counted_goal(c)

    {:ok, _} =
      Goals.update_goal(c.owner, goal.id, %{source_settings: %{"project_id" => project.id}})

    refusal(Goals.measure_goal(c.owner, goal.id), :bad_settings)
    refusal(Goals.goal_number(c.owner, goal.id), :bad_settings)
    assert count() == 0
  end

  test "audience user and space agent read but cannot log or measure", c do
    reader = user!()
    participant = agent!()
    space = space!(c.org)
    join_space!(space.id, :user, c.owner.id)
    join_space!(space.id, :agent, participant.id)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, reader.id})
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:space, space.id})
    {:ok, reading} = Goals.log_reading(c.owner, c.goal.id, %{value: 2})

    for actor <- [reader, participant] do
      assert {:ok, {:reading, %{latest: %{id: id}}}} = Goals.goal_number(actor, c.goal.id)
      assert id == reading.id
      assert {:ok, [%{id: ^id}]} = Goals.list_readings(actor, c.goal.id)
      assert {:error, :forbidden} = Goals.log_reading(actor, c.goal.id, %{value: 3})
      assert {:error, :forbidden} = Goals.measure_goal(actor, c.goal.id)
    end

    assert count() == 1
  end

  test "strangers and root admins see the same refusal for real, random and malformed ids", c do
    for actor <- [user!(), root_admin!()], id <- [c.goal.id, Ecto.UUID.generate(), "bad-id"] do
      assert Goals.goal_number(actor, id) == {:error, :not_found}
      assert Goals.goal_number(actor, id, since: DateTime.utc_now()) == {:error, :not_found}
      assert Goals.list_readings(actor, id) == {:error, :not_found}
      assert Goals.log_reading(actor, id, %{value: 3}) == {:error, :not_found}
      assert Goals.measure_goal(actor, id) == {:error, :not_found}
    end

    assert count() == 0
  end

  test "history defaults to fifty, caps at two hundred, and keeps newest order", c do
    now = DateTime.utc_now()

    for n <- 1..205 do
      {:ok, _} =
        Goals.log_reading(c.owner, c.goal.id, %{value: n, measured_at: DateTime.add(now, n - 206)})
    end

    assert {:ok, default} = Goals.list_readings(c.owner, c.goal.id)
    assert length(default) == 50
    assert Decimal.equal?(hd(default).value, 205)
    assert {:ok, capped} = Goals.list_readings(c.owner, c.goal.id, limit: 900)
    assert length(capped) == 200
    assert {:ok, []} = Goals.list_readings(c.owner, c.goal.id, limit: 0)
  end

  defp refusal(result, reason) do
    assert {:ok, {:cannot_measure, map}} = result
    assert Map.keys(map) |> Enum.sort() == [:reason, :source_key, :source_label]
    assert map.reason == reason
    assert number_free?(result)
  end

  defp count, do: Repo.aggregate(Reading, :count)

  defp project!(org),
    do: Repo.insert!(%Project{org_id: org, name: "Readings", slug: "readings-#{unique()}"})

  defp task!(project),
    do: Repo.insert!(%Task{project_id: project.id, title: "Readings", status: "backlog"})

  defp counted_goal(c) do
    project = project!(c.org)

    {:ok, goal} =
      Goals.update_goal(c.owner, c.goal.id, %{
        source_key: "task_count",
        source_settings: %{"project_id" => project.id, "count" => "open"}
      })

    {goal, project}
  end
end
