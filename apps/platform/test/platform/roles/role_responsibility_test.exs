defmodule Platform.Roles.RoleResponsibilityTest do
  @moduledoc """
  Tests for the `Platform.Roles.RoleResponsibility` join schema and the
  `role_responsibilities` table (M4 stage 1 of task 019ef65b-a361).

  Covers changeset validation, the role_key enum guard, the unique
  constraint on the `(role_key, responsibility_key)` pair, the FK
  cascade from `roles.key`, and the absence of a hard FK against
  `responsibilities(key)` (deliberate per stage 1 spec).
  """
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Platform.Repo
  alias Platform.Roles.Role
  alias Platform.Roles.RoleResponsibility

  # Stage 4 added a seed migration that pre-inserts the four canonical
  # role rows + their bundles. These stage-1 tests pre-date that and
  # assume a no-roles starting state — wipe the seeded data in the
  # per-test sandbox transaction so the original behavioural contracts
  # (FK error on missing parent, exact unique-pair collisions, …) keep
  # holding.
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

  describe "changeset/2" do
    test "valid pair passes" do
      seed_role!("designer")

      cs =
        RoleResponsibility.changeset(%RoleResponsibility{}, %{
          role_key: "designer",
          responsibility_key: "design.brand_check"
        })

      assert cs.valid?, inspect(errors_on(cs))
    end

    test "missing fields are required" do
      cs = RoleResponsibility.changeset(%RoleResponsibility{}, %{})
      refute cs.valid?

      for field <- [:role_key, :responsibility_key] do
        assert Keyword.has_key?(cs.errors, field),
               "expected error on #{field}, got: #{inspect(cs.errors)}"
      end
    end

    test "rejects a role_key outside the closed enum" do
      cs =
        RoleResponsibility.changeset(%RoleResponsibility{}, %{
          role_key: "wizard",
          responsibility_key: "design.brand_check"
        })

      refute cs.valid?
      assert %{role_key: ["is invalid"]} = errors_on(cs)
    end
  end

  describe "persistence" do
    test "round-trips a pair and rejects duplicates via the unique pair index" do
      seed_role!("designer")

      attrs = %{role_key: "designer", responsibility_key: "design.brand_check"}

      assert {:ok, inserted} =
               %RoleResponsibility{}
               |> RoleResponsibility.changeset(attrs)
               |> Repo.insert()

      reloaded = Repo.get!(RoleResponsibility, inserted.id)
      assert reloaded.role_key == "designer"
      assert reloaded.responsibility_key == "design.brand_check"

      assert {:error, cs} =
               %RoleResponsibility{}
               |> RoleResponsibility.changeset(attrs)
               |> Repo.insert()

      assert Keyword.has_key?(cs.errors, :role_key) or
               Keyword.has_key?(cs.errors, :responsibility_key)
    end

    test "same responsibility key under a different role is allowed" do
      seed_role!("designer")
      seed_role!("historian")

      assert {:ok, _} =
               %RoleResponsibility{}
               |> RoleResponsibility.changeset(%{
                 role_key: "designer",
                 responsibility_key: "shared.precedent_lookup"
               })
               |> Repo.insert()

      assert {:ok, _} =
               %RoleResponsibility{}
               |> RoleResponsibility.changeset(%{
                 role_key: "historian",
                 responsibility_key: "shared.precedent_lookup"
               })
               |> Repo.insert()
    end

    test "deleting a role cascades to its bundle rows" do
      role = seed_role!("meeting_scribe")

      {:ok, _} =
        %RoleResponsibility{}
        |> RoleResponsibility.changeset(%{
          role_key: "meeting_scribe",
          responsibility_key: "meetings.transcribe"
        })
        |> Repo.insert()

      assert Repo.aggregate(RoleResponsibility, :count) >= 1
      Repo.delete!(role)

      refute Repo.exists?(from(rr in RoleResponsibility, where: rr.role_key == "meeting_scribe"))
    end

    test "FK error surfaces when role_key has no parent row" do
      assert {:error, cs} =
               %RoleResponsibility{}
               |> RoleResponsibility.changeset(%{
                 role_key: "designer",
                 responsibility_key: "design.brand_check"
               })
               |> Repo.insert()

      assert Keyword.has_key?(cs.errors, :role_key)
    end

    test "responsibility_key has NO hard FK — bare strings are accepted" do
      # The stage-1 spec explicitly defers the FK against
      # responsibilities(key). Verify that today's table accepts any
      # responsibility_key string so long as the role exists.
      seed_role!("triage_officer")

      assert {:ok, _} =
               %RoleResponsibility{}
               |> RoleResponsibility.changeset(%{
                 role_key: "triage_officer",
                 responsibility_key: "made.up.never.seeded"
               })
               |> Repo.insert()
    end
  end

  describe "migration shape" do
    test "table exists with the expected columns" do
      %{rows: rows} =
        SQL.query!(
          Repo,
          "SELECT column_name FROM information_schema.columns WHERE table_name = $1 ORDER BY column_name",
          ["role_responsibilities"]
        )

      columns = Enum.map(rows, fn [c] -> c end)

      for required <- ~w(id role_key responsibility_key inserted_at updated_at) do
        assert required in columns, "missing column #{required} (have: #{inspect(columns)})"
      end
    end

    test "the (role_key, responsibility_key) pair is uniquely indexed" do
      %{rows: rows} =
        SQL.query!(
          Repo,
          """
          SELECT indexname FROM pg_indexes
          WHERE tablename = 'role_responsibilities'
          """,
          []
        )

      names = Enum.map(rows, fn [n] -> n end)
      assert "role_responsibilities_pair_idx" in names
      assert "role_responsibilities_role_key_index" in names
      assert "role_responsibilities_responsibility_key_index" in names
    end
  end
end
