defmodule Platform.Meetings.IntentMuteTest do
  @moduledoc """
  Tests for the per-meeting intent mute (task 019fbaac stage 1) —
  `Platform.Meetings.set_intent_muted/2`, `Platform.Meetings.intent_muted?/1`,
  and the `{:intent_mute_changed, _}` broadcast on the meeting shell topic.

  Every "is not muted" assertion here is deliberately paired with a
  "is muted" assertion driven by the SAME fixture. `intent_muted?/1`
  returning `false` is the answer for a healthy unmuted meeting AND for
  a meeting whose row failed to insert, so a lone false assertion
  proves nothing on its own.
  """
  use Platform.DataCase, async: true

  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Tasks

  defp create_meeting do
    {:ok, project} =
      Tasks.create_project(%{name: "Project #{System.unique_integer([:positive])}"})

    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Meeting Space #{System.unique_integer([:positive])}",
        slug: "meeting-space-#{System.unique_integer([:positive])}",
        kind: "meeting"
      })

    {:ok, meeting} =
      %Meeting{}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "standup-#{System.unique_integer([:positive])}",
        name: "Standup",
        livekit_room_name: "meeting-#{Ecto.UUID.generate()}"
      })
      |> Repo.insert()

    meeting
  end

  describe "intent_muted?/1 round trip" do
    test "false when fresh, true after muting, false again after unmuting" do
      meeting = create_meeting()

      refute Meetings.intent_muted?(meeting.id)

      {:ok, muted} = Meetings.set_intent_muted(meeting, true)
      assert %DateTime{} = muted.intent_muted_at
      assert Meetings.intent_muted?(meeting.id)

      {:ok, unmuted} = Meetings.set_intent_muted(muted, false)
      assert is_nil(unmuted.intent_muted_at)
      refute Meetings.intent_muted?(meeting.id)
    end

    test "accepts a bare meeting id as well as a struct" do
      meeting = create_meeting()

      {:ok, muted} = Meetings.set_intent_muted(meeting.id, true)
      assert muted.id == meeting.id
      assert Meetings.intent_muted?(meeting.id)

      {:ok, _} = Meetings.set_intent_muted(meeting.id, false)
      refute Meetings.intent_muted?(meeting.id)
    end
  end

  describe "intent_muted?/1 totality" do
    # The caller is a singleton GenServer classifying chunks for every
    # room on the node: a raise here stops classification platform-wide.
    #
    # These are three tests rather than one with three refutes on
    # purpose. The first failing assertion ends a test, so a single
    # body would let a broken `nil` case hide whether the malformed
    # and absent-row cases are covered at all — which is exactly what
    # the mutation run showed when they were grouped.
    #
    # Each carries its own presence half: the same fixture that proves
    # the false is about the INPUT also proves the function can return
    # true, so a `false` from a function that is simply broken cannot
    # pass for a `false` that means "not muted".
    setup do
      meeting = create_meeting()
      {:ok, _} = Meetings.set_intent_muted(meeting, true)
      %{muted_meeting: meeting}
    end

    test "nil returns false without raising", %{muted_meeting: meeting} do
      assert Meetings.intent_muted?(meeting.id)
      refute Meetings.intent_muted?(nil)
    end

    test "a malformed id returns false without raising", %{muted_meeting: meeting} do
      assert Meetings.intent_muted?(meeting.id)
      refute Meetings.intent_muted?("not-a-uuid")
    end

    test "a 16-byte slug-shaped binary returns false without raising", %{
      muted_meeting: meeting
    } do
      # Ecto.UUID.cast/1 ACCEPTS any 16-byte binary by hex-encoding it,
      # and Repo then raises at dump time — see Platform.UUID's
      # moduledoc. A cast-only guard would let this through.
      assert Meetings.intent_muted?(meeting.id)
      refute Meetings.intent_muted?("higginshigginsxx")
    end

    test "a well-formed id with no row returns false", %{muted_meeting: meeting} do
      assert Meetings.intent_muted?(meeting.id)
      refute Meetings.intent_muted?(Ecto.UUID.generate())
    end

    test "set_intent_muted/2 returns {:error, :not_found} for an unknown or malformed id" do
      assert {:error, :not_found} = Meetings.set_intent_muted(Ecto.UUID.generate(), true)
      assert {:error, :not_found} = Meetings.set_intent_muted("not-a-uuid", true)
    end
  end

  describe "broadcast on the meeting shell topic" do
    test "subscribers receive a DateTime on mute and nil on unmute" do
      meeting = create_meeting()
      id = meeting.id
      :ok = MeetingsPubSub.subscribe_meeting(id)

      {:ok, muted} = Meetings.set_intent_muted(meeting, true)

      assert_receive {:intent_mute_changed, %{meeting_id: ^id, muted_at: %DateTime{} = at}}
      assert DateTime.compare(at, muted.intent_muted_at) == :eq

      {:ok, _} = Meetings.set_intent_muted(muted, false)

      assert_receive {:intent_mute_changed, %{meeting_id: ^id, muted_at: nil}}
    end

    test "the broadcast lands on the same string MeetingLive subscribes to" do
      meeting = create_meeting()
      id = meeting.id

      # MeetingLive subscribes by building this string itself. Binding
      # the literal here is what catches a rename of meeting_topic/1
      # that would otherwise silently stop reaching every open client.
      assert MeetingsPubSub.meeting_topic(id) == "meeting:#{id}"
      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, "meeting:#{id}")

      {:ok, _} = Meetings.set_intent_muted(meeting, true)

      assert_receive {:intent_mute_changed, %{meeting_id: ^id}}
    end

    # The two halves of "re-mute is a no-op that still broadcasts" are
    # two tests on purpose. Grouped, a mutation that re-clocks the
    # timestamp reddens the first assertion and the broadcast assertion
    # below it never runs — so the group would report a red without
    # exercising the behaviour the second half is there to protect.
    test "re-muting an already-muted meeting does not move the timestamp" do
      meeting = create_meeting()

      {:ok, first} = Meetings.set_intent_muted(meeting, true)
      assert %DateTime{} = first.intent_muted_at

      {:ok, second} = Meetings.set_intent_muted(first, true)

      assert second.intent_muted_at == first.intent_muted_at
      assert Repo.get!(Meeting, meeting.id).intent_muted_at == first.intent_muted_at
    end

    test "re-muting an already-muted meeting still broadcasts" do
      meeting = create_meeting()
      id = meeting.id

      {:ok, first} = Meetings.set_intent_muted(meeting, true)

      # Subscribing only NOW models the client that connected after the
      # first mute and has therefore never seen the state. Suppressing
      # the duplicate broadcast would leave its badge permanently wrong.
      :ok = MeetingsPubSub.subscribe_meeting(id)

      {:ok, _second} = Meetings.set_intent_muted(first, true)

      assert_receive {:intent_mute_changed, %{meeting_id: ^id, muted_at: %DateTime{}}}
    end

    test "unsubscribe_meeting/1 stops delivery" do
      meeting = create_meeting()
      id = meeting.id

      :ok = MeetingsPubSub.subscribe_meeting(id)
      {:ok, muted} = Meetings.set_intent_muted(meeting, true)
      assert_receive {:intent_mute_changed, %{meeting_id: ^id}}

      :ok = MeetingsPubSub.unsubscribe_meeting(id)
      {:ok, _} = Meetings.set_intent_muted(muted, false)

      refute_receive {:intent_mute_changed, _}
    end
  end

  # Regression, found by task 019fbaac stage 2's classifier tests.
  #
  # `set_intent_muted/2` used to trust the `%Meeting{}` it was handed.
  # Every real caller holds one for a long time — MeetingLive loads it
  # at `handle_params` and keeps it in socket assigns — so the field it
  # read was the value at mount, not the value now.
  describe "set_intent_muted/2 with a stale struct" do
    test "unmuting from a struct that still reads nil clears the row" do
      meeting = create_meeting()

      {:ok, _} = Meetings.set_intent_muted(meeting, true)
      assert Meetings.intent_muted?(meeting.id)

      # `meeting` is the PRE-mute struct: intent_muted_at is nil on it
      # and non-nil in the database. Passing it to unmute used to build
      # an empty changeset, which Repo.update answers {:ok, stale}
      # without writing — an unmute broadcast, a cleared badge, and a
      # classifier that stayed muted for the rest of the meeting.
      {:ok, unmuted} = Meetings.set_intent_muted(meeting, false)

      assert is_nil(unmuted.intent_muted_at)
      refute Meetings.intent_muted?(meeting.id)
      assert is_nil(Repo.get!(Meeting, meeting.id).intent_muted_at)
    end

    test "re-muting from a struct that still reads nil does not re-clock the stamp" do
      meeting = create_meeting()

      {:ok, first} = Meetings.set_intent_muted(meeting, true)

      # Same stale struct, this time muting again. Trusting its nil
      # would take the `DateTime.utc_now()` branch and move a timestamp
      # the context explicitly promises to hold still.
      {:ok, second} = Meetings.set_intent_muted(meeting, true)

      assert second.intent_muted_at == first.intent_muted_at
      assert Repo.get!(Meeting, meeting.id).intent_muted_at == first.intent_muted_at
    end
  end

  describe "Meeting.intent_mute_changeset/2" do
    test "changes only :intent_muted_at" do
      meeting = create_meeting()
      at = DateTime.utc_now()

      cs = Meeting.intent_mute_changeset(meeting, at)
      assert Map.keys(cs.changes) == [:intent_muted_at]
      assert cs.changes.intent_muted_at == at
    end

    test "changeset/2 does not cast :intent_muted_at from attrs" do
      # Mute is never set at create time. If it ever enters @cast_fields
      # a meeting could be born muted with nothing on screen to say so.
      at = DateTime.utc_now()
      cs = Meeting.changeset(%Meeting{}, %{intent_muted_at: at})

      refute Map.has_key?(cs.changes, :intent_muted_at)
    end
  end
end
