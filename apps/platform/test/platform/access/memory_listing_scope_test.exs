defmodule Platform.Access.MemoryListingScopeTest do
  @moduledoc """
  Task 01a1386d-e528 stage 4: `Platform.Org.Wiki.scope_by/3` and the
  memory-feedback filter wired into the org-memory listings, so a page an
  actor is denied leaks neither its title, path, content nor count
  (`0058-rbac-v2-roles-scopes-and-agent-capping.md § Memory grants`).

  Every absence is preceded, IN THE SAME TEST AND ON THE SAME FIXTURE, by
  its positive control: the target page IS returned before the deny that
  hides it is inserted. An absence without its control is not evidence.

  The secret page carries two unique markers: `path_marker` in its path and
  `body_marker` in its title line and body. A listing must contain neither.
  `memory_view` and `org_memory_feedback_at_path` take the path as the
  caller's own argument and echo it, so for those two the body marker is
  refuted and the envelope is compared with an absent page's.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Access.{Grants, Scope}
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Federation.ToolSurface
  alias Platform.MemoryFeedback
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.{Node, NodePath, Search}
  alias Platform.Org.WikiPage
  alias Platform.Repo
  alias Platform.Tenancy

  # Semantic channel stub (the `Platform.Org.Wiki.SearchTest` pattern): the
  # configured results are returned for every query.
  defmodule StubProvider do
    @moduledoc false
    @behaviour Platform.Memory.Provider

    @impl true
    def ingest(_entries, _config), do: {:ok, 0}

    @impl true
    def search(_query, _opts, config), do: {:ok, Keyword.get(config, :search_results, [])}

    @impl true
    def delete(_ids, _config), do: {:ok, 0}

    @impl true
    def health(_config), do: :ok
  end

  setup do
    _root = acme_org_id()
    Repo.delete_all(NodePath)
    Repo.delete_all(Node)
    Repo.delete_all(WikiPage)
    noop_provider()

    n = System.unique_integer([:positive])
    path_marker = "zqxpath#{n}"
    body_marker = "ZQXBODY#{n}"
    secret = "org/page/eng/secret/#{path_marker}.md"
    sibling = "org/page/eng/sibling.md"

    {:ok, _} =
      Wiki.upsert_page(secret, %{
        content: "# #{body_marker} plan\n\nfalcon #{body_marker} launch plan"
      })

    {:ok, _} = Wiki.upsert_page(sibling, %{content: "# Sibling\n\nfalcon sibling notes"})

    %{
      secret: secret,
      sibling: sibling,
      path_marker: path_marker,
      body_marker: body_marker
    }
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp noop_provider do
    prev = Application.get_env(:platform, :memory_service, [])
    Application.put_env(:platform, :memory_service, provider: Platform.Memory.Providers.Noop)
    on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)
  end

  defp stub_provider(results) do
    prev = Application.get_env(:platform, :memory_service, [])

    Application.put_env(:platform, :memory_service,
      provider: StubProvider,
      search_results: results
    )

    on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)
  end

  defp user!(tag) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "ml-#{tag}-#{n}@example.com",
      name: "ML #{tag} #{n}",
      oidc_sub: "ml-#{tag}-#{n}"
    })
  end

  defp guest!(org) do
    u = user!("guest")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: u.id, org_id: org})
    u
  end

  defp scope(user), do: Scope.for_user(Accounts.get_user(user.id))

  defp agent!(slug_prefix, historian? \\ false) do
    n = System.unique_integer([:positive])

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{slug: "#{slug_prefix}-#{n}", name: "ML #{n}", status: "active"})
      |> Repo.insert()

    if historian?, do: {:ok, _} = Platform.Roles.assign_role("historian", agent.id)
    agent
  end

  defp runtime!(owner) do
    agent = agent!("ml-agent")
    n = System.unique_integer([:positive])

    {:ok, rt} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "ml-rt-#{n}",
        owner_user_id: owner.id,
        agent_id: agent.id,
        auth_token_hash: AgentRuntime.hash_token(AgentRuntime.generate_token()),
        status: "active",
        allowed_bundles: AgentRuntime.default_allowed_bundles()
      })
      |> Repo.insert()

    rt
  end

  defp call(rt, name, args),
    do: ToolSurface.execute(name, args, %{runtime_id: rt.runtime_id, agent_id: rt.agent_id})

  defp deny!(principal, path) do
    {:ok, grant} =
      Grants.deny(%{principal: principal, permission: "memory.read", resource: {:memory, path}})

    grant
  end

  defp allow!(principal, path) do
    {:ok, grant} =
      Grants.grant(%{principal: principal, permission: "memory.read", resource: {:memory, path}})

    grant
  end

  defp edit!(path, marker) do
    {:ok, row} =
      MemoryFeedback.record_edit(%{
        original_content: "before #{marker}",
        edited_content: "after #{marker}",
        path: path,
        namespace: "org_context"
      })

    row
  end

  defp leaks?(resp, ctx) do
    json = encode(resp)
    String.contains?(json, ctx.path_marker) or String.contains?(json, ctx.body_marker)
  end

  defp paths(rows), do: Enum.map(rows, & &1.path)

  # The tool envelope's payload as JSON (`{:ok | :error, map}` unwrapped).
  defp encode({tag, payload}) when tag in [:ok, :error], do: Jason.encode!(payload)
  defp encode(payload), do: Jason.encode!(payload)

  # ── memory_search ───────────────────────────────────────────────────────

  describe "memory_search" do
    test "a denied page hit disappears and total drops by exactly one; the sibling stays",
         ctx do
      rt = runtime!(user!("owner"))

      assert {:ok, before} = call(rt, "memory_search", %{"query" => "falcon"})
      assert ctx.secret in paths(before.results), "positive control: the secret page is a hit"
      assert ctx.sibling in paths(before.results)
      assert leaks?(before, ctx), "positive control: the markers are in the response"

      deny!(rt, ctx.secret)

      assert {:ok, after_deny} = call(rt, "memory_search", %{"query" => "falcon"})
      refute leaks?(after_deny, ctx)
      assert paths(after_deny.results) == [ctx.sibling]
      assert after_deny.total == before.total - 1
    end

    test "a semantic page hit is removed before fusion, so it is neither counted nor dropped",
         ctx do
      secret = Wiki.get_page(ctx.secret)
      sibling = Wiki.get_page(ctx.sibling)

      stub_provider([
        %{entry_id: secret.id, score: 0.9, memory_type: "page"},
        %{entry_id: sibling.id, score: 0.8, memory_type: "page"}
      ])

      u = user!("member")

      # No lexical channel matches this query, so both hits are semantic.
      query = "nothing-lexical-matches-this"

      assert {:ok, before} = Search.search(query, access_scope: scope(u))
      assert Enum.map(before.results, & &1.id) == [secret.id, sibling.id]
      assert before.match_count == 2

      deny!(u, ctx.secret)

      assert {:ok, after_deny} = Search.search(query, access_scope: scope(u))
      refute leaks?(after_deny, ctx)
      assert Enum.map(after_deny.results, & &1.id) == [sibling.id]
      assert after_deny.match_count == 1
      assert after_deny.dropped.page == 0, "the denied hit is not counted as a hydration drop"
      # Removed before ranking: the sibling now holds semantic rank 1.
      assert [%{semantic_rank: 1}] = after_deny.results
    end

    test "with no memory grant the scoped search equals the unscoped one", ctx do
      u = user!("member")
      assert {:ok, unscoped} = Search.search("falcon")
      assert {:ok, scoped} = Search.search("falcon", access_scope: scope(u))
      assert scoped == unscoped
      assert ctx.secret in paths(scoped.results)
    end
  end

  # ── memory_view ─────────────────────────────────────────────────────────

  describe "memory_view" do
    test "a denied page answers the not_found envelope of an absent page", ctx do
      rt = runtime!(user!("owner"))

      assert {:ok, %{content: content}} = call(rt, "memory_view", %{"path" => ctx.secret})
      assert content =~ ctx.body_marker, "positive control: the page is readable"

      deny!(rt, ctx.secret)

      denied = call(rt, "memory_view", %{"path" => ctx.secret})
      assert {:error, %{code: :not_found}} = denied
      refute String.contains?(encode(denied), ctx.body_marker)

      assert {:ok, %{content: sibling}} = call(rt, "memory_view", %{"path" => ctx.sibling})
      assert sibling =~ "sibling notes"

      {:ok, _} = Wiki.delete_page(ctx.secret)
      assert call(rt, "memory_view", %{"path" => ctx.secret}) == denied
    end
  end

  # ── memory feedback reads ───────────────────────────────────────────────

  describe "org_memory_recently_edited" do
    test "a denied page's edit rows disappear, including rows recorded before the deny", ctx do
      rt = runtime!(user!("owner"))
      edit!(ctx.secret, ctx.body_marker)
      edit!(ctx.sibling, "sibling-edit")

      assert {:ok, before} = call(rt, "org_memory_recently_edited", %{})
      assert ctx.secret in paths(before), "positive control"
      assert leaks?(before, ctx)

      deny!(rt, ctx.secret)

      assert {:ok, after_deny} = call(rt, "org_memory_recently_edited", %{})
      refute leaks?(after_deny, ctx)
      assert paths(after_deny) == [ctx.sibling]
    end

    test "the filter runs before the limit, so hidden rows cannot starve the result", ctx do
      rt = runtime!(user!("owner"))
      edit!(ctx.sibling, "old-sibling")
      for _ <- 1..3, do: edit!(ctx.secret, ctx.body_marker)

      assert {:ok, before} = call(rt, "org_memory_recently_edited", %{"limit" => 3})
      assert paths(before) == List.duplicate(ctx.secret, 3), "positive control"

      deny!(rt, ctx.secret)

      assert {:ok, after_deny} = call(rt, "org_memory_recently_edited", %{"limit" => 3})
      assert paths(after_deny) == [ctx.sibling]
    end
  end

  describe "org_memory_recently_deleted" do
    test "a denied page's delete row disappears after the page is deleted", ctx do
      rt = runtime!(user!("owner"))
      # The capture hook that records a delete row (`Org.Context.delete_file/2`);
      # the `memory_delete` tool's `Wiki.delete_page/2` records none.
      {:ok, _} = Platform.Org.Context.delete_file(ctx.secret)
      {:ok, _} = Platform.Org.Context.delete_file(ctx.sibling)

      assert {:ok, before} = call(rt, "org_memory_recently_deleted", %{})
      assert ctx.secret in paths(before), "positive control"
      assert leaks?(before, ctx)

      deny!(rt, ctx.secret)

      assert {:ok, after_deny} = call(rt, "org_memory_recently_deleted", %{})
      refute leaks?(after_deny, ctx)
      assert paths(after_deny) == [ctx.sibling]
    end
  end

  describe "org_memory_feedback_at_path" do
    test "a denied page's edits and deletes (its original CONTENT) disappear", ctx do
      rt = runtime!(user!("owner"))
      edit!(ctx.secret, ctx.body_marker)
      edit!(ctx.sibling, "sibling-edit")

      assert {:ok, before} = call(rt, "org_memory_feedback_at_path", %{"path" => ctx.secret})
      assert [_] = before.edits, "positive control"
      assert String.contains?(Jason.encode!(before), ctx.body_marker)

      deny!(rt, ctx.secret)

      assert {:ok, after_deny} =
               call(rt, "org_memory_feedback_at_path", %{"path" => ctx.secret})

      assert after_deny == %{path: ctx.secret, edits: [], deletes: []}
      refute String.contains?(Jason.encode!(after_deny), ctx.body_marker)

      assert {:ok, %{edits: [_]}} =
               call(rt, "org_memory_feedback_at_path", %{"path" => ctx.sibling})
    end
  end

  # ── Platform.Org.Wiki ───────────────────────────────────────────────────

  describe "Wiki.list_pages/1, get_page/2, list_pages_updated_since/2" do
    test "a member's deny hides the page from every read; the sibling stays", ctx do
      u = user!("member")
      since = DateTime.add(DateTime.utc_now(), -3600, :second)

      assert ctx.secret in paths_of(Wiki.list_pages(access_scope: scope(u))), "positive control"
      assert Wiki.get_page(ctx.secret, access_scope: scope(u))

      assert ctx.secret in paths_of(Wiki.list_pages_updated_since(since, access_scope: scope(u)))

      deny!(u, ctx.secret)
      s = scope(u)

      listed = Wiki.list_pages(access_scope: s)
      refute leaks?(Enum.map(listed, &Map.take(&1, [:file_key, :content])), ctx)
      assert ctx.sibling in paths_of(listed)
      assert Wiki.get_page(ctx.secret, access_scope: s) == nil
      assert Wiki.get_page(ctx.sibling, access_scope: s)

      updated = Wiki.list_pages_updated_since(since, access_scope: s)
      refute ctx.secret in paths_of(updated)
      assert ctx.sibling in paths_of(updated)

      # Unscoped callers are untouched.
      assert ctx.secret in paths_of(Wiki.list_pages())
    end

    test "a denied page is not reachable through an alias of its old name", ctx do
      u = user!("member")
      page = Wiki.get_page(ctx.secret)
      legacy = "LEGACY_#{ctx.path_marker}.md"

      Ecto.Adapters.SQL.query!(
        Repo,
        "INSERT INTO org_wiki_aliases (workspace_id, old_path, current_id, inserted_at) VALUES ($1, $2, $3, now())",
        [
          Ecto.UUID.dump!("00000000-0000-0000-0000-000000000000"),
          legacy,
          Ecto.UUID.dump!(page.id)
        ]
      )

      assert %WikiPage{id: id} = Wiki.get_page(legacy, access_scope: scope(u)),
             "positive control: the alias resolves"

      assert id == page.id

      deny!(u, ctx.secret)
      assert Wiki.get_page(legacy, access_scope: scope(u)) == nil
      assert Wiki.get_page(legacy), "unscoped alias lookups are untouched"
    end

    test "a guest with a subtree allow lists only that subtree", ctx do
      org = tenant_org_id("ml")
      g = guest!(org)
      {:ok, _} = Wiki.upsert_page("org/page/top.md", %{content: "top"})

      assert "org/page/top.md" in paths_of(Wiki.list_pages(access_scope: scope(g))),
             "positive control: with no memory grant a guest's listing is today's"

      allow!(g, "org/page/eng/")
      deny!(g, ctx.secret)

      assert paths_of(Wiki.list_pages(access_scope: scope(g))) == [ctx.sibling]
    end

    test "with no memory grant the scoped listing equals the unscoped one" do
      u = user!("member")
      assert Wiki.list_pages(access_scope: scope(u)) == Wiki.list_pages()
    end
  end

  defp paths_of(pages), do: Enum.map(pages, & &1.file_key)

  # ── rename continuity ───────────────────────────────────────────────────

  describe "rename continuity" do
    test "a pre-rename feedback row stays hidden after memory_rename moves the prefix" do
      rt = runtime!(user!("owner"))
      other = runtime!(user!("owner2"))
      historian = agent!("ml-historian", true)
      plan = "org/page/eng/secret/plan.md"
      {:ok, _} = Wiki.upsert_page(plan, %{content: "plan"})
      marker = "ZQXRENAME#{System.unique_integer([:positive])}"

      edit!(plan, marker <> "-early")
      edit!("org/page/eng/sibling.md", "sibling")

      assert {:ok, before} = call(rt, "org_memory_recently_edited", %{})
      assert plan in paths(before), "positive control"

      deny!(rt, plan)
      edit!(plan, marker <> "-late")

      assert {:ok, hidden} = call(rt, "org_memory_recently_edited", %{})
      refute String.contains?(Jason.encode!(hidden), marker)

      assert {:ok, _} =
               ToolSurface.execute(
                 "memory_rename",
                 %{"old_path" => "org/page/eng/", "new_path" => "org/page/engineering/"},
                 %{agent_id: historian.id}
               )

      assert Wiki.get_page("org/page/engineering/secret/plan.md")

      assert {:ok, after_rename} = call(rt, "org_memory_recently_edited", %{})
      refute String.contains?(Jason.encode!(after_rename), marker)
      assert "org/page/eng/sibling.md" in paths(after_rename)

      # Positive control after the rename: the rows exist and an actor with
      # no deny still reads both of them.
      assert {:ok, unhidden} = call(other, "org_memory_recently_edited", %{})
      assert Enum.count(unhidden, &(&1.path == plan)) == 2
    end
  end

  # ── org_list_descendants premise guard ──────────────────────────────────

  describe "org_list_descendants" do
    # Premise correction (stage 4): this tool returns tenant ORGS, never a
    # memory page, path or title, so there is nothing to filter. The guard
    # fails loudly if a future change adds page data to its entries.
    test "every entry carries exactly id, slug, name and role" do
      root = acme_org_id()
      _tenant = tenant_org_id("ml-desc")

      assert {:ok, %{descendants: entries}} =
               ToolSurface.execute("org_list_descendants", %{"org_id" => root}, %{})

      assert entries != [], "positive control: a tenant exists, so the guard is not vacuous"

      for entry <- entries do
        assert entry |> Map.keys() |> Enum.sort() == [:id, :name, :role, :slug]
      end
    end
  end

  # ── org-memory LiveView ─────────────────────────────────────────────────

  describe "OrgMemoryLive" do
    test "a member's deny drops the page from the tree and its direct URL", %{conn: conn} = ctx do
      u = user!("member")
      conn = Plug.Test.init_test_session(conn, %{"current_user_id" => u.id})
      lv_marker = "zqxlv#{System.unique_integer([:positive])}"
      lv = "org/page/eng/#{lv_marker}.md"
      {:ok, _} = Wiki.upsert_page(lv, %{content: "# LV\n\n#{ctx.body_marker} lv body"})

      # Opening the sibling expands `org/page/eng/`, so both leaves render.
      {:ok, _view, html} = live(conn, "/org_memory/" <> ctx.sibling)
      assert html =~ lv_marker, "positive control: the tree lists the page"
      {:ok, _view, html} = live(conn, "/org_memory/" <> lv)
      assert html =~ "lv body", "positive control: the direct URL renders the page"

      deny!(u, lv)

      {:ok, _view, html} = live(conn, "/org_memory/" <> ctx.sibling)
      refute html =~ lv_marker
      assert html =~ "sibling notes"

      denied = live(conn, "/org_memory/" <> lv)
      absent = live(conn, "/org_memory/org/page/eng/absent-page.md")
      assert shape(denied) == shape(absent)

      case denied do
        {:ok, _view, html} -> refute html =~ "lv body"
        _ -> :ok
      end
    end
  end

  defp shape({:error, {kind, %{to: to}}}), do: {kind, to}
  defp shape({:ok, _view, _html}), do: :mounted
end
