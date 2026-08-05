defmodule PlatformWeb.ChatLive.MeetingHooksJoinGateTest do
  @moduledoc """
  Task `019fb955-f8b1` stage 4 — the invite gate on the LiveKit join seam.

  Loading a meeting page and joining its call are different gates, and before
  this stage only the first one existed. `MeetingHooks.do_join/1` required an
  `:active_space` plus a binary `:user_id` and nothing else;
  `Meetings.generate_token/2` performs no membership check of its own.

  The reason the fence belongs HERE rather than on the meeting page is that the
  meeting page is not the only caller. `chat_live.html.heex` renders its "Meet"
  button gated on `@meetings_enabled && !@in_meeting` — NOT on `!@external?` —
  and `ChatLive` attaches these same hooks. The LiveKit room is keyed off the
  space, so both surfaces land in the same room: an external user seated in a
  meeting's bound chat space could join the call from the chat surface without
  ever touching the meet surface.

  Every test below pins BOTH sides of its claim. A single side passes on a
  build where the new branch does nothing at all, which is precisely the build
  this file exists to fail.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Participant
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.ChatLive.MeetingHooks

  # ── Fixtures ───────────────────────────────────────────────────────────────

  defp put_livekit_env(_ctx) do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

    :ok
  end

  defp create_user!(label) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "join-gate-#{label}-#{n}@example.com",
      name: "JoinGate #{label} #{n}",
      oidc_sub: "oidc-join-gate-#{label}-#{n}"
    })
    |> Repo.insert!()
  end

  defp tenant_org! do
    n = System.unique_integer([:positive])

    %Org{}
    |> Org.changeset(%{
      name: "Tenant #{n}",
      slug: "tenant_join_gate_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("fabrikam").id
    })
    |> Repo.insert!()
  end

  # A real meeting through the real constructor, which also mints the backing
  # chat space the join seam is handed.
  defp meeting_with_space! do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Join Gate Project #{n}"})

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Join Gate Meeting #{n}",
        slug: "join-gate-meeting-#{n}"
      })

    {meeting, Chat.get_space(meeting.chat_space_id)}
  end

  defp invite!(meeting, user, attrs \\ %{}) do
    %Invite{}
    |> Invite.changeset(
      Map.merge(
        %{meeting_id: meeting.id, user_id: user.id, display_name: "Join Gate Invitee"},
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp seat_in_space!(space, user) do
    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    :ok
  end

  defp build_socket(user_id, space) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        user_id: user_id,
        active_space: space,
        current_participant: nil,
        in_meeting: false,
        mic_enabled: true,
        camera_enabled: false,
        screen_share_enabled: false
      }
    }
  end

  # `push_event/3` writes to `socket.private.live_temp[:push_events]`; a bare
  # `%Socket{}` carries the same default private map a mounted one does.
  defp pushed_events(socket) do
    socket.private
    |> Map.get(:live_temp, %{})
    |> Map.get(:push_events, [])
  end

  defp joined_event(socket) do
    Enum.find(pushed_events(socket), fn
      ["join-meeting" | _] -> true
      _ -> false
    end)
  end

  defp participant_count(room) do
    Repo.aggregate(from(p in Participant, where: p.room_id == ^room.id), :count)
  end

  defp participant_rows(room) do
    Repo.all(from(p in Participant, where: p.room_id == ^room.id))
  end

  # Collect the SQL of every query `fun` issues on THIS process. Sandbox mode
  # means a query that never ran still returns plausible data to a caller
  # inspecting rows, so the only honest way to answer "did the internal path
  # pay for this?" is to watch `[:platform, :repo, :query]` directly.
  defp capture_queries(fun) do
    ref = make_ref()
    test_pid = self()
    handler_id = {__MODULE__, :queries, ref}

    :telemetry.attach(
      handler_id,
      [:platform, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if metadata[:caller_pid] == test_pid or self() == test_pid do
          send(test_pid, {ref, metadata[:query]})
        end
      end,
      nil
    )

    fun.()
    :telemetry.detach(handler_id)

    drain_queries(ref, [])
  end

  defp drain_queries(ref, acc) do
    receive do
      {^ref, query} -> drain_queries(ref, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp count_matching(queries, table) do
    Enum.count(queries, &(is_binary(&1) and String.contains?(&1, ~s("#{table}"))))
  end

  setup [:put_livekit_env]

  setup do
    org = tenant_org!()

    external = create_user!("ext")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: external.id, org_id: org.id})

    internal = create_user!("int")

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: internal.id, org_id: org.id, role: "member"})
    |> Repo.insert!()

    {meeting, space} = meeting_with_space!()

    # BOTH principals are seated in the meeting's bound chat space. That is
    # what makes the external denial below a statement about the INVITE row
    # rather than about chat membership — the two users differ in exactly one
    # fact, and the fixture is otherwise symmetric.
    seat_in_space!(space, external)
    seat_in_space!(space, internal)

    %{org: org, external: external, internal: internal, meeting: meeting, space: space}
  end

  # ── The gate ───────────────────────────────────────────────────────────────

  describe "external users at the join seam" do
    test "an INVITED external user joins: token, event and a user-bound row", ctx do
      invite!(ctx.meeting, ctx.external)

      joined = MeetingHooks.join(build_socket(ctx.external.id, ctx.space))

      assert joined.assigns.in_meeting == true
      assert ["join-meeting", payload] = joined_event(joined)
      assert is_binary(payload.token)

      {:ok, room} = Meetings.ensure_room(ctx.space.id)
      assert [%Participant{user_id: user_id}] = participant_rows(room)
      assert user_id == ctx.external.id
    end

    test "an UNINVITED external user is refused with a participant delta of 0", ctx do
      {:ok, room} = Meetings.ensure_room(ctx.space.id)

      # Seed one unrelated row so the count query is proven non-degenerate:
      # a delta of 0 measured from 0 is equally consistent with a `count/1`
      # that never sees anything.
      {:ok, _} =
        Meetings.upsert_live_participant(room, %{
          identity: "guest:" <> Ecto.UUID.generate(),
          name: "Unrelated Guest"
        })

      before_count = participant_count(room)
      assert before_count == 1

      refused = MeetingHooks.join(build_socket(ctx.external.id, ctx.space))

      refute refused.assigns.in_meeting
      assert joined_event(refused) == nil
      assert participant_count(room) - before_count == 0
    end

    test "an EXPIRED invite is refused, and the row count is unmoved", ctx do
      invite!(ctx.meeting, ctx.external, %{
        expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      })

      {:ok, room} = Meetings.ensure_room(ctx.space.id)
      before_count = participant_count(room)

      refused = MeetingHooks.join(build_socket(ctx.external.id, ctx.space))

      refute refused.assigns.in_meeting
      assert joined_event(refused) == nil
      assert participant_count(room) - before_count == 0
    end

    # Both halves in ONE test on ONE principal. Asserting only the post-revoke
    # refusal passes on a build that refused this user all along — the pre-
    # revoke success is what makes the second half mean "revocation did it".
    test "REVOCATION: the same user joins, then is refused after revoke", ctx do
      invite = invite!(ctx.meeting, ctx.external)

      joined = MeetingHooks.join(build_socket(ctx.external.id, ctx.space))
      assert joined.assigns.in_meeting == true
      assert joined_event(joined) != nil

      {:ok, revoked} = Meetings.revoke_invite(invite)
      assert revoked.revoked_at != nil

      refused = MeetingHooks.join(build_socket(ctx.external.id, ctx.space))

      refute refused.assigns.in_meeting
      assert joined_event(refused) == nil
    end

    test "the refusal emits access_blocked telemetry with the join reason", ctx do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:platform, :auth, :access_blocked],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:access_blocked, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

      refused = MeetingHooks.join(build_socket(ctx.external.id, ctx.space))
      refute refused.assigns.in_meeting

      assert_receive {:access_blocked, meta}
      assert meta.reason == "external_meeting_join_denied"
      assert meta.actor_id == ctx.external.id
      assert meta.resource_id == ctx.space.id
    end

    # The refusal must not be usable as an oracle from the client. A flash
    # keyed to "you are not invited" is exactly what turns a denial into a
    # meeting-directory probe — so assert the WHOLE socket comes back
    # identical rather than enumerating the things that must not be on it.
    # Struct equality also covers `private.live_temp` (no pushed events) and
    # every assign the happy path would have written.
    test "the refused socket is returned byte-identical to the one passed in", ctx do
      socket = build_socket(ctx.external.id, ctx.space)

      assert MeetingHooks.join(socket) == socket
    end
  end

  # ── The control that proves the gate did not simply break joining ──────────

  describe "internal users at the join seam" do
    test "an internal user with NO invite row joins exactly as before", ctx do
      refute Meetings.invited_to_space?(ctx.space.id, ctx.internal)

      joined = MeetingHooks.join(build_socket(ctx.internal.id, ctx.space))

      assert joined.assigns.in_meeting == true
      assert ["join-meeting", payload] = joined_event(joined)
      assert is_binary(payload.token)
      assert payload.url == Meetings.livekit_url()

      {:ok, room} = Meetings.ensure_room(ctx.space.id)
      assert [%Participant{user_id: user_id}] = participant_rows(room)
      assert user_id == ctx.internal.id
    end

    test "an internal user is admitted with the invite table completely empty", ctx do
      assert Repo.aggregate(Invite, :count) == 0

      joined = MeetingHooks.join(build_socket(ctx.internal.id, ctx.space))

      assert joined.assigns.in_meeting == true
    end

    # The cost claim, measured rather than asserted. "The internal path is
    # unchanged" is a statement about queries, and the only way to see queries
    # is to count them — `Repo` in sandbox mode will happily serve either
    # shape. Both sides again: the external join MUST show the invite lookup
    # and one extra `users` read, the internal join MUST show neither, or the
    # branch is not where the comment says it is.
    test "the invite lookup and the user load happen ONLY on the external path", ctx do
      invite!(ctx.meeting, ctx.external)

      internal =
        capture_queries(fn -> MeetingHooks.join(build_socket(ctx.internal.id, ctx.space)) end)

      external =
        capture_queries(fn -> MeetingHooks.join(build_socket(ctx.external.id, ctx.space)) end)

      assert count_matching(internal, "meeting_invites") == 0
      assert count_matching(external, "meeting_invites") == 1

      # `resolve_display_name/1` reads `users` on both paths; the gate's own
      # `Accounts.get_user/1` is the ONE extra read, and it is external-only.
      # The floor keeps the delta honest — `0 == 0 + 1` is false, but
      # `1 == 0 + 1` would let a capture that saw nothing at all pass.
      assert count_matching(internal, "users") > 0
      assert count_matching(external, "users") == count_matching(internal, "users") + 1
    end
  end

  # ── Identity prefixes: both sides, or the pin proves nothing ───────────────
  #
  # A build that minted one prefix for every joiner would pass an assertion on
  # either side alone, and that collision is the whole point of the prefix:
  # `Meetings.parse_identity/1` is what turns the LiveKit identity back into an
  # FK, and a guest that parses as `{:user, _}` would carry someone's user_id.
  describe "LiveKit identity" do
    test "an authenticated join is user-prefixed and FK-bound; a guest is neither", ctx do
      joined = MeetingHooks.join(build_socket(ctx.internal.id, ctx.space))
      assert joined.assigns.in_meeting == true

      {:ok, room} = Meetings.ensure_room(ctx.space.id)

      guest_uuid = Ecto.UUID.generate()

      {:ok, _} =
        Meetings.upsert_live_participant(room, %{
          identity: "guest:" <> guest_uuid,
          name: "A Guest"
        })

      rows = participant_rows(room)
      assert length(rows) == 2

      auth_row = Enum.find(rows, &(&1.user_id == ctx.internal.id))
      guest_row = Enum.find(rows, &is_nil(&1.user_id))

      # Authenticated side: user prefix, and the row carries the FK.
      assert auth_row.metadata["identity"] == "user:" <> ctx.internal.id
      assert Meetings.parse_identity(auth_row.metadata["identity"]) == {:user, ctx.internal.id}
      assert auth_row.user_id == ctx.internal.id

      # Guest side: guest prefix, and the row carries NO user FK.
      assert guest_row.metadata["identity"] == "guest:" <> guest_uuid
      assert Meetings.parse_identity(guest_row.metadata["identity"]) == {:guest, guest_uuid}
      assert guest_row.user_id == nil
    end
  end
end
