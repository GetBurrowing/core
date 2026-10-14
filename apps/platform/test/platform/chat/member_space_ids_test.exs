defmodule Platform.Chat.MemberSpaceIdsTest do
  @moduledoc """
  rbac-external-users M10 stage 1 — the pure presence/typing scoping primitives.

  `Chat.list_member_space_ids/2` and `Chat.Presence.external_scope_space_ids/1`
  are the single source of truth for the allowlist consumed by the ChatLive
  subscribe loop (stage 2) and the PresenceHooks consumer guards (stage 3), so
  they are unit-tested here without a LiveView.

  `Chat.total_unread_for_viewer/1` joined them (task
  `01a02491-a407-794f-a13e-d18398e4b092` stage 1) because it reads the same
  member query. It is the number behind the left icon rail's Chat badge, and
  the two sets have to be tested together: the badge counted spaces the Chat
  surface never renders, so no amount of reading could take it to zero, and
  the obvious repair (narrowing the member query itself) would have silently
  shrunk presence and dropped ShellLive's broadcast subscriptions.
  """
  use Platform.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Chat.Participant
  alias Platform.Chat.Presence, as: ChatPresence
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.ChatPin
  alias Platform.Tasks.ChatPins
  alias Platform.Tasks.Task, as: TaskRow
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp create_user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{email: "u-#{n}@example.com", name: "User #{n}", oidc_sub: "oidc-#{n}"})
    |> Repo.insert!()
  end

  defp channel(attrs \\ %{}) do
    default = %{
      name: "Chan",
      slug: "chan-#{System.unique_integer([:positive])}",
      kind: "channel"
    }

    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp member!(user, org) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
    |> Repo.insert!()
  end

  defp add_user(space_id, user_id) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user_id,
        joined_at: DateTime.utc_now()
      })

    p
  end

  describe "list_member_space_ids/2" do
    test "returns only the spaces the user is a participant of" do
      user = create_user!()
      other = create_user!()
      a = channel()
      b = channel()

      add_user(a.id, user.id)
      # user is NOT a participant of b — only `other` is.
      add_user(b.id, other.id)

      ids = Chat.list_member_space_ids(user.id)

      assert a.id in ids
      refute b.id in ids
    end

    test "excludes archived spaces the user still participates in" do
      user = create_user!()
      live = channel()
      archived = channel()

      add_user(live.id, user.id)
      add_user(archived.id, user.id)
      {:ok, _} = Chat.archive_space(archived)

      ids = Chat.list_member_space_ids(user.id)

      assert live.id in ids
      refute archived.id in ids
    end

    test "returns an empty list for a user who participates in nothing" do
      user = create_user!()
      _a = channel()

      assert Chat.list_member_space_ids(user.id) == []
    end

    test "honors the :kind opt" do
      user = create_user!()
      chan = channel(%{kind: "channel"})

      dm =
        channel(%{kind: "dm", slug: "dm-#{System.unique_integer([:positive])}", name: "DM"})

      add_user(chan.id, user.id)
      add_user(dm.id, user.id)

      channel_ids = Chat.list_member_space_ids(user.id, kind: "channel")

      assert chan.id in channel_ids
      refute dm.id in channel_ids
    end
  end

  describe "list_viewer_presence_space_ids/1" do
    # Every absence assertion below shares a fixture with a positive control:
    # an unconditional `[]` is the exact shape of total breakage here, so a
    # test that only asserts absence would pass on a completely broken
    # function.
    setup do
      home = Tenancy.get_org_by_slug!("sxi")
      foreign = Tenancy.get_org_by_slug!("soylent")

      viewer = create_user!()
      colleague = create_user!()
      member!(viewer, home)
      member!(colleague, home)

      %{home: home, foreign: foreign, viewer: viewer, colleague: colleague}
    end

    test "returns a shared in-org space and withholds foreign-org and archived ones", ctx do
      shared = channel(%{org_id: ctx.home.id})
      foreign_space = channel(%{org_id: ctx.foreign.id})
      archived = channel(%{org_id: ctx.home.id})

      add_user(shared.id, ctx.viewer.id)
      add_user(shared.id, ctx.colleague.id)
      # The viewer somehow holds a participant row in the foreign org's space:
      # membership alone must not be enough to see it.
      add_user(foreign_space.id, ctx.viewer.id)
      add_user(archived.id, ctx.viewer.id)
      {:ok, _} = Chat.archive_space(archived)

      ids = Chat.list_viewer_presence_space_ids(ctx.viewer)

      # Positive control — without this the refutes below prove nothing.
      assert shared.id in ids
      refute foreign_space.id in ids
      refute archived.id in ids
    end

    test "a space the viewer does not participate in is withheld even in their own org", ctx do
      shared = channel(%{org_id: ctx.home.id})
      colleague_only = channel(%{org_id: ctx.home.id})

      add_user(shared.id, ctx.viewer.id)
      add_user(colleague_only.id, ctx.colleague.id)

      ids = Chat.list_viewer_presence_space_ids(ctx.viewer)

      assert shared.id in ids
      refute colleague_only.id in ids
    end

    test "a viewer resolving to :none gets [] rather than everything", ctx do
      shared = channel(%{org_id: ctx.home.id})
      unaffiliated = create_user!()

      add_user(shared.id, ctx.viewer.id)
      add_user(shared.id, unaffiliated.id)

      assert Tenancy.visibility(unaffiliated) == :none

      # Same fixture, same space, same participant row shape — the ONLY
      # difference is the org membership, so a function that returned `[]`
      # for everyone would fail on the control.
      assert shared.id in Chat.list_viewer_presence_space_ids(ctx.viewer)
      assert Chat.list_viewer_presence_space_ids(unaffiliated) == []
    end

    test "resolves identically from a preloaded user struct (zero-query path)", ctx do
      shared = channel(%{org_id: ctx.home.id})
      foreign_space = channel(%{org_id: ctx.foreign.id})
      add_user(shared.id, ctx.viewer.id)
      add_user(foreign_space.id, ctx.viewer.id)

      preloaded = Repo.preload(ctx.viewer, org_memberships: :org)
      assert {:orgs, _} = Tenancy.visibility(preloaded)

      ids = Chat.list_viewer_presence_space_ids(preloaded)

      assert shared.id in ids
      refute foreign_space.id in ids
    end

    test "non-user input returns []" do
      assert Chat.list_viewer_presence_space_ids(nil) == []
      assert Chat.list_viewer_presence_space_ids(%{}) == []
    end
  end

  describe "external_scope_space_ids/1" do
    test "returns a MapSet of the member space ids" do
      user = create_user!()
      a = channel()
      b = channel()
      add_user(a.id, user.id)
      add_user(b.id, user.id)

      scope = ChatPresence.external_scope_space_ids(user.id)

      assert %MapSet{} = scope
      assert MapSet.member?(scope, a.id)
      assert MapSet.member?(scope, b.id)
    end

    test "excludes archived and non-participant spaces (mirrors list_member_space_ids)" do
      user = create_user!()
      other = create_user!()
      member = channel()
      archived = channel()
      foreign = channel()

      add_user(member.id, user.id)
      add_user(archived.id, user.id)
      add_user(foreign.id, other.id)
      {:ok, _} = Chat.archive_space(archived)

      scope = ChatPresence.external_scope_space_ids(user.id)

      assert MapSet.member?(scope, member.id)
      refute MapSet.member?(scope, archived.id)
      refute MapSet.member?(scope, foreign.id)
    end
  end

  describe "total_unread_for_viewer/1 counts only the kinds Chat renders" do
    setup do
      # A root-org member, which is the shape of every user this app creates
      # and the shape of the account the defect was reported from. Root
      # membership resolves `Tenancy.visibility/1` to `:root_all`.
      #
      # Since task 01a01f4c the count carries NO org fence, so this viewer is
      # no longer the only shape under which the refutes below mean something:
      # they are the kind allow-list's work at any visibility. The `:root_all`
      # guard is kept as a POSITIVE CONTROL rather than as a fence-defeater.
      # This block is the case that already worked before the fence came off,
      # and nothing in it may move. The zero-org and cross-org blocks further
      # down are where the fence's removal is measured.
      root = Tenancy.get_org_by_slug!("acme")
      viewer = create_user!()
      member!(viewer, root)

      assert Tenancy.visibility(viewer) == :root_all,
             "the fixture viewer must resolve :root_all: this block is the positive control, the case that already worked"

      %{viewer: viewer, root: root}
    end

    test "a meeting space holding unread is not counted; a channel holding unread is",
         ctx do
      chan = space_of_kind("channel")
      meeting = space_of_kind("meeting")

      seat_with_unread!(chan, ctx.viewer, 2)
      seat_with_unread!(meeting, ctx.viewer, 3)

      # PRECONDITION, and the test turns on it. `total_unread_for_viewer/1` is
      # an intersection of two sets; assert the meeting space is in BOTH of
      # them before refuting the total, or the refute proves only that some
      # unrelated gate already excluded it.
      counts = Chat.unread_counts_for_user(ctx.viewer.id)
      assert Map.get(counts, chan.id) == 2
      assert Map.get(counts, meeting.id) == 3

      # Read from `list_member_space_ids/1`, which is the set
      # `total_unread_for_viewer/1` derives from since task 01a01f4c. Reading
      # the org-fenced list here would assert a precondition on a query the
      # count no longer touches.
      member_ids = Chat.list_member_space_ids(ctx.viewer.id)
      assert chan.id in member_ids
      assert meeting.id in member_ids

      # Paired with the channel deliberately: a `total_unread_for_viewer/1`
      # that returned 0 for everything would pass a bare refute.
      assert Chat.total_unread_for_viewer(ctx.viewer) == 2
    end

    test "dm and group are counted; guest_meeting and execution are not", ctx do
      dm = space_of_kind("dm")
      group = space_of_kind("group")
      # A guest-meeting space DOES carry an org_id in production, so this one
      # is not screened out by the org fence for any viewer. It is a live
      # contributor to the reported number, not a hypothetical.
      guest_meeting = space_of_kind("guest_meeting", %{org_id: ctx.root.id})
      execution = space_of_kind("execution")

      seat_with_unread!(dm, ctx.viewer, 1)
      seat_with_unread!(group, ctx.viewer, 2)
      seat_with_unread!(guest_meeting, ctx.viewer, 4)
      seat_with_unread!(execution, ctx.viewer, 5)

      counts = Chat.unread_counts_for_user(ctx.viewer.id)
      assert Map.get(counts, guest_meeting.id) == 4
      assert Map.get(counts, execution.id) == 5

      member_ids = Chat.list_member_space_ids(ctx.viewer.id)
      assert guest_meeting.id in member_ids
      assert execution.id in member_ids

      assert Chat.total_unread_for_viewer(ctx.viewer) == 3
    end

    test "reading every Chat conversation drives the total to 0, even with an unread meeting",
         ctx do
      chan = space_of_kind("channel")
      dm = space_of_kind("dm")
      group = space_of_kind("group")
      meeting = space_of_kind("meeting")

      seats = Enum.map([chan, dm, group], &{&1, seat_with_unread!(&1, ctx.viewer, 2)})
      # Never read, and it must not matter.
      seat_with_unread!(meeting, ctx.viewer, 7)

      assert Chat.total_unread_for_viewer(ctx.viewer) == 6

      Enum.each(seats, fn {_space, seat} ->
        Chat.mark_space_read(seat.participant.id, seat.newest.id)
      end)

      # The state the reporter said was unreachable: read everything Chat
      # shows you, and the rail badge disappears.
      assert Chat.total_unread_for_viewer(ctx.viewer) == 0
    end

    test "list_viewer_presence_space_ids/1 still returns every kind", ctx do
      chan = space_of_kind("channel")
      meeting = space_of_kind("meeting")
      execution = space_of_kind("execution")

      add_user(chan.id, ctx.viewer.id)
      add_user(meeting.id, ctx.viewer.id)
      add_user(execution.id, ctx.viewer.id)

      ids = Chat.list_viewer_presence_space_ids(ctx.viewer)

      # This is the assertion that protects `Chat.Presence`, which reads this
      # list. Narrowing it to the badge's kinds would shrink presence with no
      # visible failure, so the kind predicate lives in
      # `total_unread_for_viewer/1` alone.
      #
      # ShellLive's subscribe set no longer reads this function: since task
      # 01a01f4c it reads `Chat.list_member_space_ids/1`, which is
      # participation-only. This one stays org-fenced precisely because
      # `Chat.Presence.list_online_for_viewer/1` carries other people's names.
      assert chan.id in ids
      assert meeting.id in ids
      assert execution.id in ids
    end

    test "unread on a PINNED task conversation is not counted, a known gap", ctx do
      # DECISION PIN, not a bug. Task `01a02491-a407-794f-a13e-d18398e4b092`
      # stage 1 is where this was called. The Chat sidebar renders a fourth
      # stream the badge's allow-list cannot express: pinned task
      # conversations are `kind: "execution"` spaces and they DO render unread
      # pills, so one can show a pill that adds nothing to the rail badge.
      #
      # Accepted, because the two errors are not symmetric. Over-counting is
      # the uncleariable badge being fixed here; under-counting is a pill with
      # no badge, which is self-explaining. Membership in the pinned set is a
      # row in `task_chat_pins` rather than a kind, so no kind predicate can
      # express it and pulling it in would couple the badge to the Tasks
      # context. Raised as a follow-up product question rather than absorbed.
      chan = space_of_kind("channel")
      seat_with_unread!(chan, ctx.viewer, 2)

      pinned = pinned_task_space!(ctx.viewer, ctx.root)
      seat_with_unread!(pinned, ctx.viewer, 4)

      assert pinned.kind == "execution"

      # It really is on this viewer's rail: the same query the Pinned block
      # renders from returns it.
      pinned_ids =
        ctx.viewer
        |> pin_identity()
        |> ChatPins.list_pinned_task_spaces_for()
        |> Enum.map(& &1.id)

      assert pinned.id in pinned_ids

      assert Map.get(Chat.unread_counts_for_user(ctx.viewer.id), pinned.id) == 4

      # Only the channel. Change this number and you are changing the decision
      # above, not fixing a test.
      assert Chat.total_unread_for_viewer(ctx.viewer) == 2
    end
  end

  describe "mark_all_chat_spaces_read/1 clears exactly the set the badge counts" do
    setup do
      # Same root-org viewer as the block above, and for the same reason: this
      # is the positive control, the shape that already worked before task
      # 01a01f4c took the org fence off the count and off the write.
      root = Tenancy.get_org_by_slug!("acme")
      viewer = create_user!()
      member!(viewer, root)

      assert Tenancy.visibility(viewer) == :root_all,
             "the fixture viewer must resolve :root_all: this block is the positive control, the case that already worked"

      %{viewer: viewer, root: root}
    end

    test "takes the badge to zero and leaves a meeting space's cursor untouched", ctx do
      chan = space_of_kind("channel")
      dm = space_of_kind("dm")
      group = space_of_kind("group")
      meeting = space_of_kind("meeting")

      seat_with_unread!(chan, ctx.viewer, 3)
      seat_with_unread!(dm, ctx.viewer, 1)
      seat_with_unread!(group, ctx.viewer, 2)
      meeting_seat = seat_with_unread!(meeting, ctx.viewer, 4)

      assert Chat.total_unread_for_viewer(ctx.viewer) == 6
      assert is_nil(cursor(meeting_seat))

      # Three cursors moved: the channel, the dm and the group. Not four.
      assert {:ok, 3} = Chat.mark_all_chat_spaces_read(ctx.viewer)

      assert Chat.total_unread_for_viewer(ctx.viewer) == 0

      # THE HALF THAT MAKES THE REST MEAN SOMETHING. A version that marked
      # every participant row read passes every assertion above while silently
      # destroying the unread state of a conversation the viewer has never
      # opened.
      assert is_nil(cursor(meeting_seat))
      assert Map.get(Chat.unread_counts_for_user(ctx.viewer.id), meeting.id) == 4
    end

    test "every cursor lands on its OWN tip, and none of them moves backward", ctx do
      caught_up = space_of_kind("channel")
      behind = space_of_kind("channel")
      ahead = space_of_kind("channel")

      caught_up_seat = seat_with_unread!(caught_up, ctx.viewer, 2)
      behind_seat = seat_with_unread!(behind, ctx.viewer, 3)
      ahead_seat = seat_with_unread!(ahead, ctx.viewer, 1)

      # Already read to this space's newest message.
      Chat.mark_space_read(caught_up_seat.participant.id, caught_up_seat.newest.id)

      # Parked PAST the top-level tip, which is what a thread reply's id does:
      # the reply is newer than every top-level message, and `mark_space_read/2`
      # stamps whatever id it is handed.
      tick!()
      reply = thread_reply!(ahead, ahead_seat.newest)
      Chat.mark_space_read(ahead_seat.participant.id, reply.id)

      # Only `behind` has anywhere to move.
      assert {:ok, 1} = Chat.mark_all_chat_spaces_read(ctx.viewer)

      # Each space's own newest message, never one shared id. Ids are UUIDv7,
      # so a cursor carrying a busier space's id sits in that space's future
      # and would suppress genuinely new messages here until wall clock caught
      # up.
      assert cursor(caught_up_seat) == caught_up_seat.newest.id
      assert cursor(behind_seat) == behind_seat.newest.id
      refute cursor(caught_up_seat) == cursor(behind_seat)

      # Backward is the corruption being guarded: it resurrects unread on a
      # conversation the reader had already finished.
      assert cursor(ahead_seat) == reply.id
      assert cursor(ahead_seat) > ahead_seat.newest.id
    end

    test "a second call with nothing unread is a no-op, and so is an empty viewer", ctx do
      chan = space_of_kind("channel")
      seat = seat_with_unread!(chan, ctx.viewer, 2)

      assert {:ok, 1} = Chat.mark_all_chat_spaces_read(ctx.viewer)
      first = cursor(seat)

      assert {:ok, 0} = Chat.mark_all_chat_spaces_read(ctx.viewer)
      assert cursor(seat) == first
      assert Chat.total_unread_for_viewer(ctx.viewer) == 0

      assert {:ok, 0} = Chat.mark_all_chat_spaces_read(create_user!())
      assert {:ok, 0} = Chat.mark_all_chat_spaces_read(nil)
    end

    test "the cursor stops at the newest top-level, non-deleted message", ctx do
      chan = space_of_kind("channel")
      seat = seat_with_unread!(chan, ctx.viewer, 2)

      # Both are newer than every top-level message and neither is unread:
      # `count_unread/3` filters `thread_id` and `deleted_at` out.
      tick!()
      reply = thread_reply!(chan, seat.newest)
      deleted = deleted_message!(chan, seat.newest.participant_id)

      assert Map.get(Chat.unread_counts_for_user(ctx.viewer.id), chan.id) == 2

      # A space holding nothing but rows that cannot be unread is skipped
      # entirely rather than stamped with something.
      quiet = space_of_kind("channel")
      quiet_seat = seat_with_unread!(quiet, ctx.viewer, 1)
      Chat.mark_space_read(quiet_seat.participant.id, quiet_seat.newest.id)
      tick!()
      _ = thread_reply!(quiet, quiet_seat.newest)

      assert {:ok, 1} = Chat.mark_all_chat_spaces_read(ctx.viewer)

      assert cursor(seat) == seat.newest.id
      refute cursor(seat) == reply.id
      refute cursor(seat) == deleted.id
      assert cursor(seat) < reply.id
      assert cursor(seat) < deleted.id
      assert cursor(quiet_seat) == quiet_seat.newest.id
      assert Chat.total_unread_for_viewer(ctx.viewer) == 0

      # And the next real message still arrives as exactly one unread, which is
      # what a cursor parked past those rows would put at risk.
      tick!()
      next = post_from_author!(chan, seat.newest.participant_id)
      assert next.id > cursor(seat)
      assert Chat.total_unread_for_viewer(ctx.viewer) == 1
    end
  end

  describe "the count follows participation, not org visibility" do
    # ANTI-VACUITY NOTE FOR THE WHOLE BLOCK. Every other badge test in this
    # file runs on a `:root_all` viewer, and `Tenancy.scope(q, :root_all, _)`
    # is the identity, so taking the org fence off the count (task 01a01f4c)
    # reddens nothing that shipped before it. These tests are the evidence.
    # The `Tenancy.visibility/1` precondition in each one is load-bearing: a
    # viewer who picked up a membership by accident would exercise nothing.

    test "a viewer with zero org memberships: the badge agrees with the pills" do
      viewer = create_user!()
      chan = space_of_kind("channel")
      seat_with_unread!(chan, viewer, 2)

      assert Tenancy.visibility(viewer) == :none

      counts = Chat.unread_counts_for_user(viewer.id)
      assert Map.get(counts, chan.id) == 2

      # THE REPORTED DEFECT, as one line: these two returned 2 and 0.
      assert Chat.total_unread_for_viewer(viewer) == counts |> Map.values() |> Enum.sum()
      assert Chat.total_unread_for_viewer(viewer) == 2

      # POSITIVE CONTROL, same test body. A `total_unread_for_viewer/1` that
      # had dropped the membership predicate along with the fence passes every
      # line above and fails this one.
      assert Chat.total_unread_for_viewer(create_user!()) == 0
    end

    test "a viewer of one org participating in another org's channel is counted" do
      # A `:none`-only test can be made green by special-casing `:none` inside
      # `Tenancy.scope/3` while leaving the fence intact for every other
      # visibility. This is the test that reds on that quiet re-fence.
      home = Tenancy.get_org_by_slug!("sxi")
      foreign = Tenancy.get_org_by_slug!("soylent")

      viewer = create_user!()
      member!(viewer, home)

      assert {:orgs, org_ids} = Tenancy.visibility(viewer)
      refute foreign.id in org_ids

      foreign_chan = space_of_kind("channel", %{org_id: foreign.id})
      seat_with_unread!(foreign_chan, viewer, 3)

      assert Map.get(Chat.unread_counts_for_user(viewer.id), foreign_chan.id) == 3
      assert foreign_chan.id in Chat.list_member_space_ids(viewer.id)
      assert Chat.total_unread_for_viewer(viewer) == 3

      # The other half of the same fact, and the reason this is safe: the
      # org-fenced query still excludes the space, so nothing that reads it
      # gained a row.
      refute foreign_chan.id in Chat.list_viewer_presence_space_ids(viewer)
    end

    test "the exact member set, and the counted set as a subset of it" do
      viewer = create_user!()

      chan = space_of_kind("channel")
      meeting = space_of_kind("meeting")
      archived = space_of_kind("channel")

      seat_with_unread!(chan, viewer, 2)
      seat_with_unread!(meeting, viewer, 3)
      seat_with_unread!(archived, viewer, 4)
      {:ok, _} = Chat.archive_space(archived)

      assert Tenancy.visibility(viewer) == :none

      members = Chat.list_member_space_ids(viewer.id)

      # EXACT, not a membership check. An over-widened base query, a lost
      # `participant_id` predicate say, passes every `in` assertion there is.
      assert Enum.sort(members) == Enum.sort([chan.id, meeting.id])
      assert Chat.total_unread_for_viewer(viewer) == 2

      # "The counted set", OBSERVED rather than assumed. The dismiss clears
      # exactly the rows the badge counts (both read
      # `countable_participant_rows/1`), so the spaces whose unread disappears
      # are that set made visible without reaching into a private function.
      before = Chat.unread_counts_for_user(viewer.id)
      {:ok, _} = Chat.mark_all_chat_spaces_read(viewer)
      counted = Map.keys(before) -- Map.keys(Chat.unread_counts_for_user(viewer.id))

      assert counted == [chan.id]

      # Containment, asserted rather than assumed. A counted space the shell
      # does not subscribe freezes the badge at a number no broadcast moves.
      assert MapSet.subset?(MapSet.new(counted), MapSet.new(members))

      # The two absences, each with its positive control on the line above.
      refute meeting.id in counted
      refute archived.id in counted
    end

    test "a zero-org viewer's meeting space is neither counted nor cleared, and their channel is both" do
      viewer = create_user!()
      assert Tenancy.visibility(viewer) == :none

      chan = space_of_kind("channel")
      meeting = space_of_kind("meeting")

      chan_seat = seat_with_unread!(chan, viewer, 2)
      meeting_seat = seat_with_unread!(meeting, viewer, 3)

      # Both are in the shell's subscribe set. The kind allow-list belongs to
      # the count, never to the subscription: narrowing the subscribe set would
      # stop `presence_diff` reaching the shell for meeting spaces.
      members = Chat.list_member_space_ids(viewer.id)
      assert chan.id in members
      assert meeting.id in members

      assert Chat.total_unread_for_viewer(viewer) == 2

      # One cursor moved, not two. The badge and the dismiss stay in lockstep
      # at `:none` exactly as they do at `:root_all`.
      assert {:ok, 1} = Chat.mark_all_chat_spaces_read(viewer)

      assert cursor(chan_seat) == chan_seat.newest.id
      assert is_nil(cursor(meeting_seat))
      assert Map.get(Chat.unread_counts_for_user(viewer.id), meeting.id) == 3
      assert Chat.total_unread_for_viewer(viewer) == 0
    end

    test "a cross-org space in the subscribe set still withholds its people from presence" do
      # THE IDENTITY BOUNDARY. This is the test that reds when someone later
      # optimises `Chat.Presence.list_online_for_viewer/1` to reuse the set the
      # shell already subscribed instead of re-deriving its own fenced one.
      home = Tenancy.get_org_by_slug!("sxi")
      foreign = Tenancy.get_org_by_slug!("soylent")

      viewer = create_user!()
      member!(viewer, home)

      assert {:orgs, org_ids} = Tenancy.visibility(viewer)
      refute foreign.id in org_ids

      foreign_chan = space_of_kind("channel", %{org_id: foreign.id})
      add_user(foreign_chan.id, viewer.id)

      stranger = create_user!()
      add_user(foreign_chan.id, stranger.id)
      online!(foreign_chan, stranger, "Nadia Nightshift")

      # POSITIVE CONTROL, seeded before the refutes so an empty presence
      # backend cannot pass this test. A space INSIDE the fence, tracked the
      # same way.
      home_chan = space_of_kind("channel", %{org_id: home.id})
      add_user(home_chan.id, viewer.id)
      colleague = create_user!()
      add_user(home_chan.id, colleague.id)
      online!(home_chan, colleague, "Bram Bellhop")

      # The change: the shell now subscribes the cross-org space.
      assert foreign_chan.id in Chat.list_member_space_ids(viewer.id)

      assert {:ok, online} = ChatPresence.list_online_for_viewer(viewer)
      names = Enum.map(online, & &1.name)

      assert "Bram Bellhop" in names
      refute "Nadia Nightshift" in names
      refute stranger.id in Enum.map(online, & &1.user_id)
    end
  end

  # ── Helpers for the badge block ─────────────────────────────────────────────

  # Track `user` as online in `space`, the same shape
  # `test/platform/chat/presence_test.exs` uses. `participant_type: "user"` is
  # what `Chat.Presence.list_online_for_viewer/1` filters on.
  defp online!(space, user, display_name) do
    {:ok, _} =
      ChatPresence.track_in_space(self(), space.id, user.id, %{
        participant_type: "user",
        display_name: display_name
      })

    :ok
  end

  defp space_of_kind(kind, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(Map.merge(%{name: "Space #{n}", slug: "space-#{n}", kind: kind}, attrs))

    space
  end

  # Seat `viewer` on `space` and leave `count` unread messages there from
  # someone else. Returns the viewer's participant row and the newest message,
  # which is the pair `Chat.mark_space_read/2` takes.
  defp seat_with_unread!(space, viewer, count) when count > 0 do
    viewer_participant = add_user(space.id, viewer.id)
    author = add_user(space.id, create_user!().id)

    Enum.each(1..count, fn i ->
      {:ok, _msg} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "message #{i}"
        })
    end)

    # The space's tip by ID, NOT the last row inserted. `Platform.Types.UUIDv7`
    # is a 48-bit millisecond timestamp plus pure randomness, so two messages
    # written inside one millisecond are unordered relative to each other and
    # "posted last" is not "greatest id". Every consumer of this watermark
    # (`count_unread/3`, `mark_space_read/2`) compares ids, so the fixture has
    # to hand back the same message they will.
    %{participant: viewer_participant, newest: newest_top_level!(space.id)}
  end

  defp newest_top_level!(space_id) do
    Repo.one!(
      from(m in Message,
        where: m.space_id == ^space_id and is_nil(m.thread_id) and is_nil(m.deleted_at),
        order_by: [desc: m.id],
        limit: 1
      )
    )
  end

  # Let the clock leave the current millisecond, so the NEXT id generated is
  # strictly greater than every id generated before it. See the note in
  # `seat_with_unread!/3`: inside one millisecond the ordering is random.
  defp tick! do
    Process.sleep(2)
  end

  defp cursor(%{participant: %{id: participant_id}}) do
    Repo.get!(Participant, participant_id).last_read_message_id
  end

  defp post_from_author!(space, author_participant_id, attrs \\ %{}) do
    {:ok, msg} =
      Chat.post_message(
        Map.merge(
          %{
            space_id: space.id,
            participant_id: author_participant_id,
            content_type: "text",
            content: "later message"
          },
          attrs
        )
      )

    msg
  end

  defp thread_reply!(space, parent) do
    {:ok, thread} = Chat.create_thread_for_message(space.id, parent.id)

    post_from_author!(space, parent.participant_id, %{thread_id: thread.id, content: "reply"})
  end

  defp deleted_message!(space, author_participant_id) do
    post_from_author!(space, author_participant_id, %{
      content: "removed",
      deleted_at: DateTime.utc_now()
    })
  end

  defp pin_identity(user), do: %{kind: "user", id: user.email}

  # A task execution space pinned to this viewer's Chat rail. Built from the
  # schemas directly rather than through `Tasks.create_task/1`, which emits an
  # inbox item and a push for a sponsor and would drag both into an async test
  # that is about neither.
  defp pinned_task_space!(user, org) do
    n = System.unique_integer([:positive])

    {:ok, project} = Tasks.create_project(%{name: "Badge Fixture Project #{n}", org_id: org.id})

    task =
      %TaskRow{}
      |> TaskRow.changeset(%{project_id: project.id, title: "Badge Fixture Task #{n}"})
      |> Repo.insert!()

    space = space_of_kind("execution", %{metadata: %{"task_id" => task.id}})

    %ChatPin{}
    |> ChatPin.changeset(%{
      task_id: task.id,
      participant_kind: "user",
      participant_id: user.email,
      pinned_by: user.email
    })
    |> Repo.insert!()

    space
  end
end
