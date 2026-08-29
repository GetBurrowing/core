defmodule Platform.Repo.Migrations.AddVoiceConfigToAgents do
  @moduledoc """
  Task 01a03f4f — per-agent voice selection.

  One jsonb column, shaped exactly like the `model_config` column three rows
  above it in `create_agent_tables`: `null: false, default: %{}`.

  ## Why a map and not columns

  Harper's requirement is explicit — "but also a different provider if we
  want." A column named `elevenlabs_voice_id` would make the vendor part of
  the schema, so a second provider becomes a migration. Here the provider is
  a VALUE (`voice_config["provider"]`), the same way `model_config["primary"]`
  carries `"anthropic/..."` or `"openai/..."` without either vendor appearing
  in the DDL.
  """
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :voice_config, :map, null: false, default: %{}
    end
  end
end
