defmodule Platform.Repo.Migrations.ForceUpdateFederationPreambleTaskKindGuidance do
  use Ecto.Migration

  @moduledoc """
  Force-updates the served federation preamble with task-kind guidance for
  task 019fa1ac-00ef-7a87-9f2d-f05e249ee046.

  The prompt row wins over the source fallback and seed_defaults/0 is
  insert-only, so an attribute edit alone would never reach existing installs.
  Before this migration was authored, the fabrikam and milv live rows were read on
  moon: both had length 12910, md5 1e85554dd9d6a713de1aabb3f4244156,
  updated_by agent, and neither contained the new heading. There was therefore
  no divergent human edit to preserve. Content comes from the descriptor so
  the deployed row and fallback remain identical. down/0 is intentionally a
  no-op; restoring guidance that causes silently-defaulted feature tasks is not
  useful state.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Orchestration.PromptTemplates

  @slug "federation.preamble"

  def up do
    content = PromptTemplates.default_content_for_slug(@slug)

    if is_binary(content) and String.trim(content) != "" do
      Platform.Repo.update_all(
        from(t in "prompt_templates", where: t.slug == ^@slug),
        set: [content: content, updated_at: DateTime.utc_now()]
      )
    end

    :ok
  end

  def down, do: :ok
end
