defmodule Platform.Files.Star do
  @moduledoc "A personal bookmark. Its target never confers read permission."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  schema "browser_stars" do
    belongs_to(:user, Platform.Accounts.User)
    belongs_to(:canvas, Platform.Chat.Canvas)
    belongs_to(:file, Platform.Files.File)
    belongs_to(:attachment, Platform.Chat.Attachment)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(star, attrs) do
    star
    |> cast(attrs, [:user_id, :canvas_id, :file_id, :attachment_id])
    |> validate_required([:user_id])
    |> check_constraint(:canvas_id, name: :browser_stars_one_target)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:canvas_id)
    |> foreign_key_constraint(:file_id)
    |> foreign_key_constraint(:attachment_id)
  end
end
