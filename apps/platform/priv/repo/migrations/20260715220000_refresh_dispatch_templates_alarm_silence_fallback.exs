defmodule Platform.Repo.Migrations.RefreshDispatchTemplatesAlarmSilenceFallback do
  use Ecto.Migration

  @slugs ~w(dispatch.planning dispatch.in_progress dispatch.in_review dispatch.deploying)

  @moduledoc """
  Force-updates the four dispatch prompt templates with the alarm_silence
  fallback sentence appended to the ack-first preamble (task 019f6791 stage 4).

  Stage 3 shipped the operator-facing `alarm_silence` MCP tool as the durable
  replacement for the `report_blocker(needs_human: false)` ack-proxy
  anti-pattern. This migration refreshes the four seeded dispatch templates so
  every runtime dispatch carries the escape-hatch instruction alongside the
  primary `task_ack` guidance. Without this refresh in prod the templates keep
  telling agents only about `task_ack`, and the operational muscle memory for
  the stale-MCP-cache case defaults back to `report_blocker`.

  Force-update pattern (same as `20260715000000_add_task_ack_preamble_to_dispatch_templates`
  and earlier refresh migrations): re-write the template body to the current
  `default_content_for_slug/1` output. Environments where the row is absent are
  skipped (`seed_defaults/0` handles those on first boot). Environments where
  the live row already matches see a changeset no-op.
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
