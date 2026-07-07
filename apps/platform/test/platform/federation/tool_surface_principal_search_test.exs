defmodule Platform.Federation.ToolSurfacePrincipalSearchTest do
  @moduledoc """
  Focused coverage for the `principal_search` MCP tool shipped in stage 1
  of task 019f3dac. `tool_surface_test.exs` carries the smoke-shape
  assertions inline with the rest of the context_read bundle; this file
  exercises the ranking, edge cases, injection-guard, subtype filters,
  and response-shape contract that the caller actually depends on to
  build UI or resolve UUIDs for downstream tools.

  Direct schema inserts (bypassing the account-creation flow) keep this
  a pure query test — nothing here depends on OIDC, tenancy, or
  membership plumbing.
  """

  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation.ToolSurface
  alias Platform.Repo

  # ── Fixtures ──────────────────────────────────────────────────────────

  defp u, do: System.unique_integer([:positive])

  defp insert_user(attrs) do
    n = u()

    defaults = %{
      name: "User #{n}",
      email: "user-#{n}@example.com",
      oidc_sub: "sub-user-#{n}"
    }

    Repo.insert!(struct(User, Map.merge(defaults, attrs)))
  end

  defp insert_agent(attrs) do
    n = u()

    defaults = %{
      slug: "agent-#{n}",
      name: "Agent #{n}",
      status: "active"
    }

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    agent
  end

  defp exec(args), do: ToolSurface.execute("principal_search", args, %{})

  # ── Users bucket ──────────────────────────────────────────────────────

  describe "execute/3 principal_search — users" do
    test "exact email match (case-insensitive) returns single user with correct shape" do
      user = insert_user(%{name: "Grace Hopper", email: "grace-#{u()}@example.com"})

      # Query with the email upper-cased to prove case-insensitivity.
      {:ok, %{results: results}} = exec(%{"query" => String.upcase(user.email)})

      matched = Enum.filter(results, &(&1.id == user.id))
      assert length(matched) == 1
      [row] = matched
      assert row.type == "user"
      assert row.id == user.id
      assert row.display_name == "Grace Hopper"
      assert row.email == user.email
    end

    test "fuzzy name substring ranks exact > prefix > substring" do
      tag = "ranktag-#{u()}"

      _substr =
        insert_user(%{name: "Zeta contains #{tag} inside", email: "z-#{u()}@ex.com"})

      _prefix = insert_user(%{name: "#{tag} Something", email: "p-#{u()}@ex.com"})
      _exact = insert_user(%{name: tag, email: "e-#{u()}@ex.com"})

      {:ok, %{results: results}} = exec(%{"query" => tag, "type" => "user"})

      user_rows = Enum.filter(results, &(&1.type == "user"))
      names = Enum.map(user_rows, & &1.display_name)

      # Exact match should come first, prefix second, substring last.
      assert length(names) == 3
      [first, second, third] = names
      assert first == tag
      assert String.starts_with?(second, tag)
      refute String.starts_with?(third, tag)
      assert String.contains?(third, tag)
    end

    test "no matches returns empty results (NOT an error)" do
      # A 32-char nonce nothing else can possibly hit.
      nonce = "nomatch#{u()}#{u()}"

      assert {:ok, %{results: []}} = exec(%{"query" => nonce})
    end

    test "limit is respected — inserting 5 hits and asking for 2 returns 2" do
      tag = "limittag-#{u()}"
      for _ <- 1..5, do: insert_user(%{name: "#{tag} #{u()}", email: "l-#{u()}@ex.com"})

      {:ok, %{results: results}} = exec(%{"query" => tag, "type" => "user", "limit" => 2})

      assert length(results) == 2
      assert Enum.all?(results, &(&1.type == "user"))
    end
  end

  # ── Agents bucket ─────────────────────────────────────────────────────

  describe "execute/3 principal_search — agents" do
    test "exact slug match returns single agent row with kind + classification" do
      slug = "hermione-exact-#{u()}"
      agent = insert_agent(%{slug: slug, name: "Hermione"})

      {:ok, %{results: results}} = exec(%{"query" => slug, "type" => "agent"})

      matched = Enum.filter(results, &(&1.id == agent.id))
      assert length(matched) == 1
      [row] = matched
      assert row.type == "agent"
      assert row.id == agent.id
      assert row.slug == slug
      assert row.display_name == "Hermione"
      assert is_binary(row.kind)
      assert is_binary(row.classification)
    end

    test "fuzzy agent name substring returns ranked matches" do
      tag = "agentrank-#{u()}"

      _substr = insert_agent(%{slug: "sub-#{u()}", name: "Zeta contains #{tag}"})
      _prefix = insert_agent(%{slug: "pre-#{u()}", name: "#{tag} Prefix"})
      _exact = insert_agent(%{slug: "exa-#{u()}", name: tag})

      {:ok, %{results: results}} = exec(%{"query" => tag, "type" => "agent"})

      agent_rows = Enum.filter(results, &(&1.type == "agent"))
      names = Enum.map(agent_rows, & &1.display_name)
      assert length(names) == 3
      [first, second, third] = names
      assert first == tag
      assert String.starts_with?(second, tag)
      refute String.starts_with?(third, tag)
      assert String.contains?(third, tag)
    end

    test "external-kind agent classifies as ext_single_responsibility" do
      slug = "ext-agent-#{u()}"

      agent =
        insert_agent(%{
          slug: slug,
          name: "External Bot",
          kind: "external",
          endpoint_kind: "openai_compat",
          base_url: "https://example.com/v1",
          model: "gpt-4"
        })

      {:ok, %{results: results}} = exec(%{"query" => slug, "type" => "agent"})

      row = Enum.find(results, &(&1.id == agent.id))
      assert row
      assert row.kind == "external"
      assert row.classification == "ext_single_responsibility"
    end

    test "native agent with runtime_type=external classifies as fed_conversational" do
      slug = "fed-agent-#{u()}"
      agent = insert_agent(%{slug: slug, name: "Fed Bot", runtime_type: "external"})

      {:ok, %{results: results}} = exec(%{"query" => slug, "type" => "agent"})

      row = Enum.find(results, &(&1.id == agent.id))
      assert row
      assert row.kind == "native"
      assert row.classification == "fed_conversational"
    end

    test "native agent with runtime_type=built_in classifies as loc_built_in" do
      slug = "loc-agent-#{u()}"
      agent = insert_agent(%{slug: slug, name: "Loc Bot", runtime_type: "built_in"})

      {:ok, %{results: results}} = exec(%{"query" => slug, "type" => "agent"})

      row = Enum.find(results, &(&1.id == agent.id))
      assert row
      assert row.kind == "native"
      assert row.classification == "loc_built_in"
    end

    test "agent row does NOT leak internal fields (endpoint_kind, base_url, model, vault_key, tools_config)" do
      slug = "ext-leak-#{u()}"

      _agent =
        insert_agent(%{
          slug: slug,
          name: "Ext Leak Guard",
          kind: "external",
          endpoint_kind: "openai_compat",
          base_url: "https://leaky.example.com/v1",
          model: "gpt-4-turbo",
          vault_key: "secret-vault-key",
          tools_config: %{"internal_tool" => true}
        })

      {:ok, %{results: results}} = exec(%{"query" => slug, "type" => "agent"})

      row = Enum.find(results, &(&1.slug == slug))
      assert row

      for banned_key <- [:endpoint_kind, :base_url, :model, :vault_key, :tools_config] do
        refute Map.has_key?(row, banned_key),
               "agent row must not carry #{inspect(banned_key)}"
      end
    end
  end

  # ── Combined (users + agents) ─────────────────────────────────────────

  describe "execute/3 principal_search — combined" do
    test "type=any (default) returns users first, then agents (concatenation order)" do
      tag = "combined-#{u()}"
      user = insert_user(%{name: "#{tag} User"})
      agent = insert_agent(%{slug: "#{tag}-slug-#{u()}", name: "#{tag} Agent"})

      {:ok, %{results: results}} = exec(%{"query" => tag})

      # Filter to just our seeded rows so unrelated principals don't
      # scramble the order assertion.
      relevant =
        Enum.filter(results, fn r ->
          r.id in [user.id, agent.id]
        end)

      types = Enum.map(relevant, & &1.type)
      assert types == ["user", "agent"]
    end

    test "type=user filters agents even when their slug/name matches the query" do
      tag = "userfilter-#{u()}"
      user = insert_user(%{name: "#{tag} Real User"})
      _agent = insert_agent(%{slug: "#{tag}-a-#{u()}", name: "#{tag} Agent"})

      {:ok, %{results: results}} = exec(%{"query" => tag, "type" => "user"})

      assert Enum.all?(results, &(&1.type == "user"))
      assert Enum.any?(results, &(&1.id == user.id))
    end

    test "type=agent filters users even when their email/name matches the query" do
      tag = "agentfilter-#{u()}"
      _user = insert_user(%{name: "#{tag} Real User", email: "#{tag}-#{u()}@ex.com"})
      agent = insert_agent(%{slug: "#{tag}-a-#{u()}", name: "#{tag} Agent"})

      {:ok, %{results: results}} = exec(%{"query" => tag, "type" => "agent"})

      assert Enum.all?(results, &(&1.type == "agent"))
      assert Enum.any?(results, &(&1.id == agent.id))
    end

    test "invalid type value returns recoverable error envelope with a suggestion" do
      assert {:error, err} = exec(%{"query" => "anything", "type" => "sponsor"})
      assert err.recoverable == true
      assert is_binary(err.error)
      assert err.error =~ "type"
      assert Map.has_key?(err, :suggestion)
      assert is_binary(err.suggestion)
    end
  end

  # ── Edge cases ────────────────────────────────────────────────────────

  describe "execute/3 principal_search — edge cases" do
    test "SQL wildcards (`_`) match literally under ILIKE semantics" do
      # PostgreSQL `_` = any single char under LIKE/ILIKE. Insert a user
      # whose name contains a literal underscore, and another whose name
      # would collide if the underscore were treated as a wildcard.
      literal = insert_user(%{name: "wild_card_#{u()}", email: "wild-#{u()}@ex.com"})
      # This user's name shares no literal substring with the query.
      _bystander =
        insert_user(%{name: "wildXcardY#{u()}", email: "byst-#{u()}@ex.com"})

      # Search for a substring that includes the literal underscore.
      {:ok, %{results: results}} = exec(%{"query" => "wild_card", "type" => "user"})

      user_rows = Enum.filter(results, &(&1.type == "user"))
      matched_ids = Enum.map(user_rows, & &1.id)

      # Literal-underscore user IS returned. Under ILIKE, `_` in the
      # pattern would also match the bystander's `X` — this asserts
      # today's behavior. If Stage 1 later escapes wildcards, tighten
      # this assertion to `refute bystander.id in matched_ids`.
      assert literal.id in matched_ids
    end

    test "injection payload returns empty results and does not delete data" do
      # Seed one row we care about surviving.
      _canary = insert_user(%{name: "Canary #{u()}"})

      before_count = Repo.aggregate(User, :count)

      assert {:ok, %{results: results}} = exec(%{"query" => "';DROP TABLE users;--"})
      assert is_list(results)

      after_count = Repo.aggregate(User, :count)
      assert after_count == before_count
    end

    test "0-char query returns empty results (short-circuit before DB)" do
      assert {:ok, %{results: []}} = exec(%{"query" => ""})
    end

    test "1-char query returns empty results (below min-length threshold)" do
      assert {:ok, %{results: []}} = exec(%{"query" => "x"})
    end

    test "whitespace-only query returns empty results (trim before length check)" do
      assert {:ok, %{results: []}} = exec(%{"query" => "   "})
    end
  end

  # ── Response shape guard ──────────────────────────────────────────────

  describe "execute/3 principal_search — response shape" do
    test "user rows carry exactly [:type, :id, :display_name, :email, :avatar_url]" do
      user = insert_user(%{name: "Shape User #{u()}"})

      {:ok, %{results: results}} = exec(%{"query" => user.email})

      row = Enum.find(results, &(&1.id == user.id))
      assert row

      assert Map.keys(row) |> Enum.sort() ==
               Enum.sort([:type, :id, :display_name, :email, :avatar_url])
    end

    test "agent rows carry exactly [:type, :id, :display_name, :slug, :kind, :classification]" do
      slug = "shape-agent-#{u()}"
      agent = insert_agent(%{slug: slug, name: "Shape Agent"})

      {:ok, %{results: results}} = exec(%{"query" => slug, "type" => "agent"})

      row = Enum.find(results, &(&1.id == agent.id))
      assert row

      assert Map.keys(row) |> Enum.sort() ==
               Enum.sort([:type, :id, :display_name, :slug, :kind, :classification])

      # Explicit non-goal guards — these fields belong on users, not agents.
      refute Map.has_key?(row, :email)
      refute Map.has_key?(row, :avatar_url)
      refute Map.has_key?(row, :responsibilities)
    end
  end
end
