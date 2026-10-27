defmodule Platform.Repo.Migrations.AddMeetingToTranscripts do
  use Ecto.Migration

  @moduledoc """
  Task 01a17f00-832c-7000-b480-64ab6d710532: persist capture ownership so a
  transcript finishing after another meeting starts cannot cross meeting boundaries.
  Historical rows remain unassigned; their capture start bounds legacy reads.
  """
  def change do
    alter table(:meeting_transcripts) do
      add(:meeting_id, references(:meetings, type: :binary_id, on_delete: :nilify_all))
    end

    create(index(:meeting_transcripts, [:meeting_id]))
  end
end
