defmodule Platform.RolesTest do
  @moduledoc """
  Light-touch smoke tests for the `Platform.Roles` context module (M4
  stage 3 of task 019ef65b-a361). Confirms each public function
  compiles, returns the right shape, and doesn't crash against a fresh
  DB.

  The deep behavioural coverage — multi-role resolver matrix,
  warning-on-multiple-bundles, override-wins semantics across realistic
  seed data — lands in stage 5 alongside the seed roster.
  """
  use Platform.DataCase, async: false

  doctest Platform.Roles

  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Roles
  alias Platform.Roles.ResponsibilityOverride
  alias Platform.Roles.Role
  alias Platform.Roles.RoleAssignment
  alias Platform.Roles.RoleResponsibility

  # Stage 4 added a seed migration that pre-inserts the four canonical
  # role rows + their bundles. These stage-3 context tests pre-date
  # that and exercise tight "exactly this bundle, exactly this list"
  # assertions — wipe the seeded data in the per-test sandbox
  # transaction so the behavioural contracts keep holding. Stage 4's
  # own `Platform.Roles.SeedsTest` is the place that explicitly
  # exercises the seeded shape.
  setup do
    Repo.delete_all(Role)
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  # Idempotent: stage 4's seed migration pre-inserts the four canonical
  # role rows on every fresh DB build (via Platform.Roles.Seeds), so a
  # bare insert collides on the natural-key PK. Return the existing row
  # if present, else insert.
  defp seed_role!(key) do
    case Repo.get(Role, key) do
      %Role{} = existing ->
        existing

      nil ->
        name = key |> String.replace("_", " ") |> String.capitalize()

        %Role{}
        |> Role.changeset(%{
          key: key,
          name: name,
          description: "test role #{key}",
          icon: "hero-star"
        })
        |> Repo.insert!()
    end
  end

  # Idempotent: stage 4's seed migration also pre-inserts the bundle
  # rows. Insert via on_conflict so re-pairing in tests is a no-op
  # rather than a unique-constraint crash.
  defp seed_responsibility!(role_key, responsibility_key) do
    %RoleResponsibility{}
    |> RoleResponsibility.changeset(%{
      role_key: role_key,
      responsibility_key: responsibility_key
    })
    |> Repo.insert!(
      on_conflict: :nothing,
      conflict_target: [:role_key, :responsibility_key]
    )
  end

  defp insert_agent!(overrides \\ %{}) do
    suffix = System.unique_integer([:positive])

    attrs =
      %{
        slug: "roles-test-#{suffix}",
        name: "Roles Test #{suffix}",
        status: "active",
        kind: "native",
        workspace_id: nil
      }
      |> Map.merge(overrides)

    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert!()
  end

  # ── list_roles / get_role ───────────────────────────────────────────

  describe "list_roles/0" do
    test "returns rows ordered by :key" do
      seed_role!("historian")
      seed_role!("designer")
      seed_role!("triage_officer")

      keys = Roles.list_roles() |> Enum.map(& &1.key)
      assert keys == Enum.sort(keys)
      assert "designer" in keys
      assert "historian" in keys
      assert "triage_officer" in keys
    end
  end

  describe "get_role/1 and get_role!/1" do
    test "fetch by natural key" do
      seed_role!("designer")
      assert %Role{key: "designer"} = Roles.get_role("designer")
      assert %Role{key: "designer"} = Roles.get_role!("designer")
    end

    test "get_role/1 returns nil on miss; get_role!/1 raises" do
      assert Roles.get_role("nope") == nil

      assert_raise Ecto.NoResultsError, fn ->
        Roles.get_role!("nope")
      end
    end
  end

  # ── bundle_for / responsibilities_for ───────────────────────────────

  describe "bundle_for/1" do
    test "returns the responsibility keys for a role, alphabetised" do
      seed_role!("designer")
      seed_responsibility!("designer", "brand_review")
      seed_responsibility!("designer", "asset_lookup")

      assert Roles.bundle_for("designer") == ["asset_lookup", "brand_review"]
    end

    test "unknown role returns []" do
      assert Roles.bundle_for("nope") == []
    end
  end

  describe "responsibilities_for/2" do
    test "default shape equals bundle_for/1" do
      seed_role!("designer")
      seed_responsibility!("designer", "brand_review")

      assert Roles.responsibilities_for("designer") == Roles.bundle_for("designer")
    end

    test "exclude_overridden: true subtracts overridden keys" do
      seed_role!("designer")
      seed_responsibility!("designer", "brand_review")
      seed_responsibility!("designer", "asset_lookup")

      agent = insert_agent!()
      {:ok, _} = Roles.set_override("brand_review", agent.id)

      assert Roles.responsibilities_for("designer", exclude_overridden: true) ==
               ["asset_lookup"]
    end
  end

  # ── assign_role / unassign_role / roles_for ─────────────────────────

  describe "assign_role/2 and unassign_role/1" do
    test "assigns an agent to a role, then unassigns" do
      seed_role!("designer")
      agent = insert_agent!()

      assert {:ok, %RoleAssignment{role_key: "designer", agent_id: aid}} =
               Roles.assign_role("designer", agent.id)

      assert aid == agent.id

      assert :ok = Roles.unassign_role("designer")
      refute Repo.exists?(RoleAssignment)
    end

    test "re-assigning without unassign returns a changeset error (Decision 1)" do
      seed_role!("historian")
      agent_a = insert_agent!()
      agent_b = insert_agent!()

      assert {:ok, _} = Roles.assign_role("historian", agent_a.id)

      assert {:error, %Ecto.Changeset{} = cs} =
               Roles.assign_role("historian", agent_b.id)

      assert {"role already assigned", _} = cs.errors[:role_key]
    end

    test "unassign_role/1 on an empty row is :ok (idempotent)" do
      assert :ok = Roles.unassign_role("nope")
    end
  end

  describe "roles_for/1" do
    test "returns all roles an agent holds, ordered by :key" do
      seed_role!("designer")
      seed_role!("historian")
      agent = insert_agent!()

      {:ok, _} = Roles.assign_role("designer", agent.id)
      {:ok, _} = Roles.assign_role("historian", agent.id)

      assert Roles.roles_for(agent.id) |> Enum.map(& &1.key) ==
               ["designer", "historian"]
    end

    test "returns [] for an agent that holds no roles" do
      agent = insert_agent!()
      assert Roles.roles_for(agent.id) == []
    end
  end

  # ── set_override / clear_override ───────────────────────────────────

  describe "set_override/2 and clear_override/1" do
    test "inserts then upserts (Decision 3 — at most one row per key)" do
      seed_role!("designer")
      agent_a = insert_agent!()
      agent_b = insert_agent!()

      assert {:ok, %ResponsibilityOverride{}} =
               Roles.set_override("brand_review", agent_a.id)

      assert {:ok, %ResponsibilityOverride{agent_id: bid}} =
               Roles.set_override("brand_review", agent_b.id)

      assert bid == agent_b.id

      # Still exactly one row for this responsibility_key.
      assert Repo.aggregate(
               from(o in ResponsibilityOverride, where: o.responsibility_key == "brand_review"),
               :count
             ) == 1
    end

    test "clear_override/1 deletes the row if any (idempotent)" do
      agent = insert_agent!()
      {:ok, _} = Roles.set_override("brand_review", agent.id)

      assert :ok = Roles.clear_override("brand_review")
      assert :ok = Roles.clear_override("brand_review")
      refute Repo.exists?(ResponsibilityOverride)
    end
  end

  # ── Soft-fail runtime-type gate (task 019f2566 stage 4) ─────────────
  #
  # `set_override/2` now emits telemetry when the operator pins a
  # responsibility to an agent whose runtime shape probably can't
  # fulfill it (the Dalton-shape trap). Ship signal, not rejection —
  # the write MUST still succeed so callers observe the same
  # `{:ok, %ResponsibilityOverride{}}` return.
  describe "set_override/2 — runtime-type gate telemetry" do
    setup do
      # A gated responsibility that RuntimeGate knows about.
      {:ok, resp} =
        Responsibilities.create_responsibility(%{
          key: "meetings.summarize",
          feature: "meetings",
          trigger_kind: "event_topic",
          trigger_config: %{"topic" => "meeting_ended"},
          scope: "per_meeting",
          context_provided: [],
          output_contract: %{"summary" => "string"},
          default_prompt_template: "meetings.summarize.v1",
          cost_profile: "low_freq_capable"
        })

      %{responsibility: resp}
    end

    test "soft-fails + emits telemetry when Dalton-shape agent gets pinned to meetings.summarize" do
      ref =
        :telemetry_test.attach_event_handlers(
          self(),
          [[:platform, :roles, :runtime_mismatch]]
        )

      dalton = insert_agent!(%{runtime_type: "external"})

      assert {:ok, %ResponsibilityOverride{agent_id: aid}} =
               Roles.set_override("meetings.summarize", dalton.id)

      # Behaviour unchanged: row is inserted + resolver returns it.
      assert aid == dalton.id
      assert %Agent{id: ^aid} = Roles.assignee_for("meetings.summarize")

      assert_receive {[:platform, :roles, :runtime_mismatch], ^ref, %{count: 1}, meta}
      assert meta.responsibility_key == "meetings.summarize"
      assert meta.agent_id == dalton.id
      assert meta.agent_slug == dalton.slug
      assert meta.reason == :conversational_agent_no_dispatch_handler

      :telemetry.detach(ref)
    end

    test "does NOT emit runtime_mismatch telemetry for a compatible agent" do
      ref =
        :telemetry_test.attach_event_handlers(
          self(),
          [[:platform, :roles, :runtime_mismatch]]
        )

      # Built-in shape — compatible with meetings.summarize.
      built_in = insert_agent!(%{runtime_type: "built_in"})

      assert {:ok, %ResponsibilityOverride{}} =
               Roles.set_override("meetings.summarize", built_in.id)

      refute_receive {[:platform, :roles, :runtime_mismatch], ^ref, _, _}, 50

      :telemetry.detach(ref)
    end

    test "federated conversational WITH responds_to_dispatch marker does NOT soft-fail" do
      ref =
        :telemetry_test.attach_event_handlers(
          self(),
          [[:platform, :roles, :runtime_mismatch]]
        )

      wired_dalton =
        insert_agent!(%{
          runtime_type: "external",
          metadata: %{"responds_to_dispatch" => true}
        })

      assert {:ok, %ResponsibilityOverride{}} =
               Roles.set_override("meetings.summarize", wired_dalton.id)

      refute_receive {[:platform, :roles, :runtime_mismatch], ^ref, _, _}, 50

      :telemetry.detach(ref)
    end

    test "unknown responsibility key does NOT emit runtime_mismatch telemetry" do
      ref =
        :telemetry_test.attach_event_handlers(
          self(),
          [[:platform, :roles, :runtime_mismatch]]
        )

      dalton = insert_agent!(%{runtime_type: "external"})

      # `brand_review` is not on the dispatch-gated list — no signal.
      assert {:ok, %ResponsibilityOverride{}} =
               Roles.set_override("brand_review", dalton.id)

      refute_receive {[:platform, :roles, :runtime_mismatch], ^ref, _, _}, 50

      :telemetry.detach(ref)
    end
  end

  # ── Resolver ────────────────────────────────────────────────────────

  describe "agent_id_for_role/1" do
    test "returns nil when the role is unassigned" do
      seed_role!("historian")
      # no assign_role/2 call — role exists, nobody holds it
      assert Roles.agent_id_for_role("historian") == nil
    end

    test "returns the pinned agent id when a role is assigned" do
      seed_role!("historian")
      agent = insert_agent!()
      {:ok, _} = Roles.assign_role("historian", agent.id)

      assert Roles.agent_id_for_role("historian") == agent.id
    end

    test "returns nil for an unknown role key without raising" do
      # Never seeded, never assigned. Chat.create_space's caller relies on
      # this returning nil (silent skip) rather than raising, so a bogus
      # role_key in a hot path degrades to a no-op instead of a 500.
      assert Roles.agent_id_for_role("librarian") == nil
    end

    test "returns the id (binary), not a preloaded agent struct" do
      seed_role!("historian")
      agent = insert_agent!()
      {:ok, _} = Roles.assign_role("historian", agent.id)

      result = Roles.agent_id_for_role("historian")
      assert is_binary(result)
      refute match?(%Agent{}, result)
    end

    test "reflects the swap after unassign + re-assign" do
      seed_role!("historian")
      first = insert_agent!()
      second = insert_agent!()

      {:ok, _} = Roles.assign_role("historian", first.id)
      assert Roles.agent_id_for_role("historian") == first.id

      :ok = Roles.unassign_role("historian")
      assert Roles.agent_id_for_role("historian") == nil

      {:ok, _} = Roles.assign_role("historian", second.id)
      assert Roles.agent_id_for_role("historian") == second.id
    end
  end

  describe "assignee_for/1" do
    test "returns nil when nothing matches" do
      assert Roles.assignee_for("nope") == nil
    end

    test "returns the role-assigned agent for a bundled key" do
      seed_role!("designer")
      seed_responsibility!("designer", "brand_review")
      agent = insert_agent!()
      {:ok, _} = Roles.assign_role("designer", agent.id)

      assert %Agent{id: aid} = Roles.assignee_for("brand_review")
      assert aid == agent.id
    end

    test "override wins over the role assignment" do
      seed_role!("designer")
      seed_responsibility!("designer", "brand_review")
      role_agent = insert_agent!()
      override_agent = insert_agent!()

      {:ok, _} = Roles.assign_role("designer", role_agent.id)
      {:ok, _} = Roles.set_override("brand_review", override_agent.id)

      assert %Agent{id: aid} = Roles.assignee_for("brand_review")
      assert aid == override_agent.id
    end

    test "returns nil when the role exists but has no assignment" do
      seed_role!("designer")
      seed_responsibility!("designer", "brand_review")
      # No assign_role/2 call — bundle exists, but nobody holds the role.

      assert Roles.assignee_for("brand_review") == nil
    end
  end

  describe "assigned_agents/0" do
    test "returns role_key + agent slug + name for an assigned role" do
      seed_role!("designer")
      agent = insert_agent!(%{slug: "octavius", name: "Octavius"})

      {:ok, _} = Roles.assign_role("designer", agent.id)

      assert [%{role_key: "designer", agent_slug: "octavius", agent_name: "Octavius"}] =
               Roles.assigned_agents()
    end

    test "omits a role that has no assignment" do
      seed_role!("designer")
      seed_role!("historian")
      agent = insert_agent!(%{slug: "octavius-2", name: "Octavius Two"})

      {:ok, _} = Roles.assign_role("designer", agent.id)

      assert Roles.assigned_agents() |> Enum.map(& &1.role_key) == ["designer"]
    end

    test "returns an empty list when nobody holds a role" do
      seed_role!("designer")

      assert Roles.assigned_agents() == []
    end
  end

  # ── scientist (task 01a0d415 stage 3) ───────────────────────────────

  describe "the scientist role" do
    test "roles_key_check accepts scientist and still rejects a non-roster key" do
      # `setup` emptied `roles`, so this insert exercises the CHECK itself.
      now = DateTime.utc_now()

      assert {1, _} =
               Repo.insert_all("roles", [
                 %{
                   key: "scientist",
                   name: "Scientist",
                   description: "d",
                   icon: "hero-beaker",
                   inserted_at: now,
                   updated_at: now
                 }
               ])

      # Positive control: the CHECK still closes the roster.
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.insert_all("roles", [
            %{
              key: "not_a_real_role",
              name: "X",
              description: "d",
              icon: "hero-beaker",
              inserted_at: now,
              updated_at: now
            }
          ])
        end

      assert error.postgres.constraint == "roles_key_check"
    end

    test "the seed is idempotent and bundles both experiments keys" do
      :ok = Platform.Roles.Seeds.seed_defaults()
      :ok = Platform.Roles.Seeds.seed_defaults()

      assert Repo.aggregate(from(r in Role, where: r.key == "scientist"), :count) == 1

      assert Repo.aggregate(
               from(rr in RoleResponsibility, where: rr.role_key == "scientist"),
               :count
             ) == 2

      # Stage 3's labeler plus stage 5's goal loop (task 01a0d415).
      assert Roles.bundle_for("scientist") == [
               "experiments.label_signal",
               "experiments.scientist"
             ]
    end
  end
end
