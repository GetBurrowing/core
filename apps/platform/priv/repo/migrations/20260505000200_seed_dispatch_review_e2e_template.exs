defmodule Platform.Repo.Migrations.SeedDispatchReviewE2eTemplate do
  use Ecto.Migration

  @slugs ["dispatch.review_e2e", "dispatch.in_review"]

  @moduledoc """
  Seed the new `dispatch.review_e2e` prompt template (introduced as part of the
  per-task `e2e_behavior` validation kind) and refresh the `dispatch.in_review`
  template content so it no longer mentions e2e behavioral validation (that is
  now `dispatch.review_e2e`'s responsibility).

  - `dispatch.review_e2e`: insert if missing, otherwise force-update to current
    default content (covers re-runs in environments where it was created
    manually).
  - `dispatch.in_review`: force-update to current default content so deployments
    that seeded templates before this split pick up the new clarified scope.
  """
  def up do
    alias Platform.Orchestration.PromptTemplates

    Enum.each(@slugs, fn slug ->
      content = PromptTemplates.default_content_for_slug(slug)

      case PromptTemplates.get_template_by_slug(slug) do
        nil when is_binary(content) ->
          template = default_template(slug)

          if template do
            {:ok, _} = PromptTemplates.create_template(template)
          end

        nil ->
          :skip

        existing when is_binary(content) ->
          {:ok, _} = PromptTemplates.update_template(existing, %{content: content})

        _ ->
          :skip
      end
    end)

    :ok
  end

  def down do
    alias Platform.Orchestration.PromptTemplates

    case PromptTemplates.get_template_by_slug("dispatch.review_e2e") do
      nil -> :ok
      template -> {:ok, _} = PromptTemplates.delete_template(template)
    end

    :ok
  end

  # Find the full default-template map (slug + name + description + variables + content).
  # We can't access PromptTemplates.default_templates/0 (private) but we can rebuild the
  # subset we need from public helpers. For dispatch.review_e2e we need a complete row.
  defp default_template(slug) do
    Platform.Orchestration.PromptTemplates
    |> apply_default_templates()
    |> Enum.find(&(&1.slug == slug))
  end

  # PromptTemplates.default_templates/0 is private; use seed_defaults/0 as a proxy
  # that goes through create_template for any missing slug. This helper is only
  # used in the `nil`/insert branch above — we leave the actual seeding to
  # seed_defaults/0 if no row exists.
  defp apply_default_templates(_module) do
    # We delegate to seed_defaults/0 below if needed. For the migration, if the
    # template is missing AND default content exists, fall back to a minimal
    # synthesized row so the migration is robust even if seed_defaults hasn't run.
    case Platform.Orchestration.PromptTemplates.default_content_for_slug("dispatch.review_e2e") do
      nil ->
        []

      content ->
        [
          %{
            slug: "dispatch.review_e2e",
            name: "E2E Behavioral Review Dispatch Prompt",
            description:
              "Sent when a task is in_review and the pending validation kind is e2e_behavior.",
            variables: [
              "task_title",
              "validation_id",
              "evaluation_payload_json",
              "execution_space_id",
              "repo_url",
              "task_slug",
              "skills_reference"
            ],
            content: content
          }
        ]
    end
  end
end
