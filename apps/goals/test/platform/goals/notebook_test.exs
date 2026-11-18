defmodule Platform.Goals.NotebookTest do
  use Platform.DataCase, async: false
  import Platform.GoalsFixtures
  alias Platform.Goals

  setup do
    enable_goals!()
    org = org_id!()
    owner = member!(org)
    coach = agent!()
    %{org: org, owner: owner, coach: coach, goal: goal!(owner, org, %{coach_agent_id: coach.id})}
  end

  test "six kinds retain fields, filters, and actor authorship", c do
    for kind <- ~w(wake_up action ask wait takeaway retro) do
      attrs = %{
        kind: kind,
        title: kind,
        body: "notes",
        prediction: "up",
        predicted_change: "2.5",
        predicted_by: "2026-12-01",
        sources: [%{"name" => "one", "url" => "https://example.com"}, %{"name" => "two"}],
        details: %{"next" => "try"},
        author_type: "agent",
        author_agent_id: c.coach.id
      }

      assert {:ok, entry} = Goals.add_entry(c.owner, c.goal.id, attrs)
      assert entry.author_type == "user"
      assert entry.author_user_id == c.owner.id
      assert entry.author_agent_id == nil
      assert entry.occurred_at
      assert entry.title == kind
      assert entry.body == "notes"
      assert entry.prediction == "up"
      assert Decimal.equal?(entry.predicted_change, "2.5")
      assert entry.predicted_by == ~D[2026-12-01]
      assert entry.sources == attrs.sources
      assert entry.details == attrs.details
    end

    assert {:ok, entries} = Goals.list_entries(c.owner, c.goal.id)
    assert length(entries) == 6

    assert Enum.map(entries, & &1.occurred_at) ==
             Enum.sort(Enum.map(entries, & &1.occurred_at), {:desc, DateTime})

    assert {:ok, [%{kind: "ask"}]} = Goals.list_entries(c.owner, c.goal.id, kind: "ask")
    assert {:ok, [_]} = Goals.list_entries(c.owner, c.goal.id, kind: ["action", "ask"], limit: 1)

    assert {:ok, entry} =
             Goals.add_entry(c.coach, c.goal.id, %{kind: "wait", author_user_id: c.owner.id})

    assert entry.author_type == "agent"
    assert entry.author_agent_id == c.coach.id
    assert entry.author_user_id == nil
  end

  test "stops replace atomically, ignore positions and accept coach updates", c do
    attrs = %{
      label: "First",
      position: 99,
      target_value: "10",
      due_on: "2026-12-01",
      caption: "big",
      theme: "learn",
      criteria: [%{"text" => "x"}],
      reached_on: "2026-11-15"
    }

    assert {:ok, [first, second]} =
             Goals.put_stops(c.owner, c.goal.id, [attrs, %{label: "Second"}])

    assert [first.position, second.position] == [1, 2]
    assert first.caption == attrs.caption
    assert first.theme == attrs.theme
    assert first.criteria == attrs.criteria
    assert first.due_on == ~D[2026-12-01]
    assert first.reached_on == ~D[2026-11-15]
    assert Decimal.equal?(first.target_value, 10)

    assert {:ok, updated} =
             Goals.update_stop(c.coach, c.goal.id, first.id, %{label: "Changed", position: 8})

    assert updated.position == 1
    assert updated.label == "Changed"

    assert {:error, %Ecto.Changeset{}} =
             Goals.put_stops(c.owner, c.goal.id, [%{label: "Valid"}, %{label: ""}])

    assert {:ok, [^updated, ^second]} = Goals.list_stops(c.owner, c.goal.id)
    assert {:ok, []} = Goals.put_stops(c.coach, c.goal.id, [])
  end

  test "entry references require same goal and takeaway kind", c do
    other = goal!(c.owner, c.org)
    {:ok, [stop]} = Goals.put_stops(c.owner, c.goal.id, [%{label: "Finish"}])
    {:ok, [foreign_stop]} = Goals.put_stops(c.owner, other.id, [%{label: "Other"}])

    {:ok, takeaway} =
      Goals.add_entry(c.owner, c.goal.id, %{
        kind: "takeaway",
        title: "t",
        sources: [%{"name" => "s"}]
      })

    {:ok, action} =
      Goals.add_entry(c.owner, c.goal.id, %{kind: "action", takeaway_id: takeaway.id})

    assert action.takeaway_id == takeaway.id

    assert {:ok, %{stop_id: id}} =
             Goals.add_entry(c.owner, c.goal.id, %{kind: "retro", stop_id: stop.id})

    assert id == stop.id

    {:ok, foreign} =
      Goals.add_entry(c.owner, other.id, %{
        kind: "takeaway",
        title: "t",
        sources: [%{"name" => "s"}]
      })

    for attrs <- [
          %{takeaway_id: foreign.id},
          %{stop_id: foreign_stop.id},
          %{takeaway_id: action.id},
          %{stop_id: Ecto.UUID.generate()}
        ] do
      assert {:error, %Ecto.Changeset{}} =
               Goals.add_entry(c.owner, c.goal.id, Map.put(attrs, :kind, "ask"))
    end

    assert {:error, :not_found} =
             Goals.update_stop(c.owner, c.goal.id, foreign_stop.id, %{label: "stolen"})
  end

  test "audience reads, cannot write; strangers cannot access any of five functions", c do
    reader = user!()
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, reader.id})
    {:ok, [stop]} = Goals.put_stops(c.owner, c.goal.id, [%{label: "Finish"}])
    {:ok, entry} = Goals.add_entry(c.owner, c.goal.id, %{kind: "wait"})
    assert {:ok, [^stop]} = Goals.list_stops(reader, c.goal.id)
    assert {:ok, [^entry]} = Goals.list_entries(reader, c.goal.id)

    for {actor, expected} <- [{reader, :forbidden}, {user!(), :not_found}] do
      assert {:error, ^expected} = Goals.put_stops(actor, c.goal.id, [])
      assert {:error, ^expected} = Goals.update_stop(actor, c.goal.id, stop.id, %{})
      assert {:error, ^expected} = Goals.add_entry(actor, c.goal.id, %{kind: "wait"})

      if expected == :not_found do
        assert {:error, :not_found} = Goals.list_stops(actor, c.goal.id)
        assert {:error, :not_found} = Goals.list_entries(actor, c.goal.id)
      end
    end
  end

  test "entry list defaults to 50 and caps at 200", c do
    for _ <- 1..201, do: Goals.add_entry(c.owner, c.goal.id, %{kind: "wait"})
    assert {:ok, entries} = Goals.list_entries(c.owner, c.goal.id)
    assert length(entries) == 50
    assert {:ok, entries} = Goals.list_entries(c.owner, c.goal.id, limit: 999)
    assert length(entries) == 200
  end

  test "reading links round-trip and reject foreign or malformed ids without writing", c do
    make_reading = fn goal ->
      Platform.Repo.insert!(%Platform.Goals.Reading{
        goal_id: goal.id,
        value: Decimal.new(1),
        source_key: "self_reported",
        population: "self_reported",
        origin: "manual",
        measured_at: DateTime.utc_now(),
        author_type: "user",
        author_user_id: c.owner.id
      })
    end

    reading = make_reading.(c.goal)
    foreign = make_reading.(goal!(c.owner, c.org))

    assert {:ok, entry} =
             Goals.add_entry(c.owner, c.goal.id, %{kind: "wait", reading_id: reading.id})

    assert {:ok, [^entry]} = Goals.list_entries(c.owner, c.goal.id)
    assert entry.reading_id == reading.id

    for id <- [foreign.id, "not-a-uuid", Ecto.UUID.generate()] do
      assert {:error, %Ecto.Changeset{}} =
               Goals.add_entry(c.owner, c.goal.id, %{kind: "ask", reading_id: id})
    end

    assert {:ok, [^entry]} = Goals.list_entries(c.owner, c.goal.id)
  end
end
