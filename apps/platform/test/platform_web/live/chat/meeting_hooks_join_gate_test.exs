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
      parent_org_id: Tenancy.get_org_by_slug!("acme").id
    })
    |> Repo.insert!()
  end

  # A real meeting through the real constructor, which also mints the backing
  # chat space the join seam is handed.
  defp meeting_with_space!(org \\ nil) do
    n = System.unique_integer([:positive])
    attrs = %{name: "Join Gate Project #{n}"}
    attrs = if org, do: Map.put(attrs, :org_id, org.id), else: attrs
    {:ok, project} = Tasks.create_project(attrs)

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

  # The production rejoin functions return `{result, socket}` (the socket
  # carries the write window); these tests pin the result.
  defp rejoin(socket, params), do: socket |> MeetingHooks.rejoin_token(params) |> elem(0)

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

    {meeting, space} = meeting_with_space!(org)

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

    test "an invite landing between join's two checks joins without crashing a full window",
         ctx do
      now = System.monotonic_time(:millisecond)
      full = for _ <- 1..MeetingHooks.write_throttle_limit(), do: now

      socket =
        ctx.external.id
        |> build_socket(ctx.space)
        |> then(&%{&1 | assigns: Map.put(&1.assigns, :write_requests, full)})

      # The window is full and the user is uninvited, so `join_throttled?/1`
      # sees "not permitted" and lets the call through to `attempt_join/1`.
      # The invite is granted right after that first invite query, so the
      # gate inside `join_for_user` then passes: the two checks disagree.
      test_pid = self()
      handler_id = {__MODULE__, :race, make_ref()}
      meeting = ctx.meeting
      external = ctx.external

      :telemetry.attach(
        handler_id,
        [:platform, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid and is_binary(metadata[:query]) and
               String.contains?(metadata[:query], ~s("meeting_invites")) and
               not Process.get(:race_invite_granted, false) do
            Process.put(:race_invite_granted, true)
            invite!(meeting, external)
          end
        end,
        nil
      )

      result =
        try do
          MeetingHooks.join(socket)
        after
          :telemetry.detach(handler_id)
        end

      assert Process.get(:race_invite_granted), "the race was never staged"
      assert %Phoenix.LiveView.Socket{} = result
      assert joined_event(result), "the join that already happened is kept"
      assert length(result.assigns.write_requests) == MeetingHooks.write_throttle_limit()
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

  # ── Rejoin token on a socket that is not in the call ───────────────────────
  #
  # A network drop remounts the LiveView: `:in_meeting` is false again, so the
  # old gate (`in_meeting == true || :not_in_meeting`) answered "unavailable"
  # and the client rejoined on the token it held, ignoring a revoke made
  # during the outage. A socket that is not in the call must still be refused
  # when the join gate would refuse it.
  # The room name the client holds (`_joinCreds.roomName`) and sends with
  # `meeting_rejoin_token`.
  defp held(space), do: %{"room_name" => Meetings.room_name_for_space(space.id)}

  describe "rejoin_token/2 gates on the HELD room, not the URL's space" do
    # After a remount `:active_space` is the URL's space (B) while the call
    # the client holds is in A. The gate must follow the room the client
    # holds, mapped back to its space by the server.
    setup ctx do
      {meeting_b, space_b} = meeting_with_space!(ctx.org)
      seat_in_space!(space_b, ctx.external)
      %{meeting_b: meeting_b, space_b: space_b}
    end

    test "revoked on A, live on B, URL on B: DENIED (not rejoined on the held token)", ctx do
      invite = invite!(ctx.meeting, ctx.external)
      invite!(ctx.meeting_b, ctx.external)
      {:ok, _} = Meetings.revoke_invite(invite)

      assert {:error, :join_not_permitted} =
               rejoin(
                 build_socket(ctx.external.id, ctx.space_b),
                 held(ctx.space)
               )
    end

    test "live on A, not invited to B, URL on B: NOT denied", ctx do
      invite!(ctx.meeting, ctx.external)

      assert {:error, :not_in_meeting} =
               rejoin(
                 build_socket(ctx.external.id, ctx.space_b),
                 held(ctx.space)
               )
    end

    test "no room name from a socket with no held call: unavailable, never the URL's space",
         ctx do
      assert {:error, :not_in_meeting} =
               rejoin(build_socket(ctx.external.id, ctx.space_b), %{})
    end

    test "a forged room name for a space the user is not seated in is DENIED", ctx do
      {_meeting_c, space_c} = meeting_with_space!(ctx.org)

      assert {:error, :not_a_participant} =
               rejoin(build_socket(ctx.internal.id, ctx.space), held(space_c))
    end

    test "a room name that maps to no space is DENIED", ctx do
      for name <- ["space-" <> Ecto.UUID.generate(), "meeting-123", "space-not-a-uuid", ""] do
        assert {:error, :unknown_room} =
                 rejoin(
                   build_socket(ctx.internal.id, ctx.space),
                   %{"room_name" => name}
                 )
      end

      assert {:error, :unknown_room} =
               rejoin(build_socket(ctx.internal.id, ctx.space), %{
                 "room_name" => 42
               })
    end

    test "call_space_id names the call: a payload room for another space is gated on its own, never minted",
         ctx do
      invite!(ctx.meeting, ctx.external)
      joined = MeetingHooks.join(build_socket(ctx.external.id, ctx.space))
      assert joined.assigns.call_space_id == ctx.space.id

      # B is seated but not invited: its own gate denies
      assert {:error, :join_not_permitted} = rejoin(joined, held(ctx.space_b))
      invite!(ctx.meeting_b, ctx.external)
      # B permitted: still no token, the socket is not in B's call
      assert {:error, :not_in_meeting} = rejoin(joined, held(ctx.space_b))
      assert {:ok, %{token: _}} = rejoin(joined, held(ctx.space))
    end
  end

  describe "rejoin_token/2 on a socket that is not in the call" do
    test "an external user without a live invite is DENIED", ctx do
      assert {:error, :join_not_permitted} =
               rejoin(
                 build_socket(ctx.external.id, ctx.space),
                 held(ctx.space)
               )

      assert MeetingHooks.rejoin_reply(
               rejoin(
                 build_socket(ctx.external.id, ctx.space),
                 held(ctx.space)
               )
             ) == %{error: "denied"}
    end

    test "naming the held call is not enough: in_meeting false is refused, in_meeting true mints",
         ctx do
      # `same_call?` (call_space_id matches) AND `in_meeting` both decide the
      # `:ok` branch of the gate. Each half alone must not mint.
      left =
        ctx.internal.id
        |> build_socket(ctx.space)
        |> Phoenix.Component.assign(:call_space_id, ctx.space.id)

      assert {:error, :not_in_meeting} = rejoin(left, held(ctx.space))

      in_call = Phoenix.Component.assign(left, :in_meeting, true)
      assert {:ok, %{token: _}} = rejoin(in_call, held(ctx.space))
    end

    test "a benign remount (gate passes) stays unavailable, for internal and invited", ctx do
      invite!(ctx.meeting, ctx.external)

      for user <- [ctx.internal, ctx.external] do
        assert {:error, :not_in_meeting} =
                 rejoin(build_socket(user.id, ctx.space), held(ctx.space))
      end

      assert MeetingHooks.rejoin_reply(
               rejoin(
                 build_socket(ctx.internal.id, ctx.space),
                 held(ctx.space)
               )
             ) == %{error: "unavailable"}
    end

    test "drop + remount + revoke: restore leaves the socket out, rejoin is DENIED", ctx do
      invite = invite!(ctx.meeting, ctx.external)
      joined = MeetingHooks.join(build_socket(ctx.external.id, ctx.space))
      assert joined.assigns.in_meeting == true

      {:ok, _} = Meetings.revoke_invite(invite)

      remounted =
        ctx.external.id
        |> build_socket(ctx.space)
        |> Phoenix.Component.assign(:meeting_reconnect?, true)
        |> MeetingHooks.maybe_restore_on_reconnect(ctx.space)

      refute remounted.assigns.in_meeting

      assert MeetingHooks.rejoin_reply(rejoin(remounted, held(ctx.space))) ==
               %{
                 error: "denied"
               }
    end

    test "drop + remount without a revoke: restore re-joins and the rejoin mints", ctx do
      invite!(ctx.meeting, ctx.external)
      _ = MeetingHooks.join(build_socket(ctx.external.id, ctx.space))

      remounted =
        ctx.external.id
        |> build_socket(ctx.space)
        |> Phoenix.Component.assign(:meeting_reconnect?, true)
        |> MeetingHooks.maybe_restore_on_reconnect(ctx.space)

      assert remounted.assigns.in_meeting == true

      assert {:ok, %{token: token, room_name: room_name}} =
               rejoin(remounted, held(ctx.space))

      assert is_binary(token)
      {:ok, room} = Meetings.ensure_room(ctx.space.id)
      assert room_name == room.livekit_room_name
    end
  end

  describe "rejoin_token/2 when the restore join landed in a different space than the held room" do
    # Remount on URL space B where the user also has a stale active participant
    # row: `maybe_restore_on_reconnect` joins B and sets `call_space_id` to B,
    # while the client still holds room A. That mismatch is not evidence of a
    # revoke: A is gated on its own merits and nothing is minted for either.
    setup ctx do
      {meeting_b, space_b} = meeting_with_space!(ctx.org)
      seat_in_space!(space_b, ctx.external)
      invite!(meeting_b, ctx.external)

      # the stale active row in B
      _ = MeetingHooks.join(build_socket(ctx.external.id, space_b))

      restored =
        ctx.external.id
        |> build_socket(space_b)
        |> Phoenix.Component.assign(:meeting_reconnect?, true)
        |> MeetingHooks.maybe_restore_on_reconnect(space_b)

      assert restored.assigns.call_space_id == space_b.id
      %{restored: restored, space_b: space_b}
    end

    test "A still permitted: unavailable (not denied), nothing minted", ctx do
      invite!(ctx.meeting, ctx.external)

      result = rejoin(ctx.restored, held(ctx.space))
      assert {:error, :not_in_meeting} = result
      assert MeetingHooks.rejoin_reply(result) == %{error: "unavailable"}
    end

    test "A revoked: denied", ctx do
      invite = invite!(ctx.meeting, ctx.external)
      {:ok, _} = Meetings.revoke_invite(invite)

      assert MeetingHooks.rejoin_reply(rejoin(ctx.restored, held(ctx.space))) ==
               %{error: "denied"}
    end
  end

  describe "rejoin_token/2 gate is the deciding line" do
    test "a seated external user with an EXPIRED invite is refused by the gate, before the mint path",
         ctx do
      invite!(ctx.meeting, ctx.external, %{
        expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      })

      handler = {__MODULE__, :blocked, make_ref()}
      test_pid = self()

      :telemetry.attach(
        handler,
        [:platform, :auth, :access_blocked],
        fn _e, _m, meta, _c -> send(test_pid, {:blocked, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:error, :join_not_permitted} =
               rejoin(
                 build_socket(ctx.external.id, ctx.space),
                 held(ctx.space)
               )

      # `join_for_user/3` would also refuse, but it emits access_blocked; a
      # gate that does its job stops the request before reaching it.
      refute_received {:blocked, _}
    end

    # The fence is the rule the mount applies: `Access.fenced_ids(scope, :space)`
    # (the user's orgs PLUS every space they hold a participant row in), and
    # `:unfenced` for a guest or a user with no memberships. These tests pin
    # that a seated user is never denied by an org fence the mount would not
    # apply to them.
    defp member!(user, org) do
      %OrgMembership{}
      |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
      |> Repo.insert!()
    end

    defp in_call(socket) do
      socket
      |> Phoenix.Component.assign(:in_meeting, true)
      |> Phoenix.Component.assign(:call_space_id, socket.assigns.active_space.id)
    end

    test "A: a sub-org member seated in a space with no org is not denied", ctx do
      {_meeting, space} = meeting_with_space!()

      {1, _} =
        Repo.update_all(from(s in Platform.Chat.Space, where: s.id == ^space.id),
          set: [org_id: nil]
        )

      space = Chat.get_space(space.id)
      assert space.org_id == nil
      user = create_user!("suborg-nil")
      member!(user, ctx.org)
      seat_in_space!(space, user)

      assert {:error, :not_in_meeting} =
               rejoin(build_socket(user.id, space), held(space))

      assert {:ok, %{token: _}} =
               rejoin(in_call(build_socket(user.id, space)), held(space))
    end

    test "A: a sub-org member seated in a space of another org is not denied", ctx do
      {_meeting, space} = meeting_with_space!(tenant_org!())
      refute space.org_id == ctx.org.id
      user = create_user!("suborg-other")
      member!(user, ctx.org)
      seat_in_space!(space, user)

      assert {:error, :not_in_meeting} =
               rejoin(build_socket(user.id, space), held(space))

      assert {:ok, %{token: _}} =
               rejoin(in_call(build_socket(user.id, space)), held(space))
    end

    test "B: a seated user with no membership rows is not denied", ctx do
      user = create_user!("nomember")
      seat_in_space!(ctx.space, user)

      assert {:error, :not_in_meeting} =
               rejoin(build_socket(user.id, ctx.space), held(ctx.space))

      assert {:ok, %{token: _}} =
               rejoin(
                 in_call(build_socket(user.id, ctx.space)),
                 held(ctx.space)
               )
    end

    test "B: a former member (memberships gone) seated in the space follows the mount rule: not denied",
         ctx do
      former = create_user!("former")
      member!(former, ctx.org)
      seat_in_space!(ctx.space, former)
      Repo.delete_all(from(m in OrgMembership, where: m.user_id == ^former.id))

      assert {:error, :not_in_meeting} =
               rejoin(build_socket(former.id, ctx.space), held(ctx.space))

      assert {:ok, %{token: _}} =
               rejoin(
                 in_call(build_socket(former.id, ctx.space)),
                 held(ctx.space)
               )
    end

    test "C: an invited, seated external user whose space is outside their membership org is not denied",
         ctx do
      {meeting, space} = meeting_with_space!(tenant_org!())
      seat_in_space!(space, ctx.external)
      invite!(meeting, ctx.external)

      assert {:error, :not_in_meeting} =
               rejoin(build_socket(ctx.external.id, space), held(space))

      assert {:ok, %{token: _}} =
               rejoin(
                 in_call(build_socket(ctx.external.id, space)),
                 held(space)
               )
    end

    test "a member of org X who is NOT seated in a space of org Y is DENIED by the fence", ctx do
      {_meeting, space_y} = meeting_with_space!(tenant_org!())
      outsider = create_user!("outsider")
      member!(outsider, ctx.org)

      assert {:error, :join_not_permitted} =
               rejoin(build_socket(outsider.id, space_y), held(space_y))

      assert {:error, :join_not_permitted} =
               rejoin(
                 in_call(build_socket(outsider.id, space_y)),
                 held(space_y)
               )
    end

    # `:access_scope` is a mount-time snapshot that only grant/role changes
    # refresh; an org-membership removal does not. The rejoin must build the
    # scope fresh, so the removal shows.
    test "a stale :access_scope that still names org X does not admit a user removed from X",
         ctx do
      user = create_user!("stale")
      member!(user, ctx.org)
      member!(user, tenant_org!())

      stale = Platform.Access.scope_for(Platform.Accounts.get_user(user.id))

      Repo.delete_all(
        from(m in OrgMembership, where: m.user_id == ^user.id and m.org_id == ^ctx.org.id)
      )

      socket =
        user.id
        |> build_socket(ctx.space)
        |> in_call()
        |> Phoenix.Component.assign(:access_scope, stale)

      # not seated: the fence (fresh) is what refuses, not the seat gate
      assert {:error, :join_not_permitted} = rejoin(socket, held(ctx.space))
    end

    test "a stale :access_scope, user removed from X but still seated: the mount rule keeps the space",
         ctx do
      user = create_user!("stale-seated")
      member!(user, ctx.org)
      member!(user, tenant_org!())
      seat_in_space!(ctx.space, user)

      stale = Platform.Access.scope_for(Platform.Accounts.get_user(user.id))

      Repo.delete_all(
        from(m in OrgMembership, where: m.user_id == ^user.id and m.org_id == ^ctx.org.id)
      )

      socket =
        user.id
        |> build_socket(ctx.space)
        |> in_call()
        |> Phoenix.Component.assign(:access_scope, stale)

      assert {:ok, %{token: _}} = rejoin(socket, held(ctx.space))
    end

    test "a deleted user is refused before any fence (nil user is not :unfenced)", ctx do
      user = create_user!("deleted")
      member!(user, ctx.org)
      seat_in_space!(ctx.space, user)
      Repo.delete_all(from(m in OrgMembership, where: m.user_id == ^user.id))
      Repo.delete_all(from(u in User, where: u.id == ^user.id))

      assert {:error, :join_not_permitted} =
               rejoin(
                 in_call(build_socket(user.id, ctx.space)),
                 held(ctx.space)
               )
    end

    test "an archived user in the call is refused a token (get_user does not filter archived_at)",
         ctx do
      user = create_user!("archived")
      member!(user, ctx.org)
      seat_in_space!(ctx.space, user)
      socket = in_call(build_socket(user.id, ctx.space))

      # control: the same user and socket mint before the archive
      assert {:ok, _} = rejoin(socket, held(ctx.space))

      {:ok, _} = Platform.Accounts.archive_user(user)

      assert {:error, :join_not_permitted} = rejoin(socket, held(ctx.space))
    end

    test "a root-org member follows the root rule: the fence admits a space of any org", ctx do
      root_member = create_user!("root")
      member!(root_member, Tenancy.get_org_by_slug!("acme"))

      # past the fence; unseated, so the seat gate (not the fence) refuses
      assert {:error, :not_a_participant} =
               rejoin(
                 build_socket(root_member.id, ctx.space),
                 held(ctx.space)
               )
    end
  end

  describe "rejoin_reply/1 logging" do
    import ExUnit.CaptureLog

    test "a changeset or map reason never reaches the log; an atom does" do
      cs =
        Ecto.Changeset.change(%User{}, %{email: "leak-me@example.com", name: "Leaky Name"})
        |> Ecto.Changeset.add_error(:email, "bad")

      log =
        capture_log(fn ->
          assert MeetingHooks.rejoin_reply({:error, cs}) == %{error: "unavailable"}

          assert MeetingHooks.rejoin_reply(
                   {:error, %{headers: [{"authorization", "Bearer sekrit-token"}]}}
                 ) == %{error: "unavailable"}

          MeetingHooks.rejoin_reply({:error, :livekit_not_configured})
        end)

      refute log =~ "leak-me@example.com"
      refute log =~ "Leaky Name"
      refute log =~ "sekrit-token"
      refute log =~ "authorization"
      assert log =~ "Ecto.Changeset"
      assert log =~ "livekit_not_configured"
    end
  end
end
