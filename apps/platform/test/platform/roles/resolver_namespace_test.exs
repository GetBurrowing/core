defmodule Platform.Roles.ResolverNamespaceTest do
  @moduledoc """
  Characterisation tests pinning the TWO-RESOLVER CONTRACT in
  `Platform.Roles` (task `019fa230` stage 1).

  ## Why this file exists

  A recurring reading of `Platform.Roles` concludes that
  `agent_id_for_role/1` has a bug because — unlike `assignee_for/1` —
  it never consults `responsibility_overrides`. Every reader who
  re-derives it reaches for the same "fix": add a
  `lookup_override_agent/1` call to `agent_id_for_role/1`.

  **That fix would be dead code by construction.** The two resolvers
  take keys from two provably disjoint namespaces:

    * `agent_id_for_role/1` takes a **role_key** from the closed
      7-element roster in `Platform.Roles.Role.valid_keys/0` — all
      undotted (`historian`, `designer`, …).
    * `responsibility_overrides` is keyed on **responsibility_key**,
      and the Control Center advanced panel only ever writes keys
      drawn from `Roles.bundle_for/1`
      (`PlatformWeb.Live.ControlCenter.AgentData.responsibility_rows/0`)
      — all dotted (`design.critique`, `meetings.summarize`, …).

  No key can be handed to both functions. An override row therefore
  cannot carry a key equal to a role key, so an override lookup inside
  `agent_id_for_role/1` could never match. These are two legitimate
  accessors over two disjoint namespaces, not one broken one.

  ## Load-bearing test

  Test 1 (`"role keys and bundled responsibility keys are disjoint
  namespaces"`) is the LOAD-BEARING structural fact of this file. It is
  what makes the proposed unification provably inert, and it is what
  turns test 2 from an arbitrary observation into a contract. **Do not
  prune it as redundant** — without it, test 2 reads as a bug report
  rather than as a pinned decision.

  Tests 2 and 3 pin the two halves of the contract so both live in one
  place. Test 3 restates the assertion at
  `test/platform/roles/coverage_test.exs:300` deliberately.

  ## Scope

  This file asserts existing behaviour and changes none of it. Both
  resolvers' queries are deliberately left untouched — see the plan for
  task `019fa230`, which explicitly declines to unify them.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Roles.ResponsibilityOverride
  alias Platform.Roles.Role
  alias Platform.Roles.Seeds

  # ── Helpers ──────────────────────────────────────────────────────────

  defp insert_agent!(overrides \\ %{}) do
    suffix = System.unique_integer([:positive])

    attrs =
      %{
        slug: "resolver-ns-#{suffix}",
        name: "Resolver NS Agent #{suffix}",
        status: "active",
        kind: "native",
        workspace_id: nil
      }
      |> Map.merge(overrides)

    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert!()
  end

  # The stage-4 seed migration means every test here starts with the
  # canonical 7-role roster + bundles already in the sandbox. Same
  # convention as `Platform.Roles.CoverageTest`.

  # ── The structural fact ──────────────────────────────────────────────

  describe "namespace disjointness" do
    test "role keys and bundled responsibility keys are disjoint namespaces" do
      # LOAD-BEARING. This is the fact that makes adding an override
      # lookup to `agent_id_for_role/1` provably inert. Asserted against
      # the seed LITERAL (not the DB) so that a future bundle addition
      # colliding with a role key fails HERE — loudly, at the source of
      # the mistake — rather than silently making override lookup
      # reachable from the role-keyed resolver.
      role_keys = MapSet.new(Role.valid_keys())

      bundled_keys =
        Seeds.default_roles()
        |> Enum.flat_map(& &1.bundle)
        |> MapSet.new()

      # 7 -> 8: `agents_leader` (task 01a0b491 stage 1).
      # 8 -> 9: `scientist` (task 01a0d415 stage 3).
      assert MapSet.size(role_keys) == 9
      refute Enum.empty?(bundled_keys)

      assert MapSet.disjoint?(role_keys, bundled_keys),
             "role_key and responsibility_key namespaces overlap on " <>
               "#{inspect(MapSet.intersection(role_keys, bundled_keys) |> MapSet.to_list())}. " <>
               "This breaks the two-resolver contract: an override row could now " <>
               "carry a key equal to a role key, making `agent_id_for_role/1`'s " <>
               "deliberate override-blindness observable as a bug."

      # Second axis, same fact from the DB side: the Control Center
      # advanced panel writes overrides only for keys it renders, and it
      # renders `Roles.bundle_for/1` per role. So the set of keys the UI
      # can possibly write must also be disjoint from the role roster.
      panel_writable_keys =
        Roles.list_roles()
        |> Enum.flat_map(&Roles.bundle_for(&1.key))
        |> MapSet.new()

      refute Enum.empty?(panel_writable_keys)

      assert MapSet.disjoint?(role_keys, panel_writable_keys),
             "a key the Control Center panel can write an override for collides " <>
               "with a role key: " <>
               "#{inspect(MapSet.intersection(role_keys, panel_writable_keys) |> MapSet.to_list())}"
    end

    test "every role key is undotted and every bundled responsibility key is dotted" do
      # The disjointness above is currently guaranteed by a stronger
      # syntactic property. Pinning the shape separately means a future
      # collision is diagnosed ("someone added a dotted role key") rather
      # than merely detected.
      for role_key <- Role.valid_keys() do
        refute String.contains?(role_key, "."),
               "role key #{inspect(role_key)} is dotted — role keys are undotted by convention"
      end

      for %{bundle: bundle} <- Seeds.default_roles(), key <- bundle do
        assert String.contains?(key, "."),
               "bundled responsibility key #{inspect(key)} is undotted — " <>
                 "responsibility keys are dotted by convention"
      end
    end
  end

  # ── Half one: the role-keyed accessor is deliberately override-blind ──

  describe "agent_id_for_role/1 — the role-identity accessor" do
    test "ignores a responsibility override even when one is force-inserted under a role key" do
      role_agent = insert_agent!()
      override_agent = insert_agent!()

      {:ok, _} = Roles.assign_role("historian", role_agent.id)

      # Insert the override row DIRECTLY, bypassing the Control Center
      # panel — which cannot produce this row, because it only offers
      # dotted bundle keys (see the disjointness test above). The row is
      # constructed solely to demonstrate that even in the impossible
      # case, `agent_id_for_role/1` does not consult it.
      %ResponsibilityOverride{}
      |> ResponsibilityOverride.changeset(%{
        responsibility_key: "historian",
        agent_id: override_agent.id
      })
      |> Repo.insert!()

      # DELIBERATE CHARACTERISATION. `agent_id_for_role/1` is the
      # role-identity accessor: it answers "who holds this role", not
      # "who does this work". A future well-meaning unification that
      # adds `lookup_override_agent/1` here fails on this line, with the
      # disjointness test alongside it as the explanation for why the
      # unification would have been inert anyway.
      assert Roles.agent_id_for_role("historian") == role_agent.id
      refute Roles.agent_id_for_role("historian") == override_agent.id
    end

    test "returns nil for a dotted responsibility key — the namespaces do not cross" do
      agent = insert_agent!()
      {:ok, _} = Roles.assign_role("designer", agent.id)

      # `design.critique` is in the designer's bundle and the designer
      # role is held — but `agent_id_for_role/1` queries `role_assignments`
      # by role_key, and no assignment row is ever keyed on a dotted key.
      assert Roles.agent_id_for_role("design.critique") == nil
    end
  end

  # ── Half two: the responsibility-keyed accessor IS override-aware ─────

  describe "assignee_for/1 — the effective-assignee accessor" do
    test "prefers the override over the role assignment" do
      role_agent = insert_agent!()
      override_agent = insert_agent!()

      {:ok, _} = Roles.assign_role("designer", role_agent.id)
      {:ok, _} = Roles.set_override("design.critique", override_agent.id)

      # Mirrors `test/platform/roles/coverage_test.exs:300`; restated
      # here so both halves of the two-resolver contract are readable in
      # one file. This is the path that WORKS — overrides are not broken
      # in general, and `Responsibilities.Router.fire_trigger/3`
      # (`responsibilities/router.ex:836`) resolves every registered
      # responsibility through exactly this function.
      assert %Agent{id: resolved_id} = Roles.assignee_for("design.critique")
      assert resolved_id == override_agent.id
      refute resolved_id == role_agent.id
    end

    test "falls back to the role assignment when no override is set" do
      # CONTROL, not coverage. With no override row, both resolvers
      # necessarily agree on their respective keys — this fixture cannot
      # distinguish override-aware from override-blind and proves nothing
      # about the contract on its own. It is here to bound the claim
      # above: the override is what causes the divergence, not the
      # dotted/undotted key shape.
      role_agent = insert_agent!()
      {:ok, _} = Roles.assign_role("designer", role_agent.id)

      assert %Agent{id: resolved_id} = Roles.assignee_for("design.critique")
      assert resolved_id == role_agent.id
      assert Roles.agent_id_for_role("designer") == role_agent.id
    end
  end

  # ── The one genuine defect, pinned before stage 2 fixes it ────────────

  describe "historian dreaming key" do
    # GREEN AS OF STAGE 2 of task `019fa230`. `Roles.Seeds` used to
    # bundle the historian's third duty as `memory.dream_consolidation`
    # while the shipped handler registered `memory.dreaming`
    # (`lib/platform/responsibilities/handlers/dreaming.ex:96`), which
    # `lib/platform/responsibilities/providers/memory.ex:100` dispatches
    # on. The Control Center panel therefore offered a row whose
    # override was read by nothing: the operator set
    # `memory.dream_consolidation`, and `Responsibilities.Router` fired
    # `assignee_for("memory.dreaming")`.
    #
    # Stage 2 renamed the SEED (3 references) rather than the handler
    # (~10, including the `memory.dreaming.v1` prompt-template slug) and
    # shipped `20260727000000_rename_dream_consolidation_bundle_key.exs`
    # to repoint existing rows. This test guards against the seed
    # drifting away from the handler key again.
    test "the panel's historian dreaming key is the key the Router actually fires" do
      bundle = Roles.bundle_for("historian")

      assert "memory.dreaming" in bundle,
             "historian bundle #{inspect(bundle)} does not contain the key the " <>
               "registered handler (Platform.Responsibilities.Handlers.Dreaming) fires"

      refute "memory.dream_consolidation" in bundle,
             "stale seed key `memory.dream_consolidation` is still bundled — the " <>
               "panel will offer a row whose override no dispatch path reads"
    end
  end
end
