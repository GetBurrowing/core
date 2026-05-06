defmodule Platform.Repo.Migrations.AddRejectionReasonToPlans do
  use Ecto.Migration

  @moduledoc """
  Adds `rejection_reason` to `plans`. The column is shared by both the
  planning-rejection flow (existing `Tasks.reject_plan/2`) and the
  reopen-with-feedback flow that lifts the same reason text into a new
  task feedback message. See task 019dfad1.

  Stage 1 only adds the column and the schema field; later stages wire
  it through the lifecycle helpers, dispatch context, and UI.
  """

  def change do
    alter table(:plans) do
      add(:rejection_reason, :text)
    end
  end
end
