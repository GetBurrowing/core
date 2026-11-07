defmodule Platform.Repo.Migrations.CreateInstructionPackReleases do
  use Ecto.Migration

  @moduledoc "Task 01a1b6e1: store immutable signed text instruction releases on the existing feedback broker."
  def change do
    create table(:instruction_packs, primary_key: false) do
      add(:id, :string, primary_key: true)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create table(:instruction_pack_releases, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:pack_id, references(:instruction_packs, type: :string, on_delete: :restrict),
        null: false
      )

      add(:version, :bigint, null: false)
      add(:digest, :string, null: false)
      add(:envelope, :binary, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:instruction_pack_releases, [:pack_id, :version]))
    create(constraint(:instruction_pack_releases, :positive_version, check: "version > 0"))

    execute(
      """
      CREATE FUNCTION reject_instruction_pack_release_mutation() RETURNS trigger AS $$
      BEGIN RAISE EXCEPTION 'instruction pack releases are immutable'; END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION reject_instruction_pack_release_mutation()"
    )

    execute(
      """
      CREATE TRIGGER instruction_pack_release_immutable BEFORE UPDATE OR DELETE
      ON instruction_pack_releases FOR EACH ROW EXECUTE FUNCTION reject_instruction_pack_release_mutation()
      """,
      "DROP TRIGGER instruction_pack_release_immutable ON instruction_pack_releases"
    )
  end
end
