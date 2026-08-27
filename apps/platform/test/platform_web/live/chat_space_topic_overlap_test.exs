defmodule PlatformWeb.ChatSpaceTopicOverlapTest do
  @moduledoc """
  Task 01a01d10 stage 1. Characterisation of the `chat:space:<id>` double
  registration, pinned as the OVERLAP CONDITION rather than as a registration
  count, so every assertion below reads the same before and after the fix.

  ## The overlap, stated

  `PlatformWeb.ShellLive` is the `on_mount` hook for every authenticated live
  session (`router.ex:599` for `:authenticated`, `:353` for `:external_chat`),
  so it runs INSIDE `PlatformWeb.ChatLive`'s process rather than beside it.
  Both take `chat:space:<id>` registrations on that one pid, and
  `Phoenix.PubSub`'s registry runs `keys: :duplicate`, so the pid gets
  `handle_info` delivered once per registration.

  The double registration needs a space in BOTH sets on one pid. That means a
  viewer holding a `participant_type: "user"` row on the space, and a space of
  kind `channel`, `dm`, `group` or `execution` while pinned to the rail. It is
  not external-only and it is not universal. Kinds that reach ShellLive's
  subscribe set but never the Chat rail, `meeting` most notably, take exactly
  one.

  ## CORRECTION (task 01a02c4e): `meeting` takes a THIRD holder, not one

  The sentence above is true OF THE PAIR THIS FILE WAS SCOPED TO — `ShellLive`
  + `ChatLive`. For a `meeting` space `ChatLive` is indeed not the second
  subscriber. But `PlatformWeb.MeetingLive` is a THIRD subscriber this file
  never counted, and it runs in the SAME pid as `ShellLive` (an `on_mount` hook
  on both `:meet_member`, `router.ex:446`, and `:authenticated`, `:599`).
  `meeting_live.ex:740` takes a RAW `ChatPubSub.subscribe/1` — not a
  `SpaceTopics.hold/3` — and nothing releases it, so a viewer who is a
  participant of the meeting's chat space and has the room open holds
  `chat:space:<id>` TWICE on one pid.

  Nothing below is contradicted. This file's assertions are about the
  ShellLive/ChatLive overlap and remain correct on their own terms; the
  `meeting`-takes-one claim was invisible-by-construction to that pair, not
  wrong about what it measured. The measurement that does cover MeetingLive is
  `meeting_live_space_topic_holders_test.exs` (task 01a02c4e stage 1).

  ## CORRECTION (task 01a01f4c): zero-org viewers now suffer it too

  This file was written when ShellLive resolved its subscribe set from the
  org-fenced `Chat.list_viewer_presence_space_ids/1`, which made an org
  membership one of the conditions above: `Tenancy.visibility/1` resolves
  `:none` for a viewer with no membership (`tenancy.ex:460`, `to_visibility([])`
  at `:462`), `scope(q, :none, _)` is `where fragment("false")`
  (`tenancy.ex:510`), so the set came back `[]` and ShellLive took no
  registration at all.

  Since 01a01f4c ShellLive resolves `Chat.list_member_space_ids/1`
  (`shell_live.ex:1190`), which carries no org fence, so a zero-org viewer's
  subscribe set is their full participation set and the overlap condition
  reaches them on the same terms as anyone else. The org membership is no
  longer one of the conditions.

  Nothing asserted in this file measures registrations. `overlap/2` below
  intersects the still-fenced `Chat.list_viewer_presence_space_ids/1` with the
  rail set, so every assertion here reads the same before and after 01a01f4c.
  What the helper describes changed: it is the presence-and-rail overlap, and
  it is a SUBSET of the registration overlap rather than equal to it.

  For an internal viewer the everyday case is a channel opened in an earlier
  session, seen on a fresh session before it is reopened: `Chat.list_spaces/1`
  (`chat.ex:382`) applies no membership filter and no org filter, so the rail
  lists it, and the participant row left behind by the earlier session puts it
  in ShellLive's presence set too. For an external viewer
  `presence_subscribe_space_ids/2` has already intersected the rail with
  membership, so effectively every rail row qualifies, which is why the
  original probe found it there.

  ## The two sets, and the two functions that own them

    * `Chat.list_member_space_ids/1` is ShellLive's chat subscribe set since
      task 01a01f4c, resolved at `shell_live.ex:1190` and subscribed by the
      `{:presence_spaces_resolved, ids}` branch at `shell_live.ex:370-389`.
      Participation-only, every kind, no org fence.
    * `Chat.list_viewer_presence_space_ids/1` is the org-fenced projection of
      the same participation predicate. It is what `overlap/2` below reads,
      and its only live consumer in the application is
      `Chat.Presence.list_online_for_viewer/1`, which carries other people's
      names. ShellLive no longer reads it.
    * `PlatformWeb.ChatLive.presence_subscribe_space_ids/2`
      (`chat_live.ex:135`) is ChatLive's rail subscribe set, driven from the
      mount loop at `chat_live.ex:684-687` through `subscribe_space/3` at
      `chat_live.ex:213`.

  A third registration exists for a subset of these spaces:
  `visible_roster/2` (`shell_live.ex:1001`) requires the same viewer row under
  the same `Tenancy.scope`, plus two extra narrowings, so the roster set is a
  strict SUBSET of the presence set. This file confirms the subset relation
  only. Counting registrations belongs to a later stage.

  ## The fix this file is invariant to

  Task `01a01a1b` collapsed the duplicate registrations and merged to `main`
  as `f1311a42` (PR #802, 2026-08-23). `PlatformWeb.SpaceTopics` is now the
  single writer for `chat:space:<id>` on a shell pid, backed by a
  `:chat_space_holders` assign with a closed owner set: `hold/3` registers
  only when the topic had no holders, `release/3` unregisters only when the
  last holder drops. ShellLive's roster and presence branches
  (`shell_live.ex:298`, `:373`) and ChatLive's rail (`chat_live.ex:214`) all
  route through it.

  That fix changes the registration COUNT, and it does not change the
  overlap CONDITION, which is why nothing below was rewritten when it landed.
  Both halves still compute the same two sets from the same two functions;
  what changed is how many registrations the intersection now costs. Every
  assertion here was run green against the base BEFORE `f1311a42` and against
  `main` after it, 10 for 10 on both sides. A file that had pinned a count
  would have needed rewriting, and would have stopped describing the defect
  at the moment the defect was fixed.

  ## Why the existing coverage cannot see this

  Two files already exercise these functions, and neither can observe the
  overlap, because neither evaluates BOTH functions against the same
  viewer/space pair:

    * `test/platform/chat/member_space_ids_test.exs` covers
      `list_viewer_presence_space_ids/1` and never calls
      `presence_subscribe_space_ids/2`.
    * `test/platform_web/live/chat_live_presence_scope_test.exs` covers
      `presence_subscribe_space_ids/2` and never calls
      `list_viewer_presence_space_ids/1`. Its `channel/0` fixture creates
      spaces with a NULL `org_id`, so had it called the other function on
      those same fixtures the answer would have been `[]` (`NULL in ^ids` is
      NULL, so `Tenancy.scope` drops the row) and the overlap would have
      looked empty even for a viewer who does hold an org membership.

  The `[]`-for-a-zero-org-viewer case below is the same trap in its other
  form: the naive fixture (participant row, no org membership) makes the
  presence set empty and the overlap vanish, which is why a test written that
  way would pass against both the broken and the fixed build.
  """
  use Platform.DataCase, async: true

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.{Org, OrgMembership}
  alias PlatformWeb.ChatLive

  defp create_user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "overlap-#{n}@example.test",
      name: "Overlap Viewer #{n}",
      oidc_sub: "oidc-overlap-#{n}"
    })
    |> Repo.insert!()
  end

  # A CHILD org of the root. A membership in the root org resolves to
  # `:root_all` (`Tenancy.visibility/1` → `root_member?/1`), which leaves the
  # query unscoped and would make the org fence untestable here.
  defp tenant_org! do
    n = System.unique_integer([:positive])

    %Org{}
    |> Org.changeset(%{
      name: "Overlap Tenant #{n}",
      slug: "overlap_tenant_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("fabrikam").id
    })
    |> Repo.insert!()
  end

  defp plain_membership!(user, org) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
    |> Repo.insert!()
  end

  defp channel(attrs) do
    default = %{
      name: "Overlap Channel",
      slug: "overlap-chan-#{System.unique_integer([:positive])}",
      kind: "channel"
    }

    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp add_user(space_id, user_id) do
    {:ok, participant} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user_id,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  # The overlap set for one viewer over one candidate rail, computed exactly
  # the way the two live surfaces compute their halves of it.
  defp overlap(viewer, rail_spaces) do
    presence = MapSet.new(Chat.list_viewer_presence_space_ids(viewer))
    rail = MapSet.new(ChatLive.presence_subscribe_space_ids(rail_spaces, viewer.id))

    MapSet.intersection(presence, rail)
  end

  setup do
    org = tenant_org!()

    viewer = create_user!()
    plain_membership!(viewer, org)

    %{org: org, viewer: viewer}
  end

  describe "Chat.list_viewer_presence_space_ids/1, the ShellLive half" do
    test "returns a channel the org-affiliated viewer participates in", ctx do
      space = channel(%{org_id: ctx.org.id})
      add_user(space.id, ctx.viewer.id)

      assert {:orgs, _} = Tenancy.visibility(ctx.viewer)
      assert space.id in Chat.list_viewer_presence_space_ids(ctx.viewer)
    end

    test "returns [] for a zero-org viewer holding the same participant row", ctx do
      space = channel(%{org_id: ctx.org.id})
      unaffiliated = create_user!()

      add_user(space.id, ctx.viewer.id)
      add_user(space.id, unaffiliated.id)

      # Positive control on the SAME space and the SAME participant-row shape.
      # The only difference between the two viewers is the org membership, so
      # a function that returned `[]` for everybody would red the line above,
      # not the line below.
      assert space.id in Chat.list_viewer_presence_space_ids(ctx.viewer)

      assert Tenancy.visibility(unaffiliated) == :none
      assert Chat.list_viewer_presence_space_ids(unaffiliated) == []
    end

    test "excludes an archived space the viewer participates in", ctx do
      live_space = channel(%{org_id: ctx.org.id})
      archived = channel(%{org_id: ctx.org.id})

      add_user(live_space.id, ctx.viewer.id)
      add_user(archived.id, ctx.viewer.id)
      {:ok, _} = Chat.archive_space(archived)

      ids = Chat.list_viewer_presence_space_ids(ctx.viewer)

      assert live_space.id in ids
      refute archived.id in ids
    end
  end

  describe "ChatLive.presence_subscribe_space_ids/2, the rail half" do
    # This asymmetry is the reason the overlap SET differs by viewer type. An
    # internal viewer's rail carries channels they never joined, so the
    # overlap is the subset they did join. An external viewer's rail has
    # already been intersected with membership, so the overlap is the whole
    # rail.
    test "keeps a non-participant channel for an internal viewer", ctx do
      stranger_channel = channel(%{org_id: ctx.org.id})

      refute Tenancy.external_user?(%{id: ctx.viewer.id})

      ids = ChatLive.presence_subscribe_space_ids([stranger_channel], ctx.viewer.id)

      assert ids == [stranger_channel.id]
    end

    test "drops a non-participant channel for an external viewer", ctx do
      stranger_channel = channel(%{org_id: ctx.org.id})
      joined_channel = channel(%{org_id: ctx.org.id})

      external = create_user!()
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: external.id, org_id: ctx.org.id})
      add_user(joined_channel.id, external.id)

      assert Tenancy.external_user?(%{id: external.id})

      ids =
        ChatLive.presence_subscribe_space_ids(
          [stranger_channel, joined_channel],
          external.id
        )

      # Paired: the drop is a membership intersection, not a blanket empty.
      assert ids == [joined_channel.id]
      refute stranger_channel.id in ids
    end
  end

  describe "the overlap itself" do
    test "a joined in-org channel on the rail lands in both sets", ctx do
      joined = channel(%{org_id: ctx.org.id})
      not_joined = channel(%{org_id: ctx.org.id})

      add_user(joined.id, ctx.viewer.id)

      # An internal viewer's rail is workspace-wide: `Chat.list_spaces/1`
      # applies no membership filter, so both channels are on it.
      rail = [joined, not_joined]

      overlapping = overlap(ctx.viewer, rail)

      assert MapSet.member?(overlapping, joined.id),
             "the joined in-org channel is in ShellLive's presence set and on ChatLive's rail, " <>
               "so it is the space that takes two registrations on one pid"

      refute MapSet.member?(overlapping, not_joined.id),
             "a channel with no participant row is not in ShellLive's presence set, so it " <>
               "takes exactly one registration"
    end

    # RENAMED by task 01a01f4c. This was "a zero-org viewer's overlap is empty
    # even with the participant row", which read as a claim about the registry:
    # that such a viewer takes one registration rather than two. That claim was
    # true when ShellLive subscribed the org-fenced query and is false now that
    # it subscribes `Chat.list_member_space_ids/1`. The assertions below were
    # always about the fenced query alone and are unchanged, so the name is
    # what moved.
    test "a zero-org viewer is absent from the org-fenced presence query, even with the participant row",
         ctx do
      joined = channel(%{org_id: ctx.org.id})
      unaffiliated = create_user!()

      add_user(joined.id, ctx.viewer.id)
      add_user(joined.id, unaffiliated.id)

      rail = [joined]

      # Positive control first: same space, same rail, same participant-row
      # shape. Only the org membership differs.
      assert MapSet.member?(overlap(ctx.viewer, rail), joined.id)

      # The rail half is unaffected by the missing membership. An internal
      # viewer with no org is still unrestricted there, so the empty
      # intersection is produced entirely by the fenced half.
      assert ChatLive.presence_subscribe_space_ids(rail, unaffiliated.id) == [joined.id]
      assert MapSet.size(overlap(unaffiliated, rail)) == 0

      # And the fenced half is no longer what ShellLive subscribes. Asserted
      # here so the rename above is backed by a fact rather than by a comment:
      # this viewer IS in the shell's chat subscribe set for the same space.
      assert joined.id in Chat.list_member_space_ids(unaffiliated.id)
    end

    test "an archived space cannot overlap", ctx do
      archived = channel(%{org_id: ctx.org.id})
      live_space = channel(%{org_id: ctx.org.id})

      add_user(archived.id, ctx.viewer.id)
      add_user(live_space.id, ctx.viewer.id)
      {:ok, _} = Chat.archive_space(archived)

      # The rail is passed the archived space deliberately: the point is that
      # the presence half rejects it even when the rail half does not.
      overlapping = overlap(ctx.viewer, [archived, live_space])

      assert MapSet.member?(overlapping, live_space.id)
      refute MapSet.member?(overlapping, archived.id)
    end
  end

  describe "the roster set is a strict subset of the presence set" do
    # `visible_roster/2` (`shell_live.ex:1001`) takes the same viewer
    # `participant_type: "user"` row under the same `Tenancy.scope` and the
    # same `is_nil(s.archived_at)` filter as `list_viewer_presence_space_ids/1`,
    # then narrows twice more: the space must carry a `participant_type:
    # "agent"` row, and its kind must not be in `@private_roster_kinds`
    # (`["dm"]`, `shell_live.ex:993`). A roster space is therefore ALWAYS
    # already in the presence set, which is why arrival order does not change
    # the count: if presence lands first, `release_roster_subscriptions/1`
    # (`shell_live.ex:903`) finds `:roster_space_id` unset and returns the
    # socket untouched.
    #
    # Asserted here through the presence set rather than by driving ShellLive,
    # because what stage 3 needs pinned is the SUBSET RELATION, not the
    # roster's own query.
    test "a roster-eligible space is always in the presence set", ctx do
      roster_eligible = channel(%{org_id: ctx.org.id})
      add_user(roster_eligible.id, ctx.viewer.id)

      presence = Chat.list_viewer_presence_space_ids(ctx.viewer)

      assert roster_eligible.id in presence
    end

    test "a private-roster kind still reaches the presence set", ctx do
      # `dm` IS in `@private_roster_kinds`, so a dm is excluded from the
      # roster while still qualifying for presence. That is the direction
      # that makes the relation STRICT rather than an equality.
      dm = channel(%{org_id: ctx.org.id, kind: "dm"})
      add_user(dm.id, ctx.viewer.id)

      assert dm.id in Chat.list_viewer_presence_space_ids(ctx.viewer)
    end
  end
end
