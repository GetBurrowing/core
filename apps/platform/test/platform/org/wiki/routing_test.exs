defmodule Platform.Org.Wiki.RoutingTest do
  @moduledoc """
  Tests for `Platform.Org.Wiki.Routing` (ADR-0041, T5 stage 2).

  Covers the canonical path-policy matrix from
  `docs/stack/0041-org-memory-impl/t5-design-lock.md` §2 plus the Historian
  predicate (§3) and owner-of-private check (§4).

  Owner-check tests pass the participant list explicitly via the
  `:agent_space_ids` opt so they stay unit-testable — the only tests
  that hit the DB are the `historian?/1` cases, which seed a real
  `role_assignments` row via `Platform.Roles.assign_role/2` now that
  the predicate reads from Roles rather than `agent.system_events`
  (task 019f2444 retirement).
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Org.Wiki.Routing
  alias Platform.Repo
  alias Platform.Roles

  @space_id "019e0930-6a03-7900-84b0-225bbf054427"
  @project_id "019e41d9-f6e9-775c-b782-75e4d3c1e596"
  @agent_id "019e41d9-2a31-7d1f-86dc-755e6934c8af"
  @other_agent_id "019e41db-84dc-7b32-97bb-a414bad22f79"
  @today ~D[2026-05-20]

  # ── Test-local helpers ────────────────────────────────────────────────
  #
  # `historian_agent/1` and `plain_agent/1` remain in-memory struct
  # constructors used everywhere EXCEPT the `historian?/1` describe
  # block — classify/1, gate_write/3 (page/journal/private branches),
  # gate_read/3, and owner_of?/3 don't need the DB, so they keep the
  # cheap struct fixtures.

  defp plain_agent(id \\ @agent_id), do: %Agent{id: id}

  # `insert_agent!/1` + `pin_historian!/1` build real DB rows so the
  # Roles-based `historian?/1` predicate has something to query. These
  # are used by the `historian?/1` describe block and the page-write
  # tests in `gate_write/3` that exercise the Historian branch.
  defp insert_agent!(overrides \\ %{}) do
    suffix = System.unique_integer([:positive])

    attrs =
      %{
        slug: "routing-test-#{suffix}",
        name: "Routing Test #{suffix}",
        status: "active",
        kind: "native",
        workspace_id: nil
      }
      |> Map.merge(overrides)

    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert!()
  end

  defp pin_historian!(%Agent{id: id} = agent) do
    {:ok, _} = Roles.assign_role("historian", id)
    agent
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## classify/1 — every policy branch from §2
  ## ─────────────────────────────────────────────────────────────────────

  describe "classify/1 — page paths" do
    test "org/page/<rest> classifies as :page with :historian write, :anyone read" do
      assert %{
               kind: :page,
               write_role: :historian,
               read_role: :anyone,
               namespace: "org",
               journal_date: nil
             } = Routing.classify("org/page/charter.md")
    end

    test "project/<uuid>/page/<rest> classifies as :page scoped to project namespace" do
      path = "project/#{@project_id}/page/decisions/0041.md"

      assert %{
               kind: :page,
               write_role: :historian,
               read_role: :anyone,
               namespace: "project/" <> _,
               journal_date: nil
             } = Routing.classify(path)
    end

    test "space/<uuid>/page/<rest> classifies as :page scoped to space namespace" do
      assert %{
               kind: :page,
               write_role: :historian,
               read_role: :anyone,
               namespace: "space/" <> _
             } = Routing.classify("space/#{@space_id}/page/onboarding.md")
    end

    test "project/<bad-uuid>/page/... falls through to :unknown" do
      assert %{kind: :unknown, write_role: :rejected, read_role: :rejected} =
               Routing.classify("project/not-a-uuid/page/foo.md")
    end
  end

  describe "classify/1 — journal paths" do
    test "org/journal/<date>.md classifies as :journal :anyone/:anyone with parsed date" do
      assert %{
               kind: :journal,
               write_role: :anyone,
               read_role: :anyone,
               namespace: "org",
               journal_date: ~D[2026-05-20]
             } = Routing.classify("org/journal/2026-05-20.md")
    end

    test "space/<uuid>/journal/<date>.md classifies as :journal scoped to space namespace" do
      path = "space/#{@space_id}/journal/2026-05-20.md"

      assert %{
               kind: :journal,
               write_role: :anyone,
               read_role: :anyone,
               namespace: "space/" <> _,
               journal_date: ~D[2026-05-20]
             } = Routing.classify(path)
    end

    test "project/<uuid>/journal/<date>.md classifies as :journal scoped to project namespace" do
      path = "project/#{@project_id}/journal/2026-05-20.md"
      assert %{kind: :journal, journal_date: ~D[2026-05-20]} = Routing.classify(path)
    end

    test "malformed date in journal slot falls through to :unknown" do
      assert %{kind: :unknown} = Routing.classify("org/journal/not-a-date.md")
    end

    test "non-.md extension in journal slot falls through to :unknown" do
      assert %{kind: :unknown} = Routing.classify("org/journal/2026-05-20.txt")
    end
  end

  describe "classify/1 — private paths" do
    test "space/<uuid>/private/<agent_uuid>/<rest> classifies as :private :owner/:owner" do
      path = "space/#{@space_id}/private/#{@agent_id}/scratch/today.md"

      assert %{
               kind: :private,
               write_role: :owner,
               read_role: :owner,
               namespace: "space/" <> _,
               journal_date: nil
             } = Routing.classify(path)
    end

    test "private path with non-UUID agent slot falls through to :unknown" do
      path = "space/#{@space_id}/private/not-a-uuid/scratch.md"
      assert %{kind: :unknown} = Routing.classify(path)
    end

    test "private path with non-UUID space slot falls through to :unknown" do
      path = "space/not-a-uuid/private/#{@agent_id}/scratch.md"
      assert %{kind: :unknown} = Routing.classify(path)
    end

    test "private prefix without trailing segment is not a private path" do
      # No final "/<rest>" segment ⇒ doesn't match the private regex, falls through.
      path = "space/#{@space_id}/private/#{@agent_id}/"
      assert %{kind: :unknown} = Routing.classify(path)
    end
  end

  describe "classify/1 — terminal catch-all" do
    test "empty string is rejected" do
      assert %{kind: :unknown, write_role: :rejected, read_role: :rejected} =
               Routing.classify("")
    end

    test "non-string input is rejected" do
      assert %{kind: :unknown} = Routing.classify(nil)
      assert %{kind: :unknown} = Routing.classify(:atom)
    end

    test "completely unrecognised prefix is rejected" do
      assert %{kind: :unknown, write_role: :rejected, read_role: :rejected} =
               Routing.classify("random/garbage/path.md")
    end

    test "wrong infix segment ('pages' vs 'page') is rejected" do
      assert %{kind: :unknown} = Routing.classify("org/pages/foo.md")
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## historian?/1 (§3) — now Roles-backed (task 019f2444)
  ## ─────────────────────────────────────────────────────────────────────

  describe "historian?/1" do
    test "true when the agent is pinned to role_key: \"historian\"" do
      agent = insert_agent!() |> pin_historian!()
      assert Routing.historian?(agent)
    end

    test "false when no role_assignment exists for the agent" do
      agent = insert_agent!()
      refute Routing.historian?(agent)
    end

    test "false when the historian role_assignment points at a DIFFERENT agent" do
      # The retirement's exclusivity contract: Roles is source-of-truth,
      # only the pinned agent gets the role. This is the case the legacy
      # `system_events`-array signal could not enforce.
      historian = insert_agent!(%{slug: "actual-historian"}) |> pin_historian!()
      impostor = insert_agent!(%{slug: "impostor"})

      assert Routing.historian?(historian)
      refute Routing.historian?(impostor)
    end

    test "false when the historian role is unassigned entirely" do
      # No role_assignments row exists → predicate must be false even
      # for an agent whose id happens to match nothing in Roles.
      agent = insert_agent!()
      Roles.unassign_role("historian")
      refute Routing.historian?(agent)
    end

    test "false for nil agent" do
      refute Routing.historian?(nil)
    end

    test "false for an agent struct without a bound id (defensive)" do
      refute Routing.historian?(%Agent{})
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## owner_of?/3 (§4)
  ## ─────────────────────────────────────────────────────────────────────

  describe "owner_of?/3" do
    test "true when path agent_id == agent.id AND agent participates in space" do
      path = "space/#{@space_id}/private/#{@agent_id}/scratch.md"
      assert Routing.owner_of?(path, plain_agent(), agent_space_ids: [@space_id])
    end

    test "false when path agent_id differs from agent.id" do
      path = "space/#{@space_id}/private/#{@other_agent_id}/scratch.md"
      refute Routing.owner_of?(path, plain_agent(), agent_space_ids: [@space_id])
    end

    test "false when agent does not participate in the space" do
      path = "space/#{@space_id}/private/#{@agent_id}/scratch.md"
      refute Routing.owner_of?(path, plain_agent(), agent_space_ids: [])
    end

    test "false for non-private path" do
      refute Routing.owner_of?("org/page/charter.md", plain_agent(), agent_space_ids: [@space_id])
    end

    test "false for nil agent" do
      path = "space/#{@space_id}/private/#{@agent_id}/scratch.md"
      refute Routing.owner_of?(path, nil)
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## gate_write/3 — happy paths
  ## ─────────────────────────────────────────────────────────────────────

  describe "gate_write/3 — page paths" do
    test "Historian can write org/page/..." do
      historian = insert_agent!() |> pin_historian!()
      assert :ok = Routing.gate_write(historian, "org/page/charter.md")
    end

    test "Historian can write project/<uuid>/page/..." do
      historian = insert_agent!() |> pin_historian!()
      path = "project/#{@project_id}/page/decisions/0041.md"
      assert :ok = Routing.gate_write(historian, path)
    end

    test "Historian can write space/<uuid>/page/..." do
      historian = insert_agent!() |> pin_historian!()
      path = "space/#{@space_id}/page/onboarding.md"
      assert :ok = Routing.gate_write(historian, path)
    end

    test "non-Historian gets :historian_required with verbatim message and suggestion" do
      assert {:error, err} =
               Routing.gate_write(plain_agent(), "org/page/charter.md", today: @today)

      # stage 3 contract: literal "propose via journal" substring + literal
      # "memory_create at <ns>/journal/<YYYY-MM-DD>.md" suggestion. e2e
      # Case B asserts on these exact substrings — do not reshape without
      # updating memory_tools_test.exs and the e2e file in stage 6.
      assert err.code == :historian_required
      assert err.recoverable == true
      assert err.suggestion == "memory_create at org/journal/2026-05-20.md"

      assert String.contains?(err.message, "propose via journal")
      assert String.contains?(err.message, "memory_create at org/journal/2026-05-20.md")
    end

    test "non-Historian on project/<uuid>/page/... gets project-scoped journal suggestion" do
      path = "project/#{@project_id}/page/decisions/0041.md"

      assert {:error, err} = Routing.gate_write(plain_agent(), path, today: @today)
      assert err.code == :historian_required
      assert err.suggestion == "memory_create at project/#{@project_id}/journal/2026-05-20.md"
    end

    test "non-Historian on space/<uuid>/page/... gets space-scoped journal suggestion" do
      path = "space/#{@space_id}/page/onboarding.md"

      assert {:error, err} = Routing.gate_write(plain_agent(), path, today: @today)
      assert err.code == :historian_required
      assert err.suggestion == "memory_create at space/#{@space_id}/journal/2026-05-20.md"
    end

    test "non-Historian default suggestion uses today's UTC date when :today not supplied" do
      assert {:error, err} = Routing.gate_write(plain_agent(), "org/page/charter.md")
      iso_today = Date.utc_today() |> Date.to_iso8601()
      assert err.suggestion == "memory_create at org/journal/#{iso_today}.md"
    end

    test "nil agent is treated as non-Historian on page paths" do
      assert {:error, %{code: :historian_required}} =
               Routing.gate_write(nil, "org/page/charter.md")
    end
  end

  describe "gate_write/3 — journal paths" do
    test "any agent can write org/journal/<date>.md" do
      assert :ok = Routing.gate_write(plain_agent(), "org/journal/2026-05-20.md")
    end

    test "nil agent can write a journal path (append-only by design)" do
      assert :ok = Routing.gate_write(nil, "org/journal/2026-05-20.md")
    end

    test "any agent can write space/<uuid>/journal/<date>.md" do
      assert :ok = Routing.gate_write(plain_agent(), "space/#{@space_id}/journal/2026-05-20.md")
    end
  end

  describe "gate_write/3 — private paths" do
    test "owner can write space/<uuid>/private/<own-id>/..." do
      path = "space/#{@space_id}/private/#{@agent_id}/scratch.md"
      assert :ok = Routing.gate_write(plain_agent(), path, agent_space_ids: [@space_id])
    end

    test "non-owner (different agent_id in path) gets :not_owner error" do
      path = "space/#{@space_id}/private/#{@other_agent_id}/scratch.md"

      assert {:error, err} =
               Routing.gate_write(plain_agent(), path, agent_space_ids: [@space_id])

      assert err.code == :not_owner
      assert err.recoverable == true
    end

    test "non-participant agent gets :not_owner error" do
      path = "space/#{@space_id}/private/#{@agent_id}/scratch.md"

      assert {:error, %{code: :not_owner}} =
               Routing.gate_write(plain_agent(), path, agent_space_ids: [])
    end

    test "nil agent against a private path gets :not_owner error" do
      path = "space/#{@space_id}/private/#{@agent_id}/scratch.md"
      assert {:error, %{code: :not_owner}} = Routing.gate_write(nil, path)
    end
  end

  describe "gate_write/3 — rejected namespace" do
    test "unknown path returns :rejected_namespace error (not recoverable)" do
      historian = insert_agent!() |> pin_historian!()
      assert {:error, err} = Routing.gate_write(historian, "random/garbage/path.md")
      assert err.code == :rejected_namespace
      assert err.recoverable == false
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## gate_read/3
  ## ─────────────────────────────────────────────────────────────────────

  describe "gate_read/3" do
    test "anyone (including nil agent) can read page paths" do
      assert :ok = Routing.gate_read(nil, "org/page/charter.md")
      assert :ok = Routing.gate_read(plain_agent(), "org/page/charter.md")
    end

    test "anyone can read journal paths" do
      assert :ok = Routing.gate_read(nil, "org/journal/2026-05-20.md")
      assert :ok = Routing.gate_read(plain_agent(), "org/journal/2026-05-20.md")
    end

    test "private paths require ownership for reads" do
      path = "space/#{@space_id}/private/#{@agent_id}/scratch.md"

      assert :ok =
               Routing.gate_read(plain_agent(), path, agent_space_ids: [@space_id])

      assert {:error, %{code: :not_owner}} =
               Routing.gate_read(plain_agent(@other_agent_id), path, agent_space_ids: [@space_id])
    end

    test "private path read with nil agent gets :not_owner" do
      path = "space/#{@space_id}/private/#{@agent_id}/scratch.md"
      assert {:error, %{code: :not_owner}} = Routing.gate_read(nil, path)
    end

    test "unknown path read returns :rejected_namespace error" do
      assert {:error, %{code: :rejected_namespace}} =
               Routing.gate_read(plain_agent(), "random/garbage.md")
    end
  end

  # ── UUID boundary (task 019fa129 stage 4) ────────────────────────────────
  describe "UUID boundary: a 16-character segment is not a namespace uuid" do
    # Fabricated-value family. Nothing here ever RAISED — a bare
    # `Ecto.UUID.cast/1` simply accepted any 16-character `project/<id>` or
    # `space/<id>` path segment as a valid namespace uuid, and `owner_of?/2`
    # then compared the hex-encoded fabrication against a real agent id.
    # Assert the classification, not an exception.
    @slug_16 "higginshigginsxx"

    test "project/<16-char> classifies as :unknown, both roles :rejected" do
      assert %{kind: :unknown, write_role: :rejected, read_role: :rejected} =
               Routing.classify("project/#{@slug_16}/page/notes.md")
    end

    test "space/<16-char> classifies as :unknown" do
      assert %{kind: :unknown} = Routing.classify("space/#{@slug_16}/page/notes.md")
    end

    test "a private path with 16-character slots classifies as :unknown" do
      assert %{kind: :unknown} =
               Routing.classify("space/#{@slug_16}/private/#{@slug_16}/scratch.md")
    end

    test "short junk also classifies :unknown (green pre-fix — kept as contrast)" do
      # Passes against the buggy bare cast too. Kept adjacent so nobody prunes
      # the 16-character cases above believing this one covers them.
      assert %{kind: :unknown} = Routing.classify("project/higgins/page/notes.md")
    end

    test "a canonical uuid segment still classifies as a real namespace" do
      id = Ecto.UUID.generate()
      refute Routing.classify("project/#{id}/page/notes.md").kind == :unknown
    end
  end
end
