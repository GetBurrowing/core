defmodule Platform.Mobile.NativeCallTest do
  @moduledoc """
  Task 01a10db7 stage 1: the native app's meeting join and leave.

  `NativeCall` owns only the meeting lifecycle around the join; the join
  itself is `Meetings.join_for_user/3`, shared with the web. The live
  `meeting_participants` assertion below is the native half of the shared-path
  pin: deleting the live-participant upsert from `join_for_user/3` must turn
  this file AND `meeting_hooks_test.exs` red.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.ExternalUserFixtures, only: [create_user!: 0, plain_member!: 2]

  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.Participant
  alias Platform.Meetings.Room
  alias Platform.Mobile.NativeCall
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy

  setup do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

    org = Tenancy.get_org_by_slug!("sxi")
    user = create_user!()
    plain_member!(user, org)

    %{org: org, user: user, meeting: meeting!(org)}
  end

  defp meeting!(org) do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Native Call #{n}", org_id: org.id})

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Native Call Meeting #{n}",
        slug: "native-call-#{n}"
      })

    meeting
  end

  defp live_rows(space_id) do
    Repo.all(
      from(p in Participant,
        join: r in Room,
        on: r.id == p.room_id,
        where: r.space_id == ^space_id
      )
    )
  end

  describe "join/2" do
    test "starts a scheduled meeting, stamps started_by, and returns token and room", ctx do
      assert ctx.meeting.status == "scheduled"

      assert {:ok, result} = NativeCall.join(ctx.user, ctx.meeting.id)

      assert is_binary(result.token)
      assert result.url == "wss://livekit.test"
      assert result.room_name == Meetings.room_name_for_space(ctx.meeting.chat_space_id)
      assert result.identity == "user:#{ctx.user.id}"
      assert result.meeting.id == ctx.meeting.id
      assert result.meeting.space_id == ctx.meeting.chat_space_id
      assert result.meeting.status == "live"
      assert %DateTime{} = result.meeting.started_at

      stored = Repo.get!(Meeting, ctx.meeting.id)
      assert stored.status == "live"
      assert stored.started_by_user_id == ctx.user.id
    end

    test "writes the joiner's live meeting_participants row (shared join path)", ctx do
      assert {:ok, _} = NativeCall.join(ctx.user, ctx.meeting.id)

      assert [%Participant{user_id: user_id, left_at: nil}] =
               live_rows(ctx.meeting.chat_space_id)

      assert user_id == ctx.user.id

      assert [%{display_name: _}] =
               Meetings.active_participants_for_space(ctx.meeting.chat_space_id)
    end

    test "joining a live meeting keeps the original starter", ctx do
      starter = create_user!()
      plain_member!(starter, ctx.org)
      {:ok, _} = NativeCall.join(starter, ctx.meeting.id)

      assert {:ok, %{meeting: %{status: "live"}}} = NativeCall.join(ctx.user, ctx.meeting.id)
      assert Repo.get!(Meeting, ctx.meeting.id).started_by_user_id == starter.id
    end

    test "an ended meeting is refused and nothing is written", ctx do
      {:ok, live} = Meetings.start_meeting(ctx.meeting)
      {:ok, _ended} = live |> Meeting.status_changeset("ended") |> Repo.update()

      assert {:error, :meeting_over} = NativeCall.join(ctx.user, ctx.meeting.id)
      assert live_rows(ctx.meeting.chat_space_id) == []
    end

    test "a cancelled meeting is refused", ctx do
      {:ok, _} = ctx.meeting |> Meeting.status_changeset("cancelled") |> Repo.update()
      assert {:error, :meeting_over} = NativeCall.join(ctx.user, ctx.meeting.id)
    end

    test "another org's meeting, an unknown id and a malformed id are all :not_found", ctx do
      other = meeting!(Tenancy.get_org_by_slug!("soylent"))

      assert {:error, :not_found} = NativeCall.join(ctx.user, other.id)
      assert {:error, :not_found} = NativeCall.join(ctx.user, Ecto.UUID.generate())
      assert {:error, :not_found} = NativeCall.join(ctx.user, "not-a-uuid")

      assert Repo.get!(Meeting, other.id).status == "scheduled"
      assert live_rows(other.chat_space_id) == []
    end
  end

  describe "leave/2" do
    test "stamps the user's live participant row left", ctx do
      {:ok, _} = NativeCall.join(ctx.user, ctx.meeting.id)

      assert :ok = NativeCall.leave(ctx.user, ctx.meeting.id)

      assert [%Participant{left_at: %DateTime{}}] = live_rows(ctx.meeting.chat_space_id)
      assert Meetings.active_participants_for_space(ctx.meeting.chat_space_id) == []
    end

    test "another org's meeting is :not_found", ctx do
      other = meeting!(Tenancy.get_org_by_slug!("soylent"))
      assert {:error, :not_found} = NativeCall.leave(ctx.user, other.id)
    end
  end
end
