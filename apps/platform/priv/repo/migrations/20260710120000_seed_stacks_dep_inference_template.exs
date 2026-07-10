defmodule Platform.Repo.Migrations.SeedStacksDepInferenceTemplate do
  use Ecto.Migration

  @doc """
  Re-run seed_defaults to insert the `stacks.dep_inference.v1` template on
  existing deployments where the original seed migration ran before this
  template was registered. Idempotent — `seed_defaults/0` only inserts when
  the slug is missing, so operator edits and re-runs are both safe.

  See ADR 0045 (task stacks v2) and Platform.Tasks.Stacks.DepInference for
  how this template is rendered at LLM-inference time.
  """
  def up do
    Platform.Orchestration.PromptTemplates.seed_defaults()
  end

  def down do
    :ok
  end
end
