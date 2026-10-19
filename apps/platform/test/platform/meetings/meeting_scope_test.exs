defmodule Platform.Meetings.MeetingScopeTest do
  @moduledoc """
  The scoped / unscoped split on `Platform.Meetings`, pinned as a PAIR.

  `list_all_meetings_unscoped/0` returns rows from EVERY org and that is
  deliberate — it takes no viewer, and its non-UI callers have none.
  `fetch_meeting_for_user/2` is the viewer-scoped read and goes through
  `Tenancy.visibility/1` + `Tenancy.scope/3`.

  The two live in one file on purpose: the point is that they differ, so a
  later "consolidation" that quietly re-merged them would have to delete a
  test that says why.

  Users are seeded with `@example.com` addresses and an explicit
  `%OrgMembership{role: "member"}` row. A `@acme.test` address would make
  `Tenancy.derive_role_from_email/1` return `:admin` and blanket-bypass the
  very filter under test. Each negative case asserts `refute
  Tenancy.root_member?(user)` inline first: without that precondition a
  broken scope reads as correct.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Meetings
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp user!(opts \\ []) do
    Repo.insert!(%User{
      email: "meeting_scope_#{System.unique_integer([:positive])}@example.com",
      name: Keyword.get(opts, :name, "Meeting Scope User"),
      oidc_sub: "oidc-meeting-scope-#{System.unique_integer([:positive])}"
    })
  end

  defp member!(user, org_id, role \\ "member") do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
    |> Repo.insert!()

    user
  end

  defp project!(org_id) do
    name = "Meeting Scope Project #{System.unique_integer([:positive])}"

    %Project{}
    |> Project.changeset(%{
      name: name,
      slug: name |> String.downcase() |> String.replace(" ", "-"),
      org_id: org_id
    })
    |> Repo.insert!()
  end

  # A globally-unique meeting name, so `fetch_meeting_for_user/2`'s
  # slug lookup can never come back `{:error, :ambiguous}` for a reason
  # that has nothing to do with scoping.
  defp meeting!(org_id) do
    project = project!(org_id)
    name = "Scope Meeting #{System.unique_integer([:positive])}"
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})
    meeting
  end

  setup do
    %{
      acme: Platform.TenancyFixtures.acme_org_id(),
      org_a: Platform.TenancyFixtures.tenant_org_id("initech"),
      org_b: Platform.TenancyFixtures.tenant_org_id("vandelay_ind")
    }
  end

  describe "the scoped / unscoped split is deliberate" do
    test "list_all_meetings_unscoped/0 returns meetings from EVERY org", ctx do
      a = meeting!(ctx.org_a)
      b = meeting!(ctx.org_b)

      ids = Meetings.list_all_meetings_unscoped() |> Enum.map(& &1.id)

      # Deliberate: this read has no viewer argument at all, and the
      # non-UI callers of the unscoped family have no viewer to pass.
      assert a.id in ids
      assert b.id in ids
    end

    test "fetch_meeting_for_user/2 returns only the plain member's own org", ctx do
      user = user!() |> member!(ctx.org_a)
      refute Tenancy.root_admin?(user)
      refute Tenancy.root_member?(user)
      assert Tenancy.visibility(user) == {:orgs, [ctx.org_a]}

      own = meeting!(ctx.org_a)
      foreign = meeting!(ctx.org_b)

      # Anti-vacuity, in this same run: the unscoped read proves BOTH rows
      # exist, so `:not_found` below means "scoped out", not "never created".
      unscoped = Meetings.list_all_meetings_unscoped() |> Enum.map(& &1.id)
      assert own.id in unscoped
      assert foreign.id in unscoped

      assert {:ok, fetched} = Meetings.fetch_meeting_for_user(user, own.slug),
             "positive control: the viewer's own org meeting must come back"

      assert fetched.id == own.id

      assert Meetings.fetch_meeting_for_user(user, foreign.slug) == {:error, :not_found}
    end
  end

  describe "fetch_meeting_for_user/2 — the root bypass is ADMIN-only here" do
    test "an Acme root admin reaches every org's meeting", ctx do
      admin = user!(name: "Root Admin") |> member!(ctx.acme, "admin")
      assert Tenancy.root_admin?(admin)

      a = meeting!(ctx.org_a)
      b = meeting!(ctx.org_b)

      assert {:ok, %{id: id_a}} = Meetings.fetch_meeting_for_user(admin, a.slug)
      assert {:ok, %{id: id_b}} = Meetings.fetch_meeting_for_user(admin, b.slug)
      assert id_a == a.id
      assert id_b == b.id
    end

    # THIS IS A RECORD OF AN OPEN INCONSISTENCY, NOT A DESIRED CONTRACT.
    #
    # `Tenancy.visibility/1` bypasses on root membership at ANY role (Alex's
    # 2026-08-05 sub-orgs ruling), and `Tasks.list_projects_for_user/2` took
    # that wider rule. This function bypasses on root ADMIN, so the two
    # surfaces answer differently for the same viewer — the shape every OIDC
    # signup has. That is why this function is not routed through
    # `Tenancy.scope/3`: doing so would widen meeting reads to every
    # signed-up user, which is an access decision, not a refactor.
    #
    # When that decision is made, this test should be REWRITTEN to the chosen
    # rule, not deleted — whichever way it goes, one of these two lines
    # changes.
    test "a plain root member resolves :root_all but is still denied a tenant meeting", ctx do
      member = user!(name: "Root Member") |> member!(ctx.acme, "member")
      refute Tenancy.root_admin?(member)
      assert Tenancy.root_member?(member)

      a = meeting!(ctx.org_a)

      assert Tenancy.visibility(member) == :root_all,
             "the choke point would admit this viewer everywhere"

      assert Meetings.fetch_meeting_for_user(member, a.slug) == {:error, :not_found},
             "but this surface's own root_admin?/1 bypass does not"
    end
  end

  describe "fetch_meeting_for_user/2 — zero memberships fail closed" do
    test "a user with no membership rows reaches nothing from a non-empty fixture", ctx do
      user = user!(name: "Orphan Viewer")
      refute Tenancy.root_member?(user)
      assert Tenancy.visibility(user) == :none

      a = meeting!(ctx.org_a)

      unscoped = Meetings.list_all_meetings_unscoped() |> Enum.map(& &1.id)
      assert a.id in unscoped

      assert Meetings.fetch_meeting_for_user(user, a.slug) == {:error, :not_found}
    end

    test "nil and a bare map reach nothing", ctx do
      a = meeting!(ctx.org_a)

      assert Meetings.fetch_meeting_for_user(nil, a.slug) == {:error, :not_found}
      assert Meetings.fetch_meeting_for_user(%{}, a.slug) == {:error, :not_found}
    end
  end
end
