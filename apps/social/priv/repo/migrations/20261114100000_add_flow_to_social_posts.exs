defmodule Platform.Repo.Migrations.AddFlowToSocialPosts do
  @moduledoc """
  Social Studio slice A: the flow discriminator.

  `social_posts.flow` is `legacy` (every existing row, and every row a legacy
  writer inserts: the column default) or `studio`. No cast list contains it:
  only Studio's create functions set it, on the struct, at insert, and
  nothing changes it afterwards. The Studio boundary CHECKs that read it are
  added by `AddPlanToSocialPosts`, once `planned` exists.

  Also `accepted_account_id` (the destination named at creative acceptance,
  written once by Studio, never cast, never changed by a retarget) and two
  partial unique indexes over Studio rows bound to a render:
  `(clip_render_id, accepted_account_id)` is the immutable acceptance key
  (idempotent accept), `(clip_render_id, account_id)` allows one Studio post
  per render and current destination (`:duplicate_destination`).

  Additive; `down/0` drops exactly what `up/0` adds.

  Ships with Social as a build-time module's migration (ADR 0055).
  """

  use Ecto.Migration

  # flow, accepted_account_id and the two Studio render indexes.

  def up do
    alter table(:social_posts) do
      add(:flow, :text, null: false, default: "legacy")
      add(:accepted_account_id, :binary_id)
    end

    create(
      unique_index(:social_posts, [:clip_render_id, :accepted_account_id],
        where: "flow = 'studio' AND clip_render_id IS NOT NULL",
        name: :social_posts_studio_acceptance_key
      )
    )

    create(
      unique_index(:social_posts, [:clip_render_id, :account_id],
        where: "flow = 'studio' AND clip_render_id IS NOT NULL",
        name: :social_posts_studio_destination_key
      )
    )

    create(
      constraint(:social_posts, :social_posts_flow_check, check: "flow IN ('legacy', 'studio')")
    )
  end

  def down do
    drop(
      index(:social_posts, [:clip_render_id, :account_id],
        name: :social_posts_studio_destination_key
      )
    )

    drop(
      index(:social_posts, [:clip_render_id, :accepted_account_id],
        name: :social_posts_studio_acceptance_key
      )
    )

    drop(constraint(:social_posts, :social_posts_flow_check))

    alter table(:social_posts) do
      remove(:accepted_account_id)
      remove(:flow)
    end
  end
end
