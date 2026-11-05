defmodule Platform.Repo.Migrations.CreateLinkUnfurls do
  @moduledoc """
  Task 01a1a944-b4fa-7000-b75a-ce138df43002, stage 2: the `link_unfurls`
  table, a URL-keyed cache of outside-link previews
  (`Platform.Chat.LinkUnfurl`). One row per normalised URL (`url_key`,
  unique), so two messages posting the same page fetch it once. Nothing on
  `chat_messages` changes.
  """
  use Ecto.Migration

  def up do
    create table(:link_unfurls) do
      add(:url_key, :text, null: false)
      add(:url, :text, null: false)
      add(:status, :text, null: false, default: "pending")
      add(:title, :text)
      add(:description, :text)
      add(:image_url, :text)
      add(:image_width, :integer)
      add(:image_height, :integer)
      add(:site_name, :text)
      add(:author, :text)
      add(:provider, :text)
      # The page's twitter:card, so a card can lead with an image of unknown
      # size when the page declared summary_large_image (stage 4).
      add(:twitter_card, :text)
      add(:media_kind, :text)
      add(:duration_seconds, :integer)
      add(:fetched_at, :utc_datetime_usec)
      add(:expires_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:link_unfurls, [:url_key]))

    create(
      constraint(:link_unfurls, :link_unfurls_status_check,
        check: "status IN ('pending', 'ok', 'failed', 'refused')"
      )
    )

    create(
      constraint(:link_unfurls, :link_unfurls_media_kind_check,
        check: "media_kind IS NULL OR media_kind IN ('video', 'article', 'other')"
      )
    )
  end

  def down do
    drop(table(:link_unfurls))
  end
end
