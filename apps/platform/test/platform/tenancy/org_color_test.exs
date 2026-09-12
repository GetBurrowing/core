defmodule Platform.Tenancy.OrgColorTest do
  @moduledoc """
  Task 01a09287 stage 1: `orgs.color_hue` / `orgs.color_chroma`.

  The changeset validation and the `orgs_color_hue_range` CHECK constraint
  are two SEPARATE guards, and this file asserts them separately on purpose:
  only the changeset produces a form error, and only the constraint survives
  a raw insert that never goes through `Org.changeset/2`. A test of either
  one alone passes for a build that dropped the other.

  Every org here is a TENANT under fabrikam. `orgs_single_root` is a partial
  unique index on `(parent_org_id IS NULL)`, so a second parentless org is a
  unique violation, not a colour failure.
  """

  use Platform.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  setup do
    %{root_id: Tenancy.get_org_by_slug!("fabrikam").id}
  end

  defp attrs(root_id, extra) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{name: "Invented Co #{n}", slug: "invented_co_#{n}", parent_org_id: root_id},
      extra
    )
  end

  defp changeset(root_id, extra \\ %{}), do: Org.changeset(%Org{}, attrs(root_id, extra))

  describe "changeset/2 hue bounds" do
    test "rejects 360 and -1", %{root_id: root_id} do
      for hue <- [360, -1] do
        cs = changeset(root_id, %{color_hue: hue})
        refute cs.valid?, "expected color_hue #{hue} to be rejected"
        assert Keyword.has_key?(cs.errors, :color_hue)
      end
    end

    test "accepts 0 and 359", %{root_id: root_id} do
      for hue <- [0, 359] do
        cs = changeset(root_id, %{color_hue: hue})
        assert cs.valid?, "expected color_hue #{hue} to be accepted, got #{inspect(cs.errors)}"
      end
    end

    test "accepts a nil hue — 'no colour set' stays legal", %{root_id: root_id} do
      cs = changeset(root_id, %{color_hue: nil, color_chroma: nil})
      assert cs.valid?
      assert {:ok, org} = Repo.insert(cs)
      assert org.color_hue == nil
    end

    test "round-trips a hue and chroma through the database", %{root_id: root_id} do
      assert {:ok, org} = Repo.insert(changeset(root_id, %{color_hue: 340, color_chroma: 0.19}))
      reloaded = Repo.get!(Org, org.id)
      assert reloaded.color_hue == 340
      assert reloaded.color_chroma == 0.19
    end
  end

  describe "orgs_color_hue_range CHECK constraint" do
    defp raw_insert(root_id, hue) do
      n = System.unique_integer([:positive])

      SQL.query!(
        Repo,
        """
        INSERT INTO orgs (id, name, slug, parent_org_id, color_hue, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, $2, $3, $4, now(), now())
        """,
        ["Raw Co #{n}", "raw_co_#{n}", Ecto.UUID.dump!(root_id), hue]
      )
    end

    test "an out-of-range hue raises on a RAW insert that bypasses the changeset", %{
      root_id: root_id
    } do
      assert_raise Postgrex.Error, ~r/orgs_color_hue_range/, fn ->
        raw_insert(root_id, 360)
      end
    end

    test "an in-range hue is accepted by the same RAW insert", %{root_id: root_id} do
      # The positive control: without it, the assertion above passes for a
      # broken statement that raises for any hue at all.
      assert %{num_rows: 1} = raw_insert(root_id, 359)
    end
  end

  describe "migration backfill" do
    test "fabrikam carries the hue and chroma its app.css block already used" do
      # The migration is only load-bearing if the six shipped orgs come out
      # of it with the values that were previously hardcoded; otherwise the
      # later stages that read the column regress the scope rail.
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      assert fabrikam.color_hue == 50
      assert fabrikam.color_chroma == 0.16
    end
  end
end
