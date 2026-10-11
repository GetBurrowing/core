defmodule Platform.Repo.Migrations.AddJanitorRole do
  @moduledoc """
  Admit and seed the platform-fixed `janitor` role, its one-key bundle
  (`janitor.cron_drain`), and that responsibility's prompt template
  `janitor.cron_drain.v1` (task `019fa1ac-6685-74dc-adac-a3a131a70dee`
  stage 1).

  One file, three steps, in this order:

    1. **Extend `roles_key_check`** to the TEN-key roster: every key valid at
       this version plus `janitor`. `Platform.Roles.Role` pins `@valid_keys`
       and the CHECK enforces the same roster at the DB layer; adding a key
       to one without the other leaves a changeset that validates and an
       insert that raises. Mirrors
       `20260924190100_add_scientist_to_roles_check.exs`. The three steps
       share one file because the router reserved a single migration
       timestamp for this stack member.
    2. **Seed the role and bundle** with `seed_defaults(only_keys:
       ["janitor"])`. Ecto runs each version once, so adding `janitor` to
       `Seeds.default_roles/0` alone never reaches an already-migrated
       install. Scoped to `janitor` so this file never inserts a role a
       later migration is meant to admit. Idempotent: both inserts use
       `on_conflict: :nothing`.
    3. **Seed `janitor.cron_drain.v1`** from its `default_templates/0`
       descriptor, insert-or-force-update, exactly as
       `20261010160100_seed_feedback_intake_prompt.exs` does: the served row
       wins over the descriptor and `PromptTemplates.seed_defaults/0` is
       INSERT-only, so the row and its source cannot otherwise be kept
       together. A missing descriptor raises.

  NO ASSIGNMENT IS SEEDED. Pinning an agent to `janitor` is a runtime
  `role_assignments` operation. Until then `Roles.assignee_for/1` resolves
  nil for `janitor.cron_drain` and the Router's Monday 06:00 UTC fire
  returns `{:ok, :unfilled}`: no context, no model call, no writes.

  `down/0` deletes the template row and the `janitor` role (the FK cascade
  clears its bundle and assignment rows), then restores the nine-key CHECK.
  """

  use Ecto.Migration

  @slug "janitor.cron_drain.v1"

  @roster_with_janitor "key IN ('designer','historian','meeting_scribe','meeting_producer'," <>
                         "'triage_officer','security_guard','architect','agents_leader'," <>
                         "'scientist','janitor')"

  @roster_without_janitor "key IN ('designer','historian','meeting_scribe','meeting_producer'," <>
                            "'triage_officer','security_guard','architect','agents_leader'," <>
                            "'scientist')"

  def up do
    drop(constraint(:roles, :roles_key_check))
    create(constraint(:roles, :roles_key_check, check: @roster_with_janitor))

    # The DDL above must be applied before the seed's INSERT reads the CHECK.
    flush()

    Platform.Roles.Seeds.seed_defaults(only_keys: ["janitor"])

    seed_prompt_template!()
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM prompt_templates WHERE slug = $1",
      [@slug]
    )

    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM roles WHERE key = $1",
      ["janitor"]
    )

    drop(constraint(:roles, :roles_key_check))
    create(constraint(:roles, :roles_key_check, check: @roster_without_janitor))
  end

  defp seed_prompt_template! do
    alias Platform.Orchestration.{PromptTemplate, PromptTemplates}

    content = PromptTemplates.default_content_for_slug(@slug)
    descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug))

    unless descriptor do
      raise "[AddJanitorRole] no default descriptor for slug=#{@slug} — " <>
              "did do_default_templates/0 lose the entry?"
    end

    attrs = %{
      slug: @slug,
      name: descriptor.name,
      description: descriptor.description,
      content: content,
      variables: descriptor.variables
    }

    case PromptTemplates.get_template_by_slug(@slug) do
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

    :ok
  end
end
