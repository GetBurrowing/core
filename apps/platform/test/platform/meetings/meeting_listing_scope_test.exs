defmodule Platform.Meetings.MeetingListingScopeTest do
  @moduledoc """
  Pins the viewer-scoped LISTINGS — `Meetings.list_meetings_for_user/1` and
  `Meetings.list_meetings_in_range_for_user/4` — against the unscoped pair they
  replace.

  ## Every denial here carries a positive control in the SAME test

  A listing that returns `[]` for everybody satisfies every `refute ... in ids`
  in this file vacuously. So each test that asserts a row is hidden from one
  viewer also asserts, on the same fixture and through the same function, that
  a viewer who SHOULD see that row does. When a guard stops firing, one of the
  two halves fails and says which.

  ## The external branch is keyed on INVITATION, not participation

  Revoking an invite stamps `revoked_at`; it does not delete the invitee's
  `chat_participants` row for the meeting's bound space. So a listing keyed on
  participation keeps showing a revoked invitee their old meetings forever, and
  shows nothing for an invite that was sent but never used — which is exactly
  the row an invitee needs in order to join. Two tests here pin that split in
  both directions.

  Users are seeded with `@example.com` addresses: a `@example.com` address
  would make `Tenancy.derive_role_from_email/1` return `:admin` and
  blanket-bypass the filter under test.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Invite
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp user!(opts \\ []) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: Keyword.get(opts, :email, "meeting_listing_#{n}@example.com"),
      name: Keyword.get(opts, :name, "Meeting Listing User"),
      oidc_sub: "oidc-meeting-listing-#{n}"
    })
  end

  defp member!(user, org_id, opts \\ []) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: org_id,
      role: Keyword.get(opts, :role, "member"),
      external: Keyword.get(opts, :external, false)
    })
    |> Repo.insert!()

    user
  end

  defp project!(org_id) do
    name = "Meeting Listing Project #{System.unique_integer([:positive])}"

    %Project{}
    |> Project.changeset(%{
      name: name,
      slug: name |> String.downcase() |> String.replace(" ", "-"),
      org_id: org_id
    })
    |> Repo.insert!()
  end

  defp meeting!(org_id, attrs \\ %{}) do
    project = project!(org_id)
    name = "Listing Meeting #{System.unique_integer([:positive])}"

    attrs = Map.merge(%{project_id: project.id, name: name}, attrs)

    # `Meeting.changeset/2` requires the intended-time PAIR: an end without a
    # start is rejected, and so is a start without an end.
    attrs =
      case attrs do
        %{scheduled_start_at: %DateTime{} = start} ->
          Map.put_new(attrs, :scheduled_end_at, DateTime.add(start, 1800, :second))

        _ ->
          attrs
      end

    {:ok, meeting} = Meetings.create_meeting(attrs)
    meeting
  end

  defp invite!(meeting, attrs) do
    %Invite{}
    |> Invite.changeset(
      Map.merge(%{meeting_id: meeting.id, display_name: "Listing Invitee"}, attrs)
    )
    |> Repo.insert!()
  end

  defp seat!(meeting, user) do
    {:ok, participant} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp ids_for(user), do: user |> Meetings.list_meetings_for_user() |> Enum.map(& &1.id)

  # A window far enough out that no other fixture in the suite lands in it.
  defp window do
    from = ~U[2031-03-01 00:00:00Z]
    {from, DateTime.add(from, 7 * 24 * 3600, :second)}
  end

  defp range_ids(user, from, to, opts \\ []) do
    user
    |> Meetings.list_meetings_in_range_for_user(from, to, opts)
    |> Enum.map(& &1.id)
  end

  setup do
    %{
      fabrikam: Platform.TenancyFixtures.fabrikam_org_id(),
      org_a: Platform.TenancyFixtures.tenant_org_id("soylent"),
      org_b: Platform.TenancyFixtures.tenant_org_id("wayne_tech")
    }
  end

  # ── Internal users ────────────────────────────────────────────────────────

  describe "list_meetings_for_user/1 — internal users see their own orgs" do
    test "own-org meeting is returned, other-org meeting is not", ctx do
      user = user!() |> member!(ctx.org_a)
      refute Tenancy.fabrikam_admin?(user)
      refute Tenancy.external_user?(user)

      own = meeting!(ctx.org_a)
      foreign = meeting!(ctx.org_b)

      # Anti-vacuity: the unscoped read proves BOTH rows exist in this run.
      unscoped = Meetings.list_all_meetings_unscoped() |> Enum.map(& &1.id)
      assert own.id in unscoped
      assert foreign.id in unscoped

      ids = ids_for(user)

      assert own.id in ids, "positive control: the viewer's own-org meeting must be listed"
      refute foreign.id in ids
    end

    test "a viewer with no memberships sees nothing, while an org member sees the row", ctx do
      orphan = user!(name: "Orphan Viewer")
      insider = user!() |> member!(ctx.org_a)
      assert Tenancy.visibility(orphan) == :none

      meeting = meeting!(ctx.org_a)

      assert meeting.id in ids_for(insider), "positive control"
      refute meeting.id in ids_for(orphan)
    end

    test "ordering is newest-created first, matching list_all_meetings_unscoped/0", ctx do
      user = user!() |> member!(ctx.org_a)
      first = meeting!(ctx.org_a)
      second = meeting!(ctx.org_a)

      ids = ids_for(user)
      assert first.id in ids and second.id in ids

      assert Enum.find_index(ids, &(&1 == second.id)) <
               Enum.find_index(ids, &(&1 == first.id))
    end
  end

  # ── The root bypass is ADMIN-only, as on the detail route ─────────────────

  describe "list_meetings_for_user/1 — the Fabrikam root bypass" do
    test "a Fabrikam root ADMIN sees every org's meetings", ctx do
      admin = user!(name: "Root Admin") |> member!(ctx.fabrikam, role: "admin")
      assert Tenancy.fabrikam_admin?(admin)

      a = meeting!(ctx.org_a)
      b = meeting!(ctx.org_b)

      ids = ids_for(admin)
      assert a.id in ids
      assert b.id in ids
    end

    # Mirrors `fetch_meeting_for_user/2`: the bypass predicate here is
    # `fabrikam_admin?/1`, NOT the strictly wider `root_member?/1`. Every OIDC
    # signup gets a plain root `member` row, so widening this is an access
    # change. If that decision is ever made, REWRITE this test to the chosen
    # rule rather than deleting it.
    test "a plain root member resolves :root_all but is not handed tenant meetings", ctx do
      member = user!(name: "Root Member") |> member!(ctx.fabrikam, role: "member")
      admin = user!(name: "Root Admin") |> member!(ctx.fabrikam, role: "admin")
      refute Tenancy.fabrikam_admin?(member)
      assert Tenancy.root_member?(member)
      assert Tenancy.visibility(member) == :root_all

      a = meeting!(ctx.org_a)

      assert a.id in ids_for(admin), "positive control: the admin bypass does list it"
      refute a.id in ids_for(member)
    end
  end

  # ── External users: invitation, not participation ─────────────────────────

  describe "list_meetings_for_user/1 — external users see exactly their live invites" do
    test "an invited meeting is listed and an uninvited one in the SAME org is not", ctx do
      external = user!() |> member!(ctx.org_a, external: true)
      insider = user!() |> member!(ctx.org_a)
      assert Tenancy.external_user?(external)

      invited = meeting!(ctx.org_a)
      uninvited = meeting!(ctx.org_a)
      invite!(invited, %{user_id: external.id})

      # The negative row is same-org, so it is denied by externality rather
      # than by the org filter — and the insider proves it is visible at all.
      insider_ids = ids_for(insider)
      assert invited.id in insider_ids

      assert uninvited.id in insider_ids,
             "positive control: the uninvited row exists and is visible"

      ids = ids_for(external)
      assert invited.id in ids, "positive control: the invited row is listed"
      refute uninvited.id in ids
    end

    test "a chat-space participant row with NO invite does not list the meeting", ctx do
      external = user!() |> member!(ctx.org_a, external: true)
      attended = meeting!(ctx.org_a)
      invited = meeting!(ctx.org_a)

      seat!(attended, external)
      invite!(invited, %{user_id: external.id})

      assert Repo.aggregate(Invite, :count) > 0
      # Participation is real: `fetch_meeting_for_user/2` admits this viewer to
      # the attended meeting's detail route through its space participant row.
      assert {:ok, _} = Meetings.fetch_meeting_for_user(external, attended.slug)

      ids = ids_for(external)
      assert invited.id in ids, "positive control: the invited meeting is listed"
      refute attended.id in ids, "participation is not invitation"
    end

    test "an invited meeting they never attended IS listed", ctx do
      external = user!() |> member!(ctx.org_a, external: true)
      never_attended = meeting!(ctx.org_a)
      invite!(never_attended, %{user_id: external.id})

      refute Chat.participant?(never_attended.chat_space_id, external.id),
             "fixture precondition: no participant row exists"

      assert never_attended.id in ids_for(external)
    end

    test "a REVOKED invite disappears, while a live invite in the same run remains", ctx do
      external = user!() |> member!(ctx.org_a, external: true)
      revoked_meeting = meeting!(ctx.org_a)
      live_meeting = meeting!(ctx.org_a)

      revoked = invite!(revoked_meeting, %{user_id: external.id})
      invite!(live_meeting, %{user_id: external.id})
      # Seated too: revocation does not delete the participant row, which is
      # exactly why the listing must not key on participation.
      seat!(revoked_meeting, external)

      assert revoked_meeting.id in ids_for(external),
             "positive control: it is listed BEFORE revocation"

      {:ok, _} = Meetings.revoke_invite(revoked)

      ids = ids_for(external)
      assert live_meeting.id in ids, "positive control: the live invite survives"
      refute revoked_meeting.id in ids
    end

    test "an EXPIRED invite disappears, while an unexpired one remains", ctx do
      external = user!() |> member!(ctx.org_a, external: true)
      expired_meeting = meeting!(ctx.org_a)
      future_meeting = meeting!(ctx.org_a)

      past = DateTime.utc_now() |> DateTime.add(-3600, :second)
      future = DateTime.utc_now() |> DateTime.add(3600, :second)

      expired = invite!(expired_meeting, %{user_id: external.id, expires_at: past})
      invite!(future_meeting, %{user_id: external.id, expires_at: future})

      assert %Invite{} = Repo.get(Invite, expired.id), "the expired row really is in the table"

      ids = ids_for(external)
      assert future_meeting.id in ids, "positive control: the unexpired invite is listed"
      refute expired_meeting.id in ids
    end

    # The load-bearing one. `ExternalAdmission` never backfills
    # `meeting_invites.user_id`, so a listing keyed on `user_id` alone passes
    # every other test in this file and shows a real invitee nothing.
    test "an invite with user_id: nil matches on EMAIL, case-insensitively", ctx do
      external = user!(email: "Listing.Invitee@Example.COM") |> member!(ctx.org_a, external: true)
      matched = meeting!(ctx.org_a)
      other_address = meeting!(ctx.org_a)

      invite!(matched, %{user_id: nil, email: "listing.invitee@example.com"})
      invite!(other_address, %{user_id: nil, email: "someone.else@example.com"})

      ids = ids_for(external)
      assert matched.id in ids, "the email disjunct must admit the account-less invite row"
      refute other_address.id in ids
    end

    test "an external user with no invites at all sees nothing an insider does see", ctx do
      external = user!() |> member!(ctx.org_a, external: true)
      insider = user!() |> member!(ctx.org_a)
      meeting = meeting!(ctx.org_a)

      assert meeting.id in ids_for(insider), "positive control"
      assert ids_for(external) == []
    end
  end

  # ── Totality ──────────────────────────────────────────────────────────────

  describe "list_meetings_for_user/1 — a viewer with no identity gets [], never everything" do
    test "nil, a bare map and a non-map answer [] on a NON-EMPTY fixture", ctx do
      insider = user!() |> member!(ctx.org_a)
      meeting = meeting!(ctx.org_a)

      assert meeting.id in ids_for(insider),
             "positive control: the fixture is non-empty and visible to somebody"

      assert Meetings.list_meetings_for_user(nil) == []
      assert Meetings.list_meetings_for_user(%{}) == []
      assert Meetings.list_meetings_for_user("not-a-user") == []
      assert Meetings.list_meetings_for_user(%{id: nil}) == []
    end
  end

  # ── The range variant keeps every edge of list_meetings_in_range/3 ────────

  describe "list_meetings_in_range_for_user/4" do
    test "scopes by org exactly as the index does", ctx do
      user = user!() |> member!(ctx.org_a)
      {from, to} = window()
      at = DateTime.add(from, 3600, :second)

      own = meeting!(ctx.org_a, %{scheduled_start_at: at})
      foreign = meeting!(ctx.org_b, %{scheduled_start_at: at})

      unscoped = from |> Meetings.list_meetings_in_range(to) |> Enum.map(& &1.id)
      assert own.id in unscoped
      assert foreign.id in unscoped

      ids = range_ids(user, from, to)
      assert own.id in ids, "positive control"
      refute foreign.id in ids
    end

    test "the window stays HALF-OPEN — [from, to)", ctx do
      user = user!() |> member!(ctx.org_a)
      {from, to} = window()

      on_from = meeting!(ctx.org_a, %{scheduled_start_at: from})
      on_to = meeting!(ctx.org_a, %{scheduled_start_at: to})

      ids = range_ids(user, from, to)
      assert on_from.id in ids, "the lower bound is inclusive"
      refute on_to.id in ids, "the upper bound is exclusive"
    end

    test "rows with a NULL scheduled_start_at are excluded by construction", ctx do
      user = user!() |> member!(ctx.org_a)
      {from, to} = window()

      ad_hoc = meeting!(ctx.org_a)
      scheduled = meeting!(ctx.org_a, %{scheduled_start_at: DateTime.add(from, 60, :second)})

      assert is_nil(ad_hoc.scheduled_start_at)
      assert ad_hoc.id in ids_for(user), "positive control: the index still sees it"

      ids = range_ids(user, from, to)
      assert scheduled.id in ids
      refute ad_hoc.id in ids
    end

    test "ordering is intended-time ascending", ctx do
      user = user!() |> member!(ctx.org_a)
      {from, to} = window()

      later = meeting!(ctx.org_a, %{scheduled_start_at: DateTime.add(from, 7200, :second)})
      earlier = meeting!(ctx.org_a, %{scheduled_start_at: DateTime.add(from, 60, :second)})

      ids = range_ids(user, from, to)

      assert Enum.find_index(ids, &(&1 == earlier.id)) <
               Enum.find_index(ids, &(&1 == later.id))
    end

    test ":project_id narrows within the viewer's own org", ctx do
      user = user!() |> member!(ctx.org_a)
      {from, to} = window()
      at = DateTime.add(from, 120, :second)

      wanted = meeting!(ctx.org_a, %{scheduled_start_at: at})
      other = meeting!(ctx.org_a, %{scheduled_start_at: at})

      both = range_ids(user, from, to)
      assert wanted.id in both and other.id in both

      ids = range_ids(user, from, to, project_id: wanted.project_id)
      assert wanted.id in ids, "positive control"
      refute other.id in ids
    end

    test "external users are narrowed to live invites here too", ctx do
      external = user!() |> member!(ctx.org_a, external: true)
      insider = user!() |> member!(ctx.org_a)
      {from, to} = window()
      at = DateTime.add(from, 300, :second)

      invited = meeting!(ctx.org_a, %{scheduled_start_at: at})
      uninvited = meeting!(ctx.org_a, %{scheduled_start_at: at})
      invite!(invited, %{user_id: external.id})

      insider_ids = range_ids(insider, from, to)
      assert invited.id in insider_ids and uninvited.id in insider_ids

      ids = range_ids(external, from, to)
      assert invited.id in ids, "positive control"
      refute uninvited.id in ids
    end

    test "a Fabrikam root admin spans orgs, a nil viewer gets []", ctx do
      admin = user!(name: "Root Admin") |> member!(ctx.fabrikam, role: "admin")
      {from, to} = window()
      at = DateTime.add(from, 900, :second)

      a = meeting!(ctx.org_a, %{scheduled_start_at: at})
      b = meeting!(ctx.org_b, %{scheduled_start_at: at})

      ids = range_ids(admin, from, to)
      assert a.id in ids and b.id in ids

      assert Meetings.list_meetings_in_range_for_user(nil, from, to) == []
      assert Meetings.list_meetings_in_range_for_user(%{}, from, to) == []
    end
  end
end
