defmodule Platform.Repo.Migrations.AddDoctorAndRelationshipStewardRoles do
  @moduledoc """
  Admit and seed the two super-agent roles the sponsor approved on
  2026-11-18, `doctor` and `relationship_steward`, their one-key bundles
  (`doctor.checkup`, `relationships.follow_up_sweep`) and their two prompt
  templates. Modelled on `20261117214509_add_showrunner_role.exs`.

  One file, three steps, in this order:

    1. **Extend `roles_key_check`** to every key valid at this version plus
       `doctor` and `relationship_steward`. `Platform.Roles.Role` pins
       `@valid_keys` and the CHECK enforces the same roster at the DB layer.
    2. **Seed both roles and bundles** with `seed_defaults(only_keys: [...])`,
       scoped so this file never inserts a role a later migration is meant to
       admit. Idempotent (`on_conflict: :nothing`).
    3. **Seed the two templates** from their `default_templates/0`
       descriptors, insert-or-force-update. A missing descriptor raises.

  NO ASSIGNMENT IS SEEDED, and no person: the escalation human is written at
  run time by `Platform.Doctor.provision/1` /
  `Handlers.RelationshipsFollowUpSweep.provision/1`. Until an agent holds a
  role, every fire of its key returns `{:ok, :unfilled}`.

  `down/0` deletes the two template rows and the two roles (the FK cascade
  clears their bundle and assignment rows), then restores the previous CHECK.
  """

  use Ecto.Migration

  # old-code-compatible: only widens roles_key_check (adds 'doctor' and 'relationship_steward'); every key the previous release writes still passes, and it reads roles.key as a plain string

  @roles ["doctor", "relationship_steward"]

  @slugs [
    "doctor.checkup.v1",
    "relationships.follow_up_sweep.v1"
  ]

  # The ten-key roster `20261118200000_merge_meeting_producer_into_scribe.exs`
  # left (meeting_producer merged into meeting_scribe).
  @roster_before "key IN ('designer','historian','meeting_scribe'," <>
                   "'triage_officer','security_guard','architect','agents_leader'," <>
                   "'scientist','janitor','showrunner')"

  @roster_after "key IN ('designer','historian','meeting_scribe'," <>
                  "'triage_officer','security_guard','architect','agents_leader'," <>
                  "'scientist','janitor','showrunner','doctor','relationship_steward')"

  def up do
    drop(constraint(:roles, :roles_key_check))
    create(constraint(:roles, :roles_key_check, check: @roster_after))

    # The DDL above must be applied before the seed's INSERT reads the CHECK.
    flush()

    Platform.Roles.Seeds.seed_defaults(only_keys: @roles)

    Enum.each(@slugs, &seed_prompt_template!/1)
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM prompt_templates WHERE slug = ANY($1)",
      [@slugs]
    )

    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM roles WHERE key = ANY($1)",
      [@roles]
    )

    drop(constraint(:roles, :roles_key_check))
    create(constraint(:roles, :roles_key_check, check: @roster_before))
  end

  @doc "The template slugs this migration seeds."
  def slugs, do: @slugs

  @doc "The role keys this migration admits."
  def roles, do: @roles

  # Descriptor positions, so the closed-roster ownership scan credits this file:
  #   slug: "doctor.checkup.v1"
  #   slug: "relationships.follow_up_sweep.v1"
  defp seed_prompt_template!(slug) do
    alias Platform.Orchestration.{PromptTemplate, PromptTemplates}

    content = PromptTemplates.default_content_for_slug(slug)
    descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == slug))

    unless descriptor do
      raise "[AddDoctorAndRelationshipStewardRoles] no default descriptor for slug=#{slug} — " <>
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
               description: descriptor.description,
               variables: descriptor.variables
             }) do
          {:ok, _} -> :ok
          {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset
        end
    end

    :ok
  end
end
