defmodule Platform.Roles.RoleAssignmentTest do
  @moduledoc """
  Tests for the `Platform.Roles.RoleAssignment` schema (M4 stage 2 of
  task 019ef65b-a361). Covers changeset validation, the `role_key`
  enum guard, the unique constraint enforcing one-agent-per-role
  (Decision 1), FK cascades from both `roles.key` and `agents.id`, and
  the migration shape.
  """
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Roles.Role
  alias Platform.Roles.RoleAssignment

  # Stage 4 added a seed migration that pre-inserts the four canonical
  # role rows. These stage-2 tests pre-date that and assume a no-roles
  # starting state (FK error on missing parent, …) — wipe the seeded
  # data in the per-test sandbox transaction so the behavioural
  # contracts keep holding.
  setup do
    Repo.delete_all(Role)
    :ok
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

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

        {:ok, role} =
          %Role{}
          |> Role.changeset(%{
            key: key,
            name: name,
            description: "test role #{key}",
            icon: "hero-star"
          })
          |> Repo.insert()

        role
    end
  end

  defp insert_agent!(overrides \\ %{}) do
    suffix = System.unique_integer([:positive])

    attrs =
      %{
        slug: "native-#{suffix}",
        name: "Native #{suffix}",
        status: "active",
        kind: "native",
        workspace_id: nil
      }
      |> Map.merge(overrides)

    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert!()
  end

  describe "changeset/2" do
    test "valid attrs pass" do
      seed_role!("designer")
      agent = insert_agent!()

      cs =
        RoleAssignment.changeset(%RoleAssignment{}, %{
          role_key: "designer",
          agent_id: agent.id
        })

      assert cs.valid?, inspect(errors_on(cs))
    end

    test "missing fields are required" do
      cs = RoleAssignment.changeset(%RoleAssignment{}, %{})
      refute cs.valid?

      for field <- [:role_key, :agent_id] do
        assert Keyword.has_key?(cs.errors, field),
               "expected error on #{field}, got: #{inspect(cs.errors)}"
      end
    end

    test "rejects a role_key outside the closed enum" do
      agent = insert_agent!()

      cs =
        RoleAssignment.changeset(%RoleAssignment{}, %{
          role_key: "wizard",
          agent_id: agent.id
        })

      refute cs.valid?
      assert %{role_key: ["is invalid"]} = errors_on(cs)
    end
  end

  describe "persistence" do
    test "round-trips through the database" do
      seed_role!("designer")
      agent = insert_agent!()

      assert {:ok, inserted} =
               %RoleAssignment{}
               |> RoleAssignment.changeset(%{role_key: "designer", agent_id: agent.id})
               |> Repo.insert()

      reloaded = Repo.get!(RoleAssignment, inserted.id)
      assert reloaded.role_key == "designer"
      assert reloaded.agent_id == agent.id
    end

    test "second assignment of the same role is rejected (Decision 1)" do
      seed_role!("historian")
      agent_a = insert_agent!()
      agent_b = insert_agent!()

      assert {:ok, _} =
               %RoleAssignment{}
               |> RoleAssignment.changeset(%{role_key: "historian", agent_id: agent_a.id})
               |> Repo.insert()

      assert {:error, cs} =
               %RoleAssignment{}
               |> RoleAssignment.changeset(%{role_key: "historian", agent_id: agent_b.id})
               |> Repo.insert()

      assert {"role already assigned", _} = cs.errors[:role_key]
    end

    test "the same agent may hold more than one role" do
      seed_role!("designer")
      seed_role!("historian")
      agent = insert_agent!()

      assert {:ok, _} =
               %RoleAssignment{}
               |> RoleAssignment.changeset(%{role_key: "designer", agent_id: agent.id})
               |> Repo.insert()

      assert {:ok, _} =
               %RoleAssignment{}
               |> RoleAssignment.changeset(%{role_key: "historian", agent_id: agent.id})
               |> Repo.insert()
    end

    test "deleting a role cascades to its assignment row" do
      role = seed_role!("meeting_scribe")
      agent = insert_agent!()

      {:ok, _} =
        %RoleAssignment{}
        |> RoleAssignment.changeset(%{role_key: "meeting_scribe", agent_id: agent.id})
        |> Repo.insert()

      assert Repo.aggregate(RoleAssignment, :count) >= 1
      Repo.delete!(role)

      refute Repo.exists?(from(ra in RoleAssignment, where: ra.role_key == "meeting_scribe"))
    end

    test "deleting an agent cascades to its assignment rows" do
      seed_role!("triage_officer")
      agent = insert_agent!()

      {:ok, _} =
        %RoleAssignment{}
        |> RoleAssignment.changeset(%{role_key: "triage_officer", agent_id: agent.id})
        |> Repo.insert()

      Repo.delete!(agent)

      refute Repo.exists?(from(ra in RoleAssignment, where: ra.agent_id == ^agent.id))
    end

    test "FK error surfaces when role_key has no parent row" do
      agent = insert_agent!()

      assert {:error, cs} =
               %RoleAssignment{}
               |> RoleAssignment.changeset(%{role_key: "designer", agent_id: agent.id})
               |> Repo.insert()

      assert Keyword.has_key?(cs.errors, :role_key)
    end
  end

  describe "migration shape" do
    test "table exists with the expected columns" do
      %{rows: rows} =
        SQL.query!(
          Repo,
          "SELECT column_name FROM information_schema.columns WHERE table_name = $1 ORDER BY column_name",
          ["role_assignments"]
        )

      columns = Enum.map(rows, fn [c] -> c end)

      for required <- ~w(id role_key agent_id inserted_at updated_at) do
        assert required in columns, "missing column #{required} (have: #{inspect(columns)})"
      end
    end

    test "role_key is uniquely indexed and agent_id has a non-unique index" do
      %{rows: rows} =
        SQL.query!(
          Repo,
          """
          SELECT indexname, indexdef FROM pg_indexes
          WHERE tablename = 'role_assignments'
          """,
          []
        )

      by_name = Map.new(rows, fn [n, d] -> {n, d} end)

      assert Map.has_key?(by_name, "role_assignments_role_key_index")
      assert by_name["role_assignments_role_key_index"] =~ "UNIQUE"

      assert Map.has_key?(by_name, "role_assignments_agent_id_index")
      refute by_name["role_assignments_agent_id_index"] =~ "UNIQUE"
    end
  end
end
