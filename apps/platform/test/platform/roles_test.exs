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

  # ── Resolver ────────────────────────────────────────────────────────

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
end
