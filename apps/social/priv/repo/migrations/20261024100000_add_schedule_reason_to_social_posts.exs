defmodule Platform.Repo.Migrations.AddScheduleReasonToSocialPosts do
  @moduledoc """
  Social authoring 5/11 (task 01a16c50): why the drafting agent suggested a
  post's time, shown under the time on the Queue's idea card. At most 280
  characters, nullable, no backfill. Additive; `down/0` drops it.
  """

  use Ecto.Migration

  def up do
    alter table(:social_posts) do
      add(:schedule_reason, :string, size: 280)
    end
  end

  def down do
    alter table(:social_posts) do
      remove(:schedule_reason)
    end
  end
end
