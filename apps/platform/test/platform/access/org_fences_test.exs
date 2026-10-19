defmodule Platform.Access.OrgFencesTest do
  @moduledoc """
  Task 01a1386d-cb5c stage 4, quantity 8 of the equivalence table: today's
  in-memory org fences, which `%Platform.Access.Scope{}` does NOT replace
  (`0058-rbac-v2-roles-scopes-and-agent-capping.md § Bypass surfaces`: "No
  v2 rule removes an org fence that exists today").

  Each fence is pinned to an exact answer per relevant actor, through a
  public entry point. This file references nothing from `Platform.Access`, so
  the identical file runs on the stack's base commit and on this branch; the
  two runs agreeing is the before/after proof that the fences are untouched.

  | Fence | Public entry point here |
  |---|---|
  | `EmailLive.usable_orgs/1` (mail inbox orgs) | mount `/email` with mail on, read the `:orgs` assign |
  | `ToolSurface.authorize_dm_target/2` (tenant agent DMs home-org users only) | MCP tool `dm_create` |
  | `Chat.external_dm_permitted?/3` | the public function |
  | `ExternalScope.counterpart_org_allowed?/2` | `ExternalScope.authorized_space?/2` |
  | `ToolSurface.tenant_scope_default/1` (tenant search filter) | MCP tool `memory_search` |
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.ExternalScope
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Federation.ToolSurface
  alias Platform.Org.Wiki.Journal
  alias Platform.Org.{WikiJournalEntry, WikiPage}
  alias Platform.Repo
  alias Platform.Tenancy

  setup do
    w = World.external_world()

    mixed = World.create_user!()
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: mixed.id, org_id: w.org_a.id})
    World.plain_member!(mixed, w.org_b)

    multi = World.create_user!()
    World.plain_member!(multi, w.org_a, "admin")
    World.plain_member!(multi, w.org_b)

    Map.merge(w, %{mixed: mixed, multi: multi})
  end

  describe "EmailLive usable_orgs (mail inbox orgs)" do
    setup do
      previous = Application.fetch_env(:platform, :mail_enabled)
      Application.put_env(:platform, :mail_enabled, true)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:platform, :mail_enabled, value)
          :error -> Application.delete_env(:platform, :mail_enabled)
        end
      end)
    end

    test "an internal user's mail orgs are their non-external memberships", w do
      assert email_orgs(w.multi) == Enum.sort([w.org_a.id, w.org_b.id])
      assert email_orgs(w.int) == [w.org_a.id]
    end

    test "external and mixed users never reach the page (403 at the plug)", w do
      for user <- [w.ext, w.mixed] do
        assert World.login(build_conn(), user.id) |> get("/email") |> Map.fetch!(:status) == 403
      end
    end
  end

  describe "Chat.external_dm_permitted?/3" do
    test "internal: always; external and mixed: allowlisted orgs' users only, never agents",
         w do
      agent_id = Ecto.UUID.generate()

      targets = [m: {"user", w.m.id}, n: {"user", w.n.id}, agent: {"agent", agent_id}]

      answers =
        for {row, user} <- [int: w.int, ext: w.ext, mixed: w.mixed],
            {target, {type, id}} <- targets,
            into: %{},
            do: {{row, target}, Chat.external_dm_permitted?(user.id, type, id)}

      assert answers == %{
               {:int, :m} => true,
               {:int, :n} => true,
               {:int, :agent} => true,
               {:ext, :m} => true,
               {:ext, :n} => false,
               {:ext, :agent} => false,
               # The mixed user holds no DM allowlist row of their own.
               {:mixed, :m} => false,
               {:mixed, :n} => false,
               {:mixed, :agent} => false
             }
    end
  end

  describe "ExternalScope.authorized_space?/2 (counterpart_org_allowed?)" do
    test "an external user is admitted to a DM by the counterpart's allowlisted org", w do
      dm_m = dm!([w.m])
      dm_n = dm!([w.n])

      assert ExternalScope.authorized_space?(w.ext, dm_m)
      refute ExternalScope.authorized_space?(w.ext, dm_n)
      refute ExternalScope.authorized_space?(w.mixed, dm_m)
      # Membership still admits whatever the counterpart.
      assert ExternalScope.authorized_space?(w.ext, w.a)
      refute ExternalScope.authorized_space?(w.ext, w.b)
    end
  end

  describe "ToolSurface dm_create (authorize_dm_target)" do
    test "a tenant-pinned agent reaches only users with a membership in its org", w do
      tenant = w.org_b
      assert tenant.parent_org_id
      agent = agent!(%{"org_id" => tenant.id})
      root_agent = agent!(%{})

      assert {:ok, _} = dm(agent, w.n.id)
      assert {:error, %{error: error}} = dm(agent, w.int.id)
      assert error =~ "not reachable from your org"
      # The mixed user's org-B row is internal, so the org fence admits them;
      # the external-user seam in `Chat.find_or_create_agent_dm/2` then
      # refuses. Pinned so a change to either shows here.
      mixed_result = dm(agent, w.mixed.id)
      assert {:error, _} = mixed_result
      refute inspect(mixed_result) =~ "not reachable from your org"
      assert {:ok, _} = dm(root_agent, w.int.id)
    end
  end

  describe "ToolSurface memory_search (tenant search filter)" do
    setup do
      prev = Application.get_env(:platform, :memory_service, [])
      Application.put_env(:platform, :memory_service, provider: Platform.Memory.Providers.Noop)
      on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)
      Repo.delete_all(WikiPage)
      Repo.delete_all(WikiJournalEntry)
      :ok
    end

    test "a tenant-pinned agent sees home org + root; a root agent sees every tenant", w do
      globex = w.org_a.id
      sibling = tenant_org_id("vandelay_ind")
      root = acme_org_id()

      for {org, tag} <- [{globex, "home"}, {sibling, "sibling"}, {root, "root"}] do
        {:ok, _} =
          Journal.append(
            %{content: "fence marker #{tag}-entry", date: Date.utc_today(), org_id: org},
            namespace: "org"
          )
      end

      assert search_tags(agent!(%{"org_id" => globex})) == ~w(home root)
      assert search_tags(agent!(%{})) == ~w(home root sibling)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp email_orgs(user) do
    {:ok, view, _html} = live(World.login(build_conn(), user.id), "/email")
    :sys.get_state(view.pid).socket.assigns.orgs |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp dm!(users) do
    {:ok, space} = Chat.create_space(%{kind: "dm", is_direct: true})
    for u <- users, do: World.add_user!(space.id, u.id)
    space
  end

  defp agent!(metadata) do
    n = System.unique_integer([:positive])

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "fence-#{n}",
        name: "Fence #{n}",
        status: "active",
        metadata: metadata
      })
      |> Repo.insert()

    agent
  end

  defp dm(agent, user_id) do
    ToolSurface.execute(
      "dm_create",
      %{"user_id" => user_id, "message" => "fence probe"},
      %{agent_id: agent.id}
    )
  end

  defp search_tags(agent) do
    {:ok, %{results: results}} =
      ToolSurface.execute(
        "memory_search",
        %{"query" => "fence marker", "source" => "journal"},
        %{agent_id: agent.id}
      )

    tags =
      for r <- results,
          [_, tag] <- [Regex.run(~r/fence marker (\w+)-entry/, r.content)],
          uniq: true,
          do: tag

    Enum.sort(tags)
  end
end
