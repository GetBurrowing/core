defmodule Platform.Roles.ResponsibilityOverrideTest do
  @moduledoc """
  Tests for the `Platform.Roles.ResponsibilityOverride` schema (M4
  stage 2 of task 019ef65b-a361). Covers changeset validation, the
  unique constraint enforcing at-most-one override per responsibility
  (Decision 3), agent FK cascade, the deliberate absence of a hard FK
  against `responsibilities(key)`, and the migration shape.
  """
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Roles.ResponsibilityOverride

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
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
      agent = insert_agent!()

      cs =
        ResponsibilityOverride.changeset(%ResponsibilityOverride{}, %{
          responsibility_key: "design.brand_check",
          agent_id: agent.id
        })

      assert cs.valid?, inspect(errors_on(cs))
    end

    test "missing fields are required" do
      cs = ResponsibilityOverride.changeset(%ResponsibilityOverride{}, %{})
      refute cs.valid?

      for field <- [:responsibility_key, :agent_id] do
        assert Keyword.has_key?(cs.errors, field),
               "expected error on #{field}, got: #{inspect(cs.errors)}"
      end
    end
  end

  describe "persistence" do
    test "round-trips through the database" do
      agent = insert_agent!()

      assert {:ok, inserted} =
               %ResponsibilityOverride{}
               |> ResponsibilityOverride.changeset(%{
                 responsibility_key: "design.brand_check",
                 agent_id: agent.id
               })
               |> Repo.insert()

      reloaded = Repo.get!(ResponsibilityOverride, inserted.id)
      assert reloaded.responsibility_key == "design.brand_check"
      assert reloaded.agent_id == agent.id
    end

    test "duplicate responsibility_key is rejected (Decision 3)" do
      agent_a = insert_agent!()
      agent_b = insert_agent!()

      assert {:ok, _} =
               %ResponsibilityOverride{}
               |> ResponsibilityOverride.changeset(%{
                 responsibility_key: "meetings.transcribe",
                 agent_id: agent_a.id
               })
               |> Repo.insert()

      assert {:error, cs} =
               %ResponsibilityOverride{}
               |> ResponsibilityOverride.changeset(%{
                 responsibility_key: "meetings.transcribe",
                 agent_id: agent_b.id
               })
               |> Repo.insert()

      assert {"responsibility already overridden", _} = cs.errors[:responsibility_key]
    end

    test "same agent may own multiple distinct overrides" do
      agent = insert_agent!()

      assert {:ok, _} =
               %ResponsibilityOverride{}
               |> ResponsibilityOverride.changeset(%{
                 responsibility_key: "design.brand_check",
                 agent_id: agent.id
               })
               |> Repo.insert()

      assert {:ok, _} =
               %ResponsibilityOverride{}
               |> ResponsibilityOverride.changeset(%{
                 responsibility_key: "meetings.transcribe",
                 agent_id: agent.id
               })
               |> Repo.insert()
    end

    test "deleting an agent cascades to its override rows" do
      agent = insert_agent!()

      {:ok, _} =
        %ResponsibilityOverride{}
        |> ResponsibilityOverride.changeset(%{
          responsibility_key: "triage.assign",
          agent_id: agent.id
        })
        |> Repo.insert()

      Repo.delete!(agent)

      refute Repo.exists?(from(o in ResponsibilityOverride, where: o.agent_id == ^agent.id))
    end

    test "responsibility_key has NO hard FK — unknown keys are accepted" do
      # Stage 2 spec defers the FK against responsibilities(key) to
      # match stage 1's role_responsibilities convention. Verify that
      # today's table accepts any string so long as the agent exists.
      agent = insert_agent!()

      assert {:ok, _} =
               %ResponsibilityOverride{}
               |> ResponsibilityOverride.changeset(%{
                 responsibility_key: "made.up.never.seeded",
                 agent_id: agent.id
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
          ["responsibility_overrides"]
        )

      columns = Enum.map(rows, fn [c] -> c end)

      for required <- ~w(id responsibility_key agent_id inserted_at updated_at) do
        assert required in columns, "missing column #{required} (have: #{inspect(columns)})"
      end
    end

    test "responsibility_key is uniquely indexed and agent_id is non-unique" do
      %{rows: rows} =
        SQL.query!(
          Repo,
          """
          SELECT indexname, indexdef FROM pg_indexes
          WHERE tablename = 'responsibility_overrides'
          """,
          []
        )

      by_name = Map.new(rows, fn [n, d] -> {n, d} end)

      assert Map.has_key?(by_name, "responsibility_overrides_responsibility_key_index")
      assert by_name["responsibility_overrides_responsibility_key_index"] =~ "UNIQUE"

      assert Map.has_key?(by_name, "responsibility_overrides_agent_id_index")
      refute by_name["responsibility_overrides_agent_id_index"] =~ "UNIQUE"
    end
  end
end
