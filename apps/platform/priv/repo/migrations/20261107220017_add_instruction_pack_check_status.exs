defmodule Platform.Repo.Migrations.AddInstructionPackCheckStatus do
  use Ecto.Migration
  @moduledoc "Owner check status for task 01a1b6e1-4995-7000-b918-fb305d219275 stage 3."
  def change do
    alter table(:instruction_pack_states) do
      add :check_error, :string
      add :last_successful_check_at, :utc_datetime_usec
    end
  end
end
