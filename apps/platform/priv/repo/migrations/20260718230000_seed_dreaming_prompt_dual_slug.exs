defmodule Platform.Repo.Migrations.SeedDreamingPromptDualSlug do
  use Ecto.Migration

  @slugs ~w(historian.dreaming memory.dreaming.v1)

  @moduledoc """
  Force-seeds (or refreshes) the dreaming dispatch template under both slugs
  so the router-owned (`historian.dreaming`) and legacy responsibility-router
  (`memory.dreaming.v1`) lookup paths always see the current body.

  Task 019f70e9-29e8 stage 5 extracted the dreaming prompt out of the
  legacy `Platform.Agents.SystemEventScheduler` fallback into
  `Platform.Orchestration.PromptTemplates.do_default_templates/0` and
  registered it under two slugs:

    * `historian.dreaming`   — canonical, referenced by future router
      dispatches and by `HistorianDispatcher.dreaming_template?/1`.
    * `memory.dreaming.v1`   — legacy, referenced by
      `Platform.Responsibilities.Handlers.Dreaming.register/0` as its
      `default_prompt_template`. Fixes the orphan lookup at
      `apps/platform/lib/platform/responsibilities/handlers/dreaming.ex:67`.

  Insert-or-force-update pattern (differs from
  `20260716211312_refresh_dispatch_templates_subagent_id_ack`, which is
  refresh-only): this migration MUST land the row on environments where
  neither slug has ever been seeded, because the legacy handler will
  otherwise silently render an empty body and burn a token round-trip
  before the next `seed_defaults/0` fires. Force-update pattern still
  used for environments where an older revision of the row exists so
  the body advances to the current default in lock-step with the code
  ship.
  """
  def up do
    alias Platform.Orchestration.{PromptTemplate, PromptTemplates}

    for slug <- @slugs do
      content = PromptTemplates.default_content_for_slug(slug)
      descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == slug))

      unless descriptor do
        raise "[SeedDreamingPromptDualSlug] no default descriptor for slug=#{slug} — " <>
                "did do_default_templates/0 lose the entry?"
      end

      attrs = %{
        slug: slug,
        name: descriptor.name,
        description: descriptor.description,
        content: content,
        variables: descriptor.variables
      }

      case PromptTemplates.get_template_by_slug(slug) do
        nil ->
          case PromptTemplates.create_template(attrs) do
            {:ok, _} -> :ok
            {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset
          end

        %PromptTemplate{} = template ->
          case PromptTemplates.update_template(template, %{
                 content: content,
                 variables: descriptor.variables
               }) do
            {:ok, _} -> :ok
            {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset
          end
      end
    end

    :ok
  end

  def down do
    :ok
  end
end
