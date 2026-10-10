defmodule Platform.Meetings.MeetingTest do
  @moduledoc """
  Tests for the `Platform.Meetings.Meeting` schema — changeset validation,
  status enum, transition rules, and the per-project slug / global
  livekit_room_name unique constraints.
  """
  use Platform.DataCase, async: true

  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp create_project(attrs \\ %{}) do
    default = %{name: "Project #{System.unique_integer([:positive])}"}
    {:ok, project} = Tasks.create_project(Map.merge(default, attrs))
    project
  end

  defp create_space do
    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Meeting Space #{System.unique_integer([:positive])}",
        slug: "meeting-space-#{System.unique_integer([:positive])}",
        kind: "meeting"
      })

    space
  end

  defp valid_attrs do
    %{
      project_id: create_project().id,
      chat_space_id: create_space().id,
      slug: "kickoff-#{System.unique_integer([:positive])}",
      name: "Kickoff",
      livekit_room_name: "meeting-#{Ecto.UUID.generate()}"
    }
  end

  describe "changeset/2" do
    test "valid attrs produce a valid changeset with default status" do
      cs = Meeting.changeset(%Meeting{}, valid_attrs())
      assert cs.valid?
      assert Ecto.Changeset.apply_changes(cs).status == "scheduled"
    end

    test "requires project_id, chat_space_id, slug, name, livekit_room_name" do
      cs = Meeting.changeset(%Meeting{}, %{})
      refute cs.valid?

      for field <- [:project_id, :chat_space_id, :slug, :name, :livekit_room_name] do
        assert %{} = errors_on(cs)
        assert Keyword.has_key?(cs.errors, field)
      end
    end

    test "rejects an invalid status" do
      cs = Meeting.changeset(%Meeting{}, Map.put(valid_attrs(), :status, "bogus"))
      refute cs.valid?
      assert %{status: ["is invalid"]} = errors_on(cs)
    end

    test "accepts each valid status" do
      for status <- Meeting.statuses() do
        cs = Meeting.changeset(%Meeting{}, Map.put(valid_attrs(), :status, status))
        assert cs.valid?, "expected #{status} to be valid"
      end
    end
  end

  describe "changeset/2 intended times" do
    @intended_start ~U[2026-09-01 15:00:00.123456Z]
    @intended_end ~U[2026-09-01 16:00:00.654321Z]

    test "both intended times round-trip through the database with microseconds intact" do
      attrs =
        valid_attrs()
        |> Map.put(:scheduled_start_at, @intended_start)
        |> Map.put(:scheduled_end_at, @intended_end)

      assert {:ok, meeting} = %Meeting{} |> Meeting.changeset(attrs) |> Repo.insert()

      # Re-fetch rather than trusting the returned struct: the returned struct
      # carries whatever the changeset applied, so it would look correct even
      # if the columns were never written.
      refetched = Repo.get!(Meeting, meeting.id)
      assert refetched.scheduled_start_at == @intended_start
      assert refetched.scheduled_end_at == @intended_end
      assert refetched.scheduled_start_at.microsecond == {123_456, 6}
      assert refetched.scheduled_end_at.microsecond == {654_321, 6}
    end

    test "neither intended time is still valid and insertable (the ad-hoc path)" do
      cs = Meeting.changeset(%Meeting{}, valid_attrs())
      assert cs.valid?

      assert {:ok, meeting} = Repo.insert(cs)
      refetched = Repo.get!(Meeting, meeting.id)
      assert is_nil(refetched.scheduled_start_at)
      assert is_nil(refetched.scheduled_end_at)
    end

    test "an end with no start is invalid, keyed on scheduled_end_at" do
      attrs = Map.put(valid_attrs(), :scheduled_end_at, @intended_end)
      cs = Meeting.changeset(%Meeting{}, attrs)

      refute cs.valid?
      assert %{scheduled_end_at: [msg]} = errors_on(cs)
      assert msg =~ "scheduled_start_at"
    end

    test "a start with no end is invalid, keyed on scheduled_end_at" do
      attrs = Map.put(valid_attrs(), :scheduled_start_at, @intended_start)
      cs = Meeting.changeset(%Meeting{}, attrs)

      refute cs.valid?
      assert %{scheduled_end_at: [msg]} = errors_on(cs)
      assert msg =~ "required"
    end

    test "an end exactly equal to the start is invalid" do
      attrs =
        valid_attrs()
        |> Map.put(:scheduled_start_at, @intended_start)
        |> Map.put(:scheduled_end_at, @intended_start)

      cs = Meeting.changeset(%Meeting{}, attrs)
      refute cs.valid?
      assert %{scheduled_end_at: ["must be after scheduled_start_at"]} = errors_on(cs)
    end

    test "an end one microsecond before the start is invalid" do
      one_micro_earlier = DateTime.add(@intended_start, -1, :microsecond)

      attrs =
        valid_attrs()
        |> Map.put(:scheduled_start_at, @intended_start)
        |> Map.put(:scheduled_end_at, one_micro_earlier)

      cs = Meeting.changeset(%Meeting{}, attrs)
      refute cs.valid?
      assert %{scheduled_end_at: ["must be after scheduled_start_at"]} = errors_on(cs)
    end

    test "an end one microsecond after the start is valid" do
      one_micro_later = DateTime.add(@intended_start, 1, :microsecond)

      attrs =
        valid_attrs()
        |> Map.put(:scheduled_start_at, @intended_start)
        |> Map.put(:scheduled_end_at, one_micro_later)

      assert Meeting.changeset(%Meeting{}, attrs).valid?
    end
  end

  describe "unique constraints" do
    test "slug is unique per project" do
      project = create_project()
      attrs = %{valid_attrs() | project_id: project.id, slug: "standup"}

      assert {:ok, _} = %Meeting{} |> Meeting.changeset(attrs) |> Repo.insert()

      dup =
        %{
          attrs
          | chat_space_id: create_space().id,
            livekit_room_name: "lk-#{Ecto.UUID.generate()}"
        }

      assert {:error, cs} = %Meeting{} |> Meeting.changeset(dup) |> Repo.insert()
      assert Keyword.has_key?(cs.errors, :project_id) or Keyword.has_key?(cs.errors, :slug)
    end

    test "same slug in different projects is allowed" do
      a = create_project()
      b = create_project()

      attrs_a = %{valid_attrs() | project_id: a.id, slug: "standup"}
      attrs_b = %{valid_attrs() | project_id: b.id, slug: "standup"}

      assert {:ok, _} = %Meeting{} |> Meeting.changeset(attrs_a) |> Repo.insert()
      assert {:ok, _} = %Meeting{} |> Meeting.changeset(attrs_b) |> Repo.insert()
    end

    test "livekit_room_name is globally unique" do
      room = "meeting-shared-#{Ecto.UUID.generate()}"
      attrs1 = %{valid_attrs() | livekit_room_name: room}
      attrs2 = %{valid_attrs() | livekit_room_name: room}

      assert {:ok, _} = %Meeting{} |> Meeting.changeset(attrs1) |> Repo.insert()
      assert {:error, cs} = %Meeting{} |> Meeting.changeset(attrs2) |> Repo.insert()
      assert %{livekit_room_name: _} = errors_on(cs)
    end
  end

  describe "status_changeset/3" do
    test "scheduled → live is legal and stamps started_at" do
      meeting = %Meeting{status: "scheduled"}
      now = DateTime.utc_now()
      cs = Meeting.status_changeset(meeting, "live", %{started_at: now})
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :status) == "live"
      assert Ecto.Changeset.get_change(cs, :started_at) == now
    end

    test "live → ended is legal and stamps ended_at" do
      meeting = %Meeting{status: "live"}
      now = DateTime.utc_now()
      cs = Meeting.status_changeset(meeting, "ended", %{ended_at: now})
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :status) == "ended"
    end

    test "scheduled → ended is rejected" do
      cs = Meeting.status_changeset(%Meeting{status: "scheduled"}, "ended")
      refute cs.valid?
      assert %{status: [msg]} = errors_on(cs)
      assert msg =~ "illegal transition"
    end

    test "cannot smuggle an intended-time edit through a status transition" do
      existing = ~U[2026-09-01 15:00:00.123456Z]
      meeting = %Meeting{status: "scheduled", scheduled_start_at: existing}

      cs =
        Meeting.status_changeset(meeting, "live", %{
          started_at: DateTime.utc_now(),
          scheduled_start_at: ~U[2026-12-25 09:00:00.000000Z]
        })

      assert cs.valid?
      assert is_nil(Ecto.Changeset.get_change(cs, :scheduled_start_at))
      assert Ecto.Changeset.get_field(cs, :scheduled_start_at) == existing
    end

    test "ended → live is rejected (no resurrection)" do
      cs = Meeting.status_changeset(%Meeting{status: "ended"}, "live")
      refute cs.valid?
      assert %{status: [msg]} = errors_on(cs)
      assert msg =~ "illegal transition"
    end
  end

  # Task 01a1265f stage 2. Resumption is its own changeset so that
  # `status_changeset/3` above keeps refusing ended → live for every other
  # writer; the no-resurrection test above is unchanged and must stay green.
  describe "resume_changeset/1" do
    test "resumes an ended meeting: live, ended_at cleared, started_at kept" do
      started = ~U[2026-10-10 09:00:00.000000Z]
      ended = ~U[2026-10-10 09:30:00.000000Z]

      cs =
        Meeting.resume_changeset(%Meeting{status: "ended", started_at: started, ended_at: ended})

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :status) == "live"
      assert Ecto.Changeset.get_field(cs, :ended_at) == nil
      assert Ecto.Changeset.get_field(cs, :started_at) == started
    end

    for status <- ~w(scheduled live cancelled) do
      test "rejects a #{status} meeting" do
        cs = Meeting.resume_changeset(%Meeting{status: unquote(status)})

        refute cs.valid?
        assert %{status: [msg]} = errors_on(cs)
        assert msg =~ "only an ended meeting resumes"
      end
    end
  end
end
