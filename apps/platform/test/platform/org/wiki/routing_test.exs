defmodule Platform.Org.Wiki.RoutingTest do
  @moduledoc """
  Tests for `Platform.Org.Wiki.Routing` (ADR-0041, T5 stage 2).

  Covers the canonical path-policy matrix from
  `docs/stack/0041-org-memory-impl/t5-design-lock.md` §2 plus the Historian
  predicate (§3) and owner-of-private check (§4).

  Owner-check tests pass the participant list explicitly via the
  `:agent_space_ids` opt so we don't need the `Repo` or sandbox here —
  Routing stays unit-testable.
  """

  use ExUnit.Case, async: true

  alias Platform.Agents.Agent
  alias Platform.Org.Wiki.Routing

  @space_id "019e0930-6a03-7900-84b0-225bbf054427"
  @project_id "019e41d9-f6e9-775c-b782-75e4d3c1e596"
  @agent_id "019e41d9-2a31-7d1f-86dc-755e6934c8af"
  @other_agent_id "019e41db-84dc-7b32-97bb-a414bad22f79"
  @today ~D[2026-05-20]

  defp historian_agent(id \\ @agent_id, extra_events \\ []),
    do: %Agent{id: id, system_events: ["historian" | extra_events]}

  defp plain_agent(id \\ @agent_id, events \\ []),
    do: %Agent{id: id, system_events: events}

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
  ## historian?/1 (§3)
  ## ─────────────────────────────────────────────────────────────────────

  describe "historian?/1" do
    test "true when agent.system_events contains \"historian\"" do
      assert Routing.historian?(historian_agent())
    end

    test "true when historian is one of several events" do
      assert Routing.historian?(historian_agent(@agent_id, ["some_future_event"]))
    end

    test "false when system_events is empty" do
      refute Routing.historian?(plain_agent())
    end

    test "false when system_events has other events but not historian" do
      # The legacy daily_summary/dreaming signals no longer confer the role.
      refute Routing.historian?(plain_agent(@agent_id, ["daily_summary", "dreaming"]))
    end

    test "false for nil agent" do
      refute Routing.historian?(nil)
    end

    test "false when system_events is not a list (defensive)" do
      refute Routing.historian?(%Agent{id: @agent_id, system_events: nil})
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
      assert :ok = Routing.gate_write(historian_agent(), "org/page/charter.md")
    end

    test "Historian can write project/<uuid>/page/..." do
      path = "project/#{@project_id}/page/decisions/0041.md"
      assert :ok = Routing.gate_write(historian_agent(), path)
    end

    test "Historian can write space/<uuid>/page/..." do
      path = "space/#{@space_id}/page/onboarding.md"
      assert :ok = Routing.gate_write(historian_agent(), path)
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
      assert {:error, err} = Routing.gate_write(historian_agent(), "random/garbage/path.md")
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
end
