defmodule Platform.Repo.Migrations.AddSocialApprovalCards do
  @moduledoc """
  The human approval flow's data (task 01a140a9-31b0, Social 3/7). The
  version, 20261015192213, is the one the stack's router reserved for this
  member.

    * `social_profiles.space_id`: the profile's channel, where approval cards
      are posted. References `chat_spaces` (a stable core table), nullable,
      indexed, `on_delete: :nilify_all`: deleting the space leaves the profile
      without a channel, and a post then cannot enter `needs_approval`.
    * `social_approval_cards`: one row per approval card canvas. `canvas_id`
      is UNIQUE, so the card is found by the canvas a human clicked. A post
      has at most ONE live card (`pending` or `deciding`, partial unique
      index). A `decided` card must name its decision, its decider (a users
      row; agents are another table) and its time (CHECK). `card_digest` is
      the sha256 of the canvas document the card was rendered with, so a
      patched canvas is detected at click time.
  """

  use Ecto.Migration

  def change do
    alter table(:social_profiles) do
      add(:space_id, references(:chat_spaces, type: :binary_id, on_delete: :nilify_all))
    end

    create(index(:social_profiles, [:space_id]))

    create table(:social_approval_cards, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:post_id, references(:social_posts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:canvas_id, references(:chat_canvases, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:message_id, references(:chat_messages, type: :binary_id, on_delete: :nilify_all))
      add(:card_digest, :text, null: false)
      add(:state, :string, null: false, default: "pending")
      add(:decision, :string)
      add(:decided_by_user_id, references(:users, type: :binary_id, on_delete: :restrict))
      add(:decided_at, :utc_datetime_usec)
      add(:edited_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:edited_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:social_approval_cards, [:canvas_id]))
    create(index(:social_approval_cards, [:post_id]))

    create(
      unique_index(:social_approval_cards, [:post_id],
        where: "state IN ('pending', 'deciding')",
        name: :social_approval_cards_one_live_card_per_post
      )
    )

    create(
      constraint(:social_approval_cards, :social_approval_cards_state_check,
        check: "state IN ('pending', 'deciding', 'decided', 'superseded')"
      )
    )

    create(
      constraint(:social_approval_cards, :social_approval_cards_decision_check,
        check: "decision IS NULL OR decision IN ('approve', 'reject')"
      )
    )

    create(
      constraint(:social_approval_cards, :social_approval_cards_decided_complete_check,
        check:
          "state <> 'decided' OR (decision IS NOT NULL AND decided_by_user_id IS NOT NULL AND decided_at IS NOT NULL)"
      )
    )
  end
end
