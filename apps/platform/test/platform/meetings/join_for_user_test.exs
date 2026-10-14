defmodule Platform.Meetings.JoinForUserTest do
  @moduledoc """
  Task 01a10db7 stage 1: `Platform.Meetings.join_for_user/3`, the ONE join
  sequence that both the web join (`MeetingHooks.join/1`) and the native app's
  join (`Platform.Mobile.NativeCall.join/2`) run.

  The order is load-bearing (two recorded bug fixes ride on it), so it is
  asserted from the SQL the call issues rather than from end state: end state
  alone cannot tell "participant row, then live participant" from the reverse.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Participant
  alias Platform.Meetings.Room
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  setup do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

    {meeting, space} = meeting_with_space!()
    %{meeting: meeting, space: space, user: create_user!("joiner")}
  end

  defp create_user!(label) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "join-for-user-#{label}-#{n}@example.com",
      name: "JoinForUser #{label} #{n}",
      oidc_sub: "oidc-join-for-user-#{label}-#{n}"
    })
    |> Repo.insert!()
  end

  defp meeting_with_space! do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Join For User #{n}"})

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Join For User Meeting #{n}",
        slug: "join-for-user-#{n}"
      })

    {meeting, Chat.get_space(meeting.chat_space_id)}
  end

  defp external_user! do
    n = System.unique_integer([:positive])

    org =
      %Org{}
      |> Org.changeset(%{
        name: "JFU Tenant #{n}",
        slug: "tenant_jfu_#{n}",
        parent_org_id: Tenancy.get_org_by_slug!("acme").id
      })
      |> Repo.insert!()

    user = create_user!("ext")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})
    user
  end

  # SQL of every query `fun` issues on this process, in order.
  defp capture_queries(fun) do
    ref = make_ref()
    test_pid = self()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:platform, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid, do: send(test_pid, {ref, metadata[:query]})
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

    {result, drain(ref, [])}
  end

  defp drain(ref, acc) do
    receive do
      {^ref, query} -> drain(ref, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp first_index(queries, prefix) do
    Enum.find_index(queries, &(is_binary(&1) and String.starts_with?(&1, prefix)))
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

  defp jwt_claims(token) do
    [_header, payload, _sig] = String.split(token, ".")
    payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  test "writes the chat participant row BEFORE the live participant row, then mints", ctx do
    {result, queries} =
      capture_queries(fn -> Meetings.join_for_user(ctx.space.id, ctx.user.id, "Ada") end)

    assert {:ok, %{token: token}} = result
    assert is_binary(token)

    chat_insert = first_index(queries, ~s(INSERT INTO "chat_participants"))
    live_insert = first_index(queries, ~s(INSERT INTO "meeting_participants"))

    assert is_integer(chat_insert), "no chat_participants insert was captured"
    assert is_integer(live_insert), "no meeting_participants insert was captured"
    assert chat_insert < live_insert
  end

  test "the identity is user:<id>, in the result and in the token's sub", ctx do
    assert {:ok, joined} = Meetings.join_for_user(ctx.space.id, ctx.user.id, "Ada")

    assert joined.identity == "user:#{ctx.user.id}"
    assert joined.room.livekit_room_name == Meetings.room_name_for_space(ctx.space.id)
    assert joined.room.status == "active"

    claims = jwt_claims(joined.token)
    assert claims["sub"] == "user:#{ctx.user.id}"
    assert claims["video"]["room"] == joined.room.livekit_room_name

    assert [%Participant{user_id: user_id, left_at: nil}] = live_rows(ctx.space.id)
    assert user_id == ctx.user.id
  end

  test "a second join reuses the live participant row", ctx do
    assert {:ok, _} = Meetings.join_for_user(ctx.space.id, ctx.user.id, "Ada")
    [first] = live_rows(ctx.space.id)

    assert {:ok, _} = Meetings.join_for_user(ctx.space.id, ctx.user.id, "Ada")
    assert [second] = live_rows(ctx.space.id)
    assert second.id == first.id

    assert length(Chat.list_participants(ctx.space.id, participant_type: "user")) == 1
  end

  describe "refusal" do
    setup ctx do
      ref = make_ref()
      test_pid = self()
      handler_id = {__MODULE__, :blocked, ref}

      :telemetry.attach(
        handler_id,
        [:platform, :auth, :access_blocked],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {ref, :blocked, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      Map.put(ctx, :blocked_ref, ref)
    end

    test "an uninvited external user is refused, writes nothing, and emits the same event",
         ctx do
      external = external_user!()
      # Seated in the space: the refusal must be about the invite, not chat
      # membership.
      {:ok, _} =
        Chat.add_participant(ctx.space.id, %{
          participant_type: "user",
          participant_id: external.id,
          joined_at: DateTime.utc_now()
        })

      chat_before = length(Chat.list_participants(ctx.space.id, participant_type: "user"))
      rooms_before = Repo.aggregate(from(r in Room, where: r.space_id == ^ctx.space.id), :count)

      assert {:error, :join_not_permitted} =
               Meetings.join_for_user(ctx.space.id, external.id, "Outsider")

      ref = ctx.blocked_ref
      assert_received {^ref, :blocked, metadata}
      assert metadata.reason == "external_meeting_join_denied"
      assert metadata.actor_id == external.id
      assert metadata.resource_type == "chat_space"
      assert metadata.resource_id == ctx.space.id

      assert length(Chat.list_participants(ctx.space.id, participant_type: "user")) ==
               chat_before

      assert Repo.aggregate(from(r in Room, where: r.space_id == ^ctx.space.id), :count) ==
               rooms_before

      assert live_rows(ctx.space.id) == []
    end

    test "the same external user WITH a live invite joins (both sides of the gate)", ctx do
      external = external_user!()

      %Invite{}
      |> Invite.changeset(%{
        meeting_id: ctx.meeting.id,
        user_id: external.id,
        display_name: "Invited Outsider"
      })
      |> Repo.insert!()

      assert {:ok, %{identity: identity}} =
               Meetings.join_for_user(ctx.space.id, external.id, "Invited Outsider")

      assert identity == "user:#{external.id}"
      ref = ctx.blocked_ref
      refute_received {^ref, :blocked, _}
    end
  end
end
