defmodule Platform.Roles.RoleTest do
  @moduledoc """
  Tests for the `Platform.Roles.Role` schema (M4 stage 1 of task
  019ef65b-a361). Covers changeset validation, the closed-enum guard
  on `key`, the unique constraint on the natural primary key, and the
  migration shape (column presence + DB-side CHECK constraint).
  """
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Platform.Repo
  alias Platform.Roles.Role

  # Stage 4 added a seed migration that pre-inserts the four canonical
  # role rows. These stage-1 persistence tests pre-date that and
  # exercise raw "insert then expect a clean row count" behaviour —
  # wipe the seeded data in the per-test sandbox transaction so the
  # round-trip and duplicate-key assertions keep holding.
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

  defp base_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        key: "designer",
        name: "Designer",
        description: "Owns visual identity, brand checks, design review.",
        icon: "hero-paint-brush"
      },
      overrides
    )
  end

  describe "changeset/2 — happy path" do
    test "valid attrs pass" do
      cs = Role.changeset(%Role{}, base_attrs())
      assert cs.valid?, inspect(errors_on(cs))
    end

    test "each valid_keys/0 member is accepted" do
      for key <- Role.valid_keys() do
        cs = Role.changeset(%Role{}, base_attrs(%{key: key}))
        assert cs.valid?, "expected key #{inspect(key)} to be valid"
      end
    end
  end

  describe "changeset/2 — required fields" do
    test "rejects empty attrs" do
      cs = Role.changeset(%Role{}, %{})
      refute cs.valid?

      for field <- [:key, :name, :description, :icon] do
        assert Keyword.has_key?(cs.errors, field),
               "expected error on #{field}, got: #{inspect(cs.errors)}"
      end
    end
  end

  describe "changeset/2 — enum guard rails" do
    test "rejects a non-roster key" do
      cs = Role.changeset(%Role{}, base_attrs(%{key: "wizard"}))
      refute cs.valid?
      assert %{key: ["is invalid"]} = errors_on(cs)
    end
  end

  describe "valid_keys/0" do
    test "exposes the four canonical roles in a stable order" do
      assert Role.valid_keys() == ~w(designer historian meeting_scribe triage_officer)
    end
  end

  describe "persistence" do
    test "round-trips through the database" do
      attrs = base_attrs()

      assert {:ok, inserted} =
               %Role{} |> Role.changeset(attrs) |> Repo.insert()

      reloaded = Repo.get!(Role, inserted.key)
      assert reloaded.key == "designer"
      assert reloaded.name == "Designer"
      assert reloaded.icon == "hero-paint-brush"
    end

    test "duplicate key is rejected by the unique constraint" do
      attrs = base_attrs(%{key: "historian", name: "Historian"})

      assert {:ok, _} = %Role{} |> Role.changeset(attrs) |> Repo.insert()

      dup_attrs = base_attrs(%{key: "historian", name: "Historian (dup)"})

      assert {:error, cs} =
               %Role{} |> Role.changeset(dup_attrs) |> Repo.insert()

      assert Keyword.has_key?(cs.errors, :key)
    end
  end

  describe "migration shape" do
    test "table exists with the expected columns" do
      %{rows: rows} =
        SQL.query!(
          Repo,
          "SELECT column_name FROM information_schema.columns WHERE table_name = $1 ORDER BY column_name",
          ["roles"]
        )

      columns = Enum.map(rows, fn [c] -> c end)

      for required <- ~w(key name description icon inserted_at updated_at) do
        assert required in columns, "missing column #{required} (have: #{inspect(columns)})"
      end
    end

    test "DB-side CHECK constraint rejects a non-roster key on raw SQL insert" do
      assert_raise Postgrex.Error, ~r/roles_key_check/, fn ->
        SQL.query!(
          Repo,
          """
          INSERT INTO roles (key, name, description, icon, inserted_at, updated_at)
          VALUES ('wizard', 'Wizard', 'd', 'i', now(), now())
          """,
          []
        )
      end
    end
  end
end
