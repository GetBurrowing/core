defmodule Platform.Meetings.EnsureLiveMeetingForSpaceTest do
  @moduledoc """
  Task 01a04e9e stage 2 — the channel quick-meet meeting row.

  The channel quick-meet BINDS to the channel's EXISTING chat space (Jordan
  Coombs, 2026-09-02): every call gets a `meetings` row with
  `chat_space_id` = the channel's space id, and NO second chat space is ever
  minted. `Meetings.create_meeting/1` is deliberately not called by the
  ad-hoc path — it stamps its own backing chat space, which would orphan one
  here — and nothing mint-and-deletes either.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Space
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks

  setup do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

    :ok
  end

  defp channel!(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(
        Map.merge(
          %{
            name: "Quick Meet Channel #{n}",
            slug: "quick-meet-channel-#{n}",
            kind: "channel"
          },
          attrs
        )
      )

    space
  end

  defp project! do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "QM Project #{n}"})
    project
  end

  defp user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "qm-#{n}@example.com",
      name: "QM User #{n}",
      oidc_sub: "oidc-qm-#{n}"
    })
    |> Repo.insert!()
  end

  defp meeting_rows(space_id) do
    Repo.all(from(m in Meeting, where: m.chat_space_id == ^space_id))
  end

  defp space_rows do
    Repo.all(from(s in Space))
  end

  describe "ensure_live_meeting_for_space/1" do
    test "mints exactly one meetings row and ZERO chat spaces" do
      space = channel!()
      spaces_before = space_rows()

      assert {:ok, %Meeting{} = meeting} = Meetings.ensure_live_meeting_for_space(space.id)

      # The minted row is bound to the channel's EXISTING space, and no new
      # chat_space appeared — an orphaned `kind: "meeting"` space is
      # otherwise invisible unless asserted directly.
      assert [%Meeting{} = row] = meeting_rows(space.id)
      assert row.id == meeting.id
      assert row.chat_space_id == space.id
      assert space_rows() == spaces_before
    end

    test "row shape: bound to the channel space, scheduled_* nil, status live" do
      n = System.unique_integer([:positive])
      {:ok, project} = Tasks.create_project(%{name: "QM Shape #{n}"})
      space = channel!(%{metadata: %{"project_id" => project.id}})

      assert {:ok, %Meeting{} = meeting} = Meetings.ensure_live_meeting_for_space(space.id)

      assert meeting.chat_space_id == space.id
      assert meeting.project_id == project.id
      assert meeting.status == "live"
      assert meeting.scheduled_start_at == nil
      assert meeting.scheduled_end_at == nil
      assert %DateTime{} = meeting.started_at
      # The column convention, NOT the join room (`invite_room_parity`):
      # globally unique per meeting (`meeting-<id>`), while joiner tokens
      # mint into the space room `room_name_for_space/1` returns.
      assert is_binary(meeting.livekit_room_name) and meeting.livekit_room_name != ""
      assert meeting.livekit_room_name == "meeting-" <> meeting.id
      assert is_binary(meeting.slug) and meeting.slug != ""
      assert is_binary(meeting.name) and meeting.name != ""
    end

    test "a second join on the same space reuses the live row (no duplicate)" do
      space = channel!()

      assert {:ok, %Meeting{id: first_id}} = Meetings.ensure_live_meeting_for_space(space.id)

      # The second "join" (another participant, or the same one re-joining)
      # must find-and-reuse the live row, never mint a second one — the
      # meeting_rooms.space_id invariant (one room per space) applied to
      # meetings rows.
      assert {:ok, %Meeting{id: second_id}} = Meetings.ensure_live_meeting_for_space(space.id)
      assert second_id == first_id

      assert [%Meeting{id: ^first_id}] = meeting_rows(space.id)
    end

    test "a project-less channel joins successfully and mints a row with nil project_id" do
      space = channel!()

      assert {:ok, %Meeting{} = meeting} = Meetings.ensure_live_meeting_for_space(space.id)
      assert meeting.project_id == nil

      # And the row is durable (nullable project_id column accepts it).
      assert Repo.get!(Meeting, meeting.id).project_id == nil
    end

    test "a channel with a project in metadata resolves project_id from space context" do
      project = project!()
      space = channel!(%{metadata: %{"project_id" => project.id}})
      space_id = space.id
      project_id = project.id

      assert {:ok, %Meeting{chat_space_id: ^space_id, project_id: ^project_id}} =
               Meetings.ensure_live_meeting_for_space(space_id)
    end

    test "an unresolvable space returns {:ok, nil} and writes nothing" do
      ghost = Ecto.UUID.generate()
      spaces_before = space_rows()

      assert {:ok, nil} = Meetings.ensure_live_meeting_for_space(ghost)
      assert space_rows() == spaces_before
      assert meeting_rows(ghost) == []
    end
  end

  describe "the end lifecycle (status ended + ended_at)" do
    test "end_meeting on the ad-hoc row stamps ended + ended_at" do
      space = channel!()
      assert {:ok, %Meeting{} = meeting} = Meetings.ensure_live_meeting_for_space(space.id)

      assert {:ok, ended} = Meetings.end_meeting(meeting)
      assert ended.status == "ended"
      assert %DateTime{} = ended.ended_at

      # A subsequent quick-meet after the meeting ended mints a NEW live row
      # — the old one is history, the new call is a new session.
      assert {:ok, %Meeting{id: new_id}} = Meetings.ensure_live_meeting_for_space(space.id)
      assert new_id != meeting.id

      assert [%Meeting{status: "live"}, %Meeting{status: "ended"}] =
               meeting_rows(space.id) |> Enum.sort_by(& &1.inserted_at)
    end
  end

  describe "join_for_user/3 mints the ad-hoc meeting row on a channel quick-meet" do
    test "a channel join creates the meetings row bound to the channel space" do
      space = channel!()
      user = user!()
      space_id = space.id

      assert {:ok, %{token: _token}} = Meetings.join_for_user(space_id, user.id, "QM Ada")

      assert [%Meeting{chat_space_id: ^space_id, status: "live"}] = meeting_rows(space_id)
    end
  end

  describe "room_finished ends a live ad-hoc meeting for the space" do
    test "the LiveKit room_finished webhook handler ends the ad-hoc row via get_live_meeting_for_space" do
      space = channel!()

      assert {:ok, %Meeting{} = meeting} = Meetings.ensure_live_meeting_for_space(space.id)

      # Mirror of the livekit_webhook_controller's room_finished handler
      # (space-keyed lookup then end_meeting).
      assert {:ok, _} = Meetings.ensure_room(space.id)
      assert %Meeting{} = live = Meetings.get_live_meeting_for_space(space.id)
      assert live.id == meeting.id

      assert {:ok, ended} = Meetings.end_meeting(live)
      assert ended.status == "ended"
      assert %DateTime{} = ended.ended_at
      assert Meetings.get_live_meeting_for_space(space.id) == nil
    end
  end
end
