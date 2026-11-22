defmodule Platform.Repo.Migrations.AddSocialIdeaSelection do
  @moduledoc """
  "Select for research": a person's choice of an idea to explore.

    * `social_ideas.selected_at` (nullable; the selection state) and
      `selected_by_user_id` (FK users, nilified when the user goes: the idea
      stays selected and the page says "a former user");
    * CHECK: a selector needs a time;
    * `social_idea_selection_events`: an append-only log of `selected` and
      `unselected`, written beside the marker in one transaction. `actor_id`
      is a plain uuid with no FK (the `social_post_events` attribution
      pattern), so the history keeps the actor after the user is erased.
      `idea_id` cascades like `social_post_events` and notes.

  Extension-local migration ownership follows ADR 0055.
  """
  use Ecto.Migration

  # old-code-compatible: additive: two nullable columns, one CHECK that only the new columns can violate,
  # and a new table. The previous release never reads or writes any of them, so a binary rollback
  # hides the selection while its data is retained. `down/0` refuses (raises) while any selected idea
  # or any selection event exists, so history is never discarded silently.

  def up do
    alter table(:social_ideas) do
      add(:selected_at, :utc_datetime_usec)
      add(:selected_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
    end

    create(
      constraint(:social_ideas, :social_ideas_selector_needs_time_check,
        check: "selected_by_user_id IS NULL OR selected_at IS NOT NULL"
      )
    )

    create(index(:social_ideas, [:selected_by_user_id], where: "selected_by_user_id IS NOT NULL"))

    create table(:social_idea_selection_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:idea_id, references(:social_ideas, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:action, :string, null: false)
      add(:actor_kind, :string, null: false)
      add(:actor_id, :binary_id, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(
      constraint(:social_idea_selection_events, :social_idea_selection_events_action_check,
        check: "action IN ('selected', 'unselected')"
      )
    )

    create(
      constraint(:social_idea_selection_events, :social_idea_selection_events_actor_kind_check,
        check: "actor_kind = 'human'"
      )
    )

    create(index(:social_idea_selection_events, [:idea_id, :inserted_at]))
  end

  def down do
    %{rows: [[selected]]} =
      repo().query!("SELECT count(*) FROM social_ideas WHERE selected_at IS NOT NULL")

    %{rows: [[events]]} = repo().query!("SELECT count(*) FROM social_idea_selection_events")

    if selected > 0 or events > 0 do
      raise Ecto.MigrationError,
            "refusing to roll back AddSocialIdeaSelection: #{selected} selected idea(s) and " <>
              "#{events} selection event(s) would be lost; export or remove them deliberately first"
    end

    drop(table(:social_idea_selection_events))
    drop(index(:social_ideas, [:selected_by_user_id]))
    drop(constraint(:social_ideas, :social_ideas_selector_needs_time_check))

    alter table(:social_ideas) do
      remove(:selected_by_user_id)
      remove(:selected_at)
    end
  end
end
