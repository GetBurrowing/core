defmodule Platform.Repo.Migrations.RefreshDispatchTemplatesSubagentIdAck do
  use Ecto.Migration

  @slugs ~w(dispatch.planning dispatch.in_progress dispatch.in_review dispatch.deploying)

  @moduledoc """
  Force-updates the four dispatch prompt templates so every runtime dispatch
  in prod carries the subagent_id-required ack-first preamble (task 019f6c73
  stage 3).

  Stage 3 shipped the new @task_ack_preamble body with subagent_id +
  spawn-first ordering: `task_ack` now REQUIRES a `subagent_id` param, and
  the preamble copy tells operators to spawn the subagent FIRST then include
  its returned agent id in the ack. This migration force-updates the four
  seeded dispatch templates so every runtime dispatch in prod carries the
  new preamble. Without this refresh the templates keep telling agents to
  call task_ack without subagent_id, causing every ack in prod to fail hard
  until the next redeploy.

  Force-update pattern (same as `20260715220000_refresh_dispatch_templates_alarm_silence_fallback`
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
