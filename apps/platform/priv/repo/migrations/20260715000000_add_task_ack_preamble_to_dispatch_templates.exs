defmodule Platform.Repo.Migrations.AddTaskAckPreambleToDispatchTemplates do
  use Ecto.Migration

  @slugs ~w(dispatch.planning dispatch.in_progress dispatch.in_review dispatch.deploying)

  @moduledoc """
  Force-updates the four dispatch prompt templates with the ack-first
  preamble (task 019f640d stage 5).

  Every dispatch template now instructs the runtime that its FIRST tool
  call must be `task_ack(task_id, stage_id)` — this ties the router's
  event-driven safety-net (stage 3) to the payload agents actually
  receive. Without the preamble in prod, executors keep their old
  behaviour of writing code without acking and the router fires
  spurious no-ack alerts after 5 minutes.

  The `variables` list for each row also gains `task_id` + `stage_id`
  so the mustache interpolation actually substitutes them. The
  hardcoded fallbacks in `HeartbeatScheduler` render the same preamble
  via `render_task_ack_preamble/2` for environments where the DB row
  is absent.

  Force-update pattern (same as `20260711202135` and earlier
  refresh migrations): re-write the template body to the current
  `default_content_for_slug/1` output. Environments where the row is
  absent are skipped (`seed_defaults/0` handles those on first boot).
  Environments where the live row already matches see a changeset
  no-op.
  """
  def up do
    alias Platform.Orchestration.{PromptTemplate, PromptTemplates}

    for slug <- @slugs do
      case PromptTemplates.get_template_by_slug(slug) do
        nil ->
          :skip

        %PromptTemplate{} = template ->
          content = PromptTemplates.default_content_for_slug(slug)
          descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == slug))
          variables = (descriptor && descriptor.variables) || template.variables

          attrs = %{content: content, variables: variables}

          case PromptTemplates.update_template(template, attrs) do
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
