defmodule Platform.Org.Wiki.ReadersTest do
  @moduledoc """
  The generic `readers:` frontmatter rule, exercised at a NON-people path so
  nothing here depends on People policy. Every restricted assertion has a
  positive control in the same test: a page without `readers:` at the same
  prefix that the same scope does see.
  """
  # async: false — search writes the global :memory_service app env.
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access.Scope
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.{Readers, Search}
  alias Platform.Org.{WikiJournalEntry, WikiPage}
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.{Org, OrgMembership}

  @open_path "org/page/fixtures/open.md"
  @restricted_path "org/page/fixtures/restricted.md"
  @admins_only_path "org/page/fixtures/admins_only.md"
  @needle "quiescent"

  setup do
    prev = Application.get_env(:platform, :memory_service, [])
    Application.put_env(:platform, :memory_service, provider: Platform.Memory.Providers.Noop)
    on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)

    Repo.delete_all(WikiPage)
    Repo.delete_all(WikiJournalEntry)

    org = Repo.get!(Org, tenant_org_id("globex"))
    admin = user!("admin", org, "admin")
    subject = user!("subject", org, "member")
    member = user!("member", org, "member")
    external = user!("external", org, "member")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: external.id, org_id: org.id})

    {:ok, open} =
      Wiki.upsert_page(@open_path, %{content: "---\ntitle: open\n---\nAn open #{@needle} page.\n"})

    {:ok, restricted} =
      Wiki.upsert_page(@restricted_path, %{
        content:
          "---\nreaders: [subject, admins]\nsubject_user_id: #{subject.id}\n---\nA restricted #{@needle} page.\n"
      })

    {:ok, admins_only} =
      Wiki.upsert_page(@admins_only_path, %{
        content: "---\nreaders: [admins]\n---\nAn admins-only #{@needle} page.\n"
      })

    %{
      org: org,
      admin: admin,
      subject: subject,
      member: member,
      external: external,
      open: open,
      restricted: restricted,
      admins_only: admins_only
    }
  end

  defp user!(label, org, role) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "readers-#{label}-#{n}@example.com",
        name: "Readers #{label} #{n}",
        oidc_sub: "readers-#{label}-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
    |> Repo.insert!()

    user
  end

  defp visible_paths(scope) do
    [access_scope: scope]
    |> Wiki.list_pages()
    |> Enum.map(& &1.file_key)
    |> Enum.filter(&String.starts_with?(&1, "org/page/fixtures/"))
    |> Enum.sort()
  end

  defp search_paths(scope) do
    {:ok, %{results: results}} =
      Search.search(@needle, source: :page, access_scope: scope, org_id: nil)

    results |> Enum.map(& &1.path) |> Enum.sort()
  end

  test "a page without readers is readable by everyone", ctx do
    for scope <- [
          Scope.for_user(ctx.admin),
          Scope.for_user(ctx.member),
          Scope.for_user(ctx.external),
          Scope.system(),
          nil
        ] do
      assert %WikiPage{file_key: @open_path} = Wiki.get_page(@open_path, access_scope: scope)
      assert @open_path in visible_paths(scope)
      assert Readers.readable?(ctx.open, scope)
    end

    refute Readers.restricted?(ctx.open)
    assert Readers.restricted?(ctx.restricted)
  end

  test "readers subject admits only the subject_user_id", ctx do
    subject_scope = Scope.for_user(ctx.subject)
    member_scope = Scope.for_user(ctx.member)

    assert %WikiPage{id: id} = Wiki.get_page(@restricted_path, access_scope: subject_scope)
    assert id == ctx.restricted.id
    assert Readers.readable?(ctx.restricted, subject_scope)

    # the subject is a plain member: `subject` does not open an admins-only page
    assert is_nil(Wiki.get_page(@admins_only_path, access_scope: subject_scope))
    refute Readers.readable?(ctx.admins_only, subject_scope)

    assert is_nil(Wiki.get_page(@restricted_path, access_scope: member_scope))
    refute Readers.readable?(ctx.restricted, member_scope)
  end

  test "readers admins admits an org admin and not a member", ctx do
    admin_scope = Scope.for_user(ctx.admin)
    member_scope = Scope.for_user(ctx.member)

    assert %WikiPage{id: id} = Wiki.get_page(@admins_only_path, access_scope: admin_scope)
    assert id == ctx.admins_only.id
    assert %WikiPage{} = Wiki.get_page(@restricted_path, access_scope: admin_scope)
    assert Readers.readable?(ctx.admins_only, admin_scope)

    assert visible_paths(admin_scope) ==
             Enum.sort([@open_path, @restricted_path, @admins_only_path])

    assert is_nil(Wiki.get_page(@admins_only_path, access_scope: member_scope))
    refute Readers.readable?(ctx.admins_only, member_scope)
  end

  test "a non-admin non-subject gets nil from get_page and no row from list_pages or search",
       ctx do
    scope = Scope.for_user(ctx.member)

    # positive controls: the same scope sees the open page through all three
    assert %WikiPage{} = Wiki.get_page(@open_path, access_scope: scope)
    assert visible_paths(scope) == [@open_path]
    assert search_paths(nil) == Enum.sort([@open_path, @restricted_path, @admins_only_path])
    assert search_paths(scope) == [@open_path]

    assert is_nil(Wiki.get_page(@restricted_path, access_scope: scope))
    assert is_nil(Wiki.get_page(@admins_only_path, access_scope: scope))
    refute @restricted_path in visible_paths(scope)
    refute @restricted_path in search_paths(scope)
  end

  test "an agent runtime scope and a nil scope read a restricted page", ctx do
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(%Agent{
        slug: "readers-agent-#{n}",
        name: "Readers Agent #{n}",
        status: "active"
      })

    runtime =
      Repo.insert!(%AgentRuntime{
        agent_id: agent.id,
        owner_user_id: ctx.admin.id,
        runtime_id: "readers-#{n}",
        status: "active"
      })

    runtime_scope = Scope.for_runtime(runtime)
    assert %Scope{actor: %AgentRuntime{}} = runtime_scope

    for scope <- [runtime_scope, nil, Scope.system()] do
      assert %WikiPage{} = Wiki.get_page(@restricted_path, access_scope: scope)
      assert %WikiPage{} = Wiki.get_page(@admins_only_path, access_scope: scope)
      assert @restricted_path in visible_paths(scope)
      assert Readers.readable?(ctx.restricted, scope)
    end

    refute Readers.applies?(runtime_scope)
    refute Readers.applies?(nil)
    assert Readers.applies?(Scope.for_user(ctx.member))
  end

  test "an external member never reads a restricted page", ctx do
    # an external user whose id IS the subject_user_id still fails the subject branch
    {:ok, _} =
      Wiki.upsert_page(@restricted_path, %{
        content:
          "---\nreaders: [subject, admins]\nsubject_user_id: #{ctx.external.id}\n---\nA restricted #{@needle} page.\n"
      })

    scope = Scope.for_user(ctx.external)

    assert %WikiPage{} = Wiki.get_page(@open_path, access_scope: scope)
    assert is_nil(Wiki.get_page(@restricted_path, access_scope: scope))
    assert is_nil(Wiki.get_page(@admins_only_path, access_scope: scope))
    assert visible_paths(scope) == [@open_path]
    refute Readers.readable?(Wiki.get_page(@restricted_path), scope)
  end
end
