defmodule Platform.Repo.Migrations.SeedConsumedInstructionGuidance do
  use Ecto.Migration

  @moduledoc "Task 01a1b6e1: insert-only text targets consumed at dispatch by the existing setup guide."
  def up, do: Platform.InstructionPacks.Guidance.seed()
  def down, do: :ok
end
