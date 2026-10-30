defmodule Platform.Repo.Migrations.AddClosingRenderSnapshots do
  @moduledoc "Task 01a18ab6: retain each render's exact closing contract; NULL means historical absence."
  use Ecto.Migration

  def change do
    alter table(:social_clip_renders) do
      add(:closing_video, :map)
    end
  end
end
