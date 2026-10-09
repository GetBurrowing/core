defmodule Platform.DataMigrations.MakeChannelSectionNameNullableTest do
  @moduledoc """
  Regression coverage for `20260927000100_make_channel_section_name_nullable`
  (task 01a08212 stage 1).

  The migration turns `channel_sections.name` into a nullable label override.
  Its data step nulls ONLY the rows whose name equals their org's current
  name (they render identically and simply start following the org) and
  leaves every differing row alone, because a deliberate custom label and a
  stale copy are indistinguishable in the data. Its down step restores each
  NULL name from the org and makes the column NOT NULL again.

  Migrations run to `:up` before ExUnit boots, so the column is asserted as
  it stands; the migration's own helpers are then driven against
  `Platform.Repo` inside the sandbox, and the down/up DDL is executed inside
  the sandbox transaction so it rolls back with the test.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat.Section
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  import Ecto.Query, only: [from: 2]

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260927000100_make_channel_section_name_nullable.exs"
                  ])

  setup_all do
    Code.require_file(@migration_path)
    :ok
  end

  defp migration, do: Platform.Repo.Migrations.MakeChannelSectionNameNullable

  defp nullable? do
    %{rows: [[answer]]} =
      Repo.query!("""
      SELECT is_nullable FROM information_schema.columns
      WHERE table_name = 'channel_sections' AND column_name = 'name'
      """)

    answer == "YES"
  end

  # A tenant org plus its section row, written as raw rows so the stored name
  # is exactly what the test says it is, independent of what the app's
  # creation path would store.
  defp org_with_section!(org_name, section_name) do
    org =
      %Org{}
      |> Org.changeset(%{
        name: org_name,
        slug: "secnull#{System.unique_integer([:positive])}",
        parent_org_id: Tenancy.get_org_by_slug!("acme").id
      })
      |> Repo.insert!()

    %Section{}
    |> Ecto.Changeset.change(%{org_id: org.id, name: section_name, color: "x", position: 99})
    |> Repo.insert!()

    org
  end

  defp stored_name(org) do
    Repo.one!(from(s in Section, where: s.org_id == ^org.id, select: s.name))
  end

  test "after the migration ran, channel_sections.name is nullable" do
    assert nullable?()
  end

  describe "up: follow_org_where_equal/1" do
    test "nulls a row whose name equals its org's name and leaves a differing row alone" do
      equal = org_with_section!("Samename", "Samename")
      differing = org_with_section!("Currentname", "Legacy Label")

      migration().follow_org_where_equal(Repo)

      assert stored_name(equal) == nil
      assert stored_name(differing) == "Legacy Label"
    end

    test "matches on exact equality: a case-only difference is kept as a label" do
      org = org_with_section!("Acme", "ACME")

      migration().follow_org_where_equal(Repo)

      assert stored_name(org) == "ACME"
    end
  end

  describe "down: restore_from_org/1 then NOT NULL" do
    test "restores every NULL name from its org, leaves labels, and the column accepts NOT NULL" do
      following = org_with_section!("Followme", nil)
      labelled = org_with_section!("Orgname", "Custom")

      migration().restore_from_org(Repo)

      assert stored_name(following) == "Followme"
      assert stored_name(labelled) == "Custom"

      # The down's DDL succeeds only if no NULL is left anywhere in the table,
      # including the rows the boot-time resync in test_helper.exs inserted.
      Repo.query!("ALTER TABLE channel_sections ALTER COLUMN name SET NOT NULL")
      refute nullable?()

      # And up again: the round trip lands the equal rows back on NULL.
      Repo.query!("ALTER TABLE channel_sections ALTER COLUMN name DROP NOT NULL")
      migration().follow_org_where_equal(Repo)

      assert nullable?()
      assert stored_name(following) == nil
      assert stored_name(labelled) == "Custom"
    end
  end
end
