defmodule Platform.Repo.Migrations.SeedMeetingBriefSynthesisPrompt do
  use Ecto.Migration

  @moduledoc """
  Task 01a16974-e3db-7000-97e9-8ec9611189bc stage 3: install the native
  synthesis prompt on existing installs. Insert only; preserve any existing
  operator-written row. The additive template survives rollback so a human
  edit is never deleted by rolling back application code.
  """
  @slug "meetings.brief_synthesis.v1"
  def up do
    Platform.Repo.insert!(
      %Platform.Roles.RoleResponsibility{
        role_key: "meeting_scribe",
        responsibility_key: "meetings.brief_synthesis"
      }, on_conflict: :nothing, conflict_target: [:role_key, :responsibility_key])

    alias Platform.Orchestration.PromptTemplates

    descriptor =
      Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug)) ||
        raise "Missing meeting synthesis prompt descriptor"

    if is_nil(PromptTemplates.get_template_by_slug(@slug)) do
      case PromptTemplates.create_template(
             Map.take(descriptor, [:slug, :name, :description, :content, :variables])
           ) do
        {:ok, _} -> :ok
        {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset
      end
    end

    :ok
  end

  def down do
    execute(
      "DELETE FROM role_responsibilities WHERE role_key = 'meeting_scribe' AND responsibility_key = 'meetings.brief_synthesis'"
    )
  end
end
