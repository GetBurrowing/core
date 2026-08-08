defmodule Platform.Tasks.ProjectScopeTest do
  @moduledoc """
  Viewer scoping for `Platform.Tasks.list_projects_for_user/2` (ADR-0042).

  `list_projects_unscoped/1` is unscoped by design; every surface that renders
  project names to a user reads through `list_projects_for_user/2`
  instead. These tests pin the org-membership filter.

  Users are seeded with `@example.com` addresses and an explicit
  `%OrgMembership{role: "member"}` row. A `@example.com` address would
  make `Tenancy.derive_role_from_email/1` return `:admin` and
  blanket-bypass the very filter under test — same trap documented at
  `PlatformWeb.MeetingLiveTest`. Each negative case asserts
  `refute Tenancy.fabrikam_admin?(user)` inline first: without that
  precondition a broken scope reads as correct.
  """
  use Platform.DataCase, async: true

  alias Platform.Repo
  alias Platform.Accounts.User
  alias Platform.Tasks
  alias Platform.Tasks.Project
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp user!(opts \\ []) do
    Repo.insert!(%User{
      email: "project_scope_#{System.unique_integer([:positive])}@example.com",
      name: Keyword.get(opts, :name, "Project Scope User"),
      oidc_sub: "oidc-project-scope-#{System.unique_integer([:positive])}"
    })
  end

  defp member!(user, org_id, role \\ "member") do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
    |> Repo.insert!()

    user
  end

  defp project!(org_id, name) do
    %Project{}
    |> Project.changeset(%{
      name: name,
      slug: "#{name}-#{System.unique_integer([:positive])}" |> String.downcase(),
      org_id: org_id
    })
    |> Repo.insert!()
  end

  setup do
    %{
      fabrikam: Platform.TenancyFixtures.fabrikam_org_id(),
      org_a: Platform.TenancyFixtures.tenant_org_id("soylent"),
      org_b: Platform.TenancyFixtures.tenant_org_id("wayne_tech"),
      org_c: Platform.TenancyFixtures.tenant_org_id("sxi")
    }
  end

  describe "list_projects_for_user/2 — plain member" do
    test "does not return a foreign org's project", ctx do
      user = user!() |> member!(ctx.org_a)
      refute Tenancy.fabrikam_admin?(user)
      refute Tenancy.root_member?(user)

      foreign = project!(ctx.org_b, "Foreign Scope Project")

      names = user |> Tasks.list_projects_for_user() |> Enum.map(& &1.id)
      refute foreign.id in names
    end

    test "returns the viewer's own org project (positive control)", ctx do
      user = user!() |> member!(ctx.org_a)
      refute Tenancy.fabrikam_admin?(user)
      refute Tenancy.root_member?(user)

      own = project!(ctx.org_a, "Own Scope Project")

      ids = user |> Tasks.list_projects_for_user() |> Enum.map(& &1.id)
      assert own.id in ids
    end

    test "multi-org member sees both their orgs and not a third", ctx do
      user = user!() |> member!(ctx.org_a) |> member!(ctx.org_b)
      refute Tenancy.fabrikam_admin?(user)
      refute Tenancy.root_member?(user)

      a = project!(ctx.org_a, "Multi A Project")
      b = project!(ctx.org_b, "Multi B Project")
      c = project!(ctx.org_c, "Multi C Project")

      ids = user |> Tasks.list_projects_for_user() |> Enum.map(& &1.id)
      assert a.id in ids
      assert b.id in ids
      refute c.id in ids
    end
  end

  describe "list_projects_for_user/2 — root membership sees everything" do
    test "a Fabrikam root admin sees projects in every org", ctx do
      admin = user!(name: "Root Admin") |> member!(ctx.fabrikam, "admin")
      assert Tenancy.fabrikam_admin?(admin) == true

      a = project!(ctx.org_a, "Admin Visible A")
      b = project!(ctx.org_b, "Admin Visible B")

      ids = admin |> Tasks.list_projects_for_user() |> Enum.map(& &1.id)
      assert a.id in ids
      assert b.id in ids
    end

    # Rowan's 2026-08-05 sub-orgs ruling: sub-orgs are filtering mechanisms,
    # not walls — a root-org member sees every tenant's content regardless
    # of role. `Tenancy.visibility/1` therefore returns `:root_all` for ANY
    # root member, which is deliberately wider than the previous
    # `fabrikam_admin?/1`-only bypass. This test pins the widening on purpose.
    test "a plain root member (role: member) also sees every org", ctx do
      member = user!(name: "Root Member") |> member!(ctx.fabrikam, "member")
      refute Tenancy.fabrikam_admin?(member)
      assert Tenancy.root_member?(member)
      assert Tenancy.visibility(member) == :root_all

      a = project!(ctx.org_a, "Root Member Visible A")
      b = project!(ctx.org_b, "Root Member Visible B")

      ids = member |> Tasks.list_projects_for_user() |> Enum.map(& &1.id)
      assert a.id in ids
      assert b.id in ids
    end
  end

  describe "list_projects_for_user/2 — zero memberships fail closed" do
    test "a user with no membership rows gets [] from a non-empty fixture", ctx do
      user = user!(name: "Orphan Viewer")
      refute Tenancy.fabrikam_admin?(user)
      refute Tenancy.root_member?(user)
      assert Tenancy.visibility(user) == :none

      a = project!(ctx.org_a, "Orphan Fixture A")
      b = project!(ctx.org_b, "Orphan Fixture B")

      # Anti-vacuity: prove in this same run that the table the orphan reads
      # actually contains projects, so `[]` means "scoped out", not "empty DB".
      unscoped = Tasks.list_projects_unscoped() |> Enum.map(& &1.id)
      assert a.id in unscoped
      assert b.id in unscoped

      assert Tasks.list_projects_for_user(user) == []
    end
  end

  describe "list_projects_for_user/2 — anonymous" do
    test "nil and a bare map return []" do
      assert Tasks.list_projects_for_user(nil) == []
      assert Tasks.list_projects_for_user(%{}) == []
    end
  end

  describe "the scoped / unscoped split is deliberate" do
    test "list_projects_unscoped/1 returns projects from EVERY org", ctx do
      a = project!(ctx.org_a, "Split Unscoped A")
      b = project!(ctx.org_b, "Split Unscoped B")

      ids = Tasks.list_projects_unscoped() |> Enum.map(& &1.id)

      # Deliberate: the boot-time PubSub subscribers (MeetingNotifier,
      # MeetingHistorianHandler) have no viewer and need every project.
      assert a.id in ids
      assert b.id in ids
    end

    test "list_projects_for_user/2 returns only the member's own org", ctx do
      user = user!() |> member!(ctx.org_a)
      refute Tenancy.fabrikam_admin?(user)
      refute Tenancy.root_member?(user)

      a = project!(ctx.org_a, "Split Scoped A")
      b = project!(ctx.org_b, "Split Scoped B")

      ids = user |> Tasks.list_projects_for_user() |> Enum.map(& &1.id)

      assert a.id in ids, "positive control: the viewer's own org project must come back"
      refute b.id in ids
    end
  end

  describe "no LiveView reaches for the unscoped read" do
    @live_dir Path.join([
                Path.dirname(__ENV__.file),
                "..",
                "..",
                "..",
                "lib",
                "platform_web",
                "live"
              ])
              |> Path.expand()

    test "the scan actually reads LiveView sources (non-vacuity anchor)" do
      files = Path.wildcard(Path.join(@live_dir, "**/*.ex"))
      basenames = Enum.map(files, &Path.basename/1)

      assert length(files) > 10,
             "expected to scan many LiveView modules under #{@live_dir}, got #{length(files)}. " <>
               "If this is 0 or tiny the guard below is vacuous and can never fail."

      assert "tasks_live.ex" in basenames,
             "expected tasks_live.ex in the scanned set; the glob is not reaching the real directory"
    end

    test "no module under lib/platform_web/live calls list_projects_unscoped" do
      offenders =
        @live_dir
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.filter(&(File.read!(&1) =~ "list_projects_unscoped"))
        |> Enum.map(&Path.relative_to(&1, @live_dir))

      assert offenders == [],
             """
             These LiveViews call Tasks.list_projects_unscoped/1: #{Enum.join(offenders, ", ")}

             LiveViews render to a human viewer and must call
             Tasks.list_projects_for_user/2 — the unscoped read returns every
             project in every org and leaks foreign-org project names.

             If you genuinely need every project in a LiveView, change this
             test deliberately and say why.
             """
    end
  end

  describe "list_projects_for_user/2 — opts" do
    test ":org_id narrows further and never widens", ctx do
      user = user!() |> member!(ctx.org_a) |> member!(ctx.org_b)
      refute Tenancy.fabrikam_admin?(user)
      refute Tenancy.root_member?(user)

      a = project!(ctx.org_a, "Opt Narrow A")
      b = project!(ctx.org_b, "Opt Narrow B")

      ids = user |> Tasks.list_projects_for_user(org_id: ctx.org_a) |> Enum.map(& &1.id)
      assert a.id in ids
      refute b.id in ids

      # Never widens: an org the viewer does not belong to yields nothing.
      foreign = project!(ctx.org_c, "Opt Narrow C")
      widened = user |> Tasks.list_projects_for_user(org_id: ctx.org_c) |> Enum.map(& &1.id)
      refute foreign.id in widened
      assert widened == []
    end

    test ":preload loads the org association", ctx do
      user = user!() |> member!(ctx.org_a)
      project = project!(ctx.org_a, "Preload Scope Project")

      loaded =
        user
        |> Tasks.list_projects_for_user(preload: :org)
        |> Enum.find(&(&1.id == project.id))

      assert %Platform.Tenancy.Org{id: org_id} = loaded.org
      assert org_id == ctx.org_a
    end

    test "results stay alphabetical by name", ctx do
      user = user!() |> member!(ctx.org_a)

      project!(ctx.org_a, "Zeta Order Project")
      project!(ctx.org_a, "Alpha Order Project")
      project!(ctx.org_a, "Mid Order Project")

      names =
        user
        |> Tasks.list_projects_for_user(org_id: ctx.org_a)
        |> Enum.map(& &1.name)

      assert names == Enum.sort(names)
    end
  end
end
