defmodule Platform.Repo.Migrations.AddTrendRecoveryCursor do
  @moduledoc "Persist bounded missing-date recovery for Social trends (ADR 0055)."
  use Ecto.Migration

  # Old code ignores the nullable cursor and defaulted count.
  def change do
    alter table(:social_trend_source_states) do
      add(:next_date, :date)
      add(:not_found_count, :integer, null: false, default: 0)
    end
  end
end
