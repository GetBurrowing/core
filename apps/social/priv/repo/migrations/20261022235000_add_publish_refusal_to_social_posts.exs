defmodule Platform.Repo.Migrations.AddPublishRefusalToSocialPosts do
  @moduledoc """
  Why an approved post did not go out (task 01a165f1, stage 1). When
  `Platform.Social.Publishing.publish_post/2` refuses an approved post before
  the vendor (media rules, the rate limit, an archived account, no publisher
  configured) it records `refused_reason`, `refused_at` and, for the rate
  limit only, `retry_after`. The status stays `approved`, so a retry is just
  `publish_post/2` again. Every later success or terminal write clears all
  three. Nullable; NULL means "not refused".

  Additive only (`0055-extension-contract-and-build-time-modules.md § 6. Migrations`).
  """

  use Ecto.Migration

  def change do
    alter table(:social_posts) do
      add(:refused_reason, :string)
      add(:refused_at, :utc_datetime_usec)
      add(:retry_after, :utc_datetime_usec)
    end

    create(
      constraint(:social_posts, :social_posts_refused_reason_check,
        check:
          "refused_reason IS NULL OR refused_reason IN " <>
            "('media_rejected', 'rate_limited', 'account_archived', 'publisher_not_configured')"
      )
    )
  end
end
