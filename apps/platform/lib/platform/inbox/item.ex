defmodule Platform.Inbox.Item do
  @moduledoc """
  Schema for the `inbox_items` table — one durable per-user attention row.

  An inbox item is a single notification addressed to exactly one user. It
  points back at the source that produced it via the `(source_type, source_id)`
  pair, which is a deliberately loose cross-schema pointer (NOT a foreign key):
  the source may live in `chat_messages`, `tasks`, `review_requests`,
  `meetings`, etc.

  `kind` and `source_type` are extensible string enums guarded by the changeset
  (`@kinds` / `@source_types`). Read status (`read_at`) is orthogonal to
  dismissal (`dismissed_at`): dismissal removes a row from the unread list,
  reading does not. Dismissal is per-ROW — see `Platform.Inbox` for the
  "dismiss = gone; @mention = back" semantics.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(chat_mention task_plan_review review_request_pending meeting_starting task_sponsor_assigned)
  @source_types ~w(chat_message task review_request meeting)

  @type t :: %__MODULE__{}

  schema "inbox_items" do
    belongs_to(:user, Platform.Accounts.User)
    field(:kind, :string)
    field(:source_type, :string)
    # Plain uuid, not a belongs_to — the source lives in another schema.
    field(:source_id, Ecto.UUID)
    field(:title, :string)
    field(:body, :string)
    field(:url, :string)
    field(:read_at, :utc_datetime_usec)
    field(:dismissed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The allowed `kind` values (extensible enum guarded by the changeset)."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The allowed `source_type` values (extensible enum guarded by the changeset)."
  @spec source_types() :: [String.t()]
  def source_types, do: @source_types

  @doc """
  Build a changeset for an inbox item.

  Requires `user_id`, `kind`, `source_type`, `source_id` and `title`; guards
  `kind` / `source_type` against their enums and asserts the `user_id` foreign
  key.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :user_id,
      :kind,
      :source_type,
      :source_id,
      :title,
      :body,
      :url,
      :read_at,
      :dismissed_at
    ])
    |> validate_required([:user_id, :kind, :source_type, :source_id, :title])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:source_type, @source_types)
    |> foreign_key_constraint(:user_id)
  end
end
