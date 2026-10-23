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

  # `meeting_invited` and `meeting_starting` are deliberately distinct kinds:
  # an INVITE is asynchronous ("you are on the list for a meeting later"),
  # while `meeting_starting` fires when the meeting is beginning NOW. Different
  # trigger, different urgency, different copy — and only a typed invite row can
  # be grouped or counted as an invite. No migration is needed to add a kind:
  # `inbox_items.kind` is a plain string column with no DB CHECK; the enum is
  # guarded solely by `validate_inclusion(:kind, @kinds)` below.
  # `lifecycle_step_failed` (task 019fe1b6-f1ee-73d4-8e6f-bd9f191c6a95 stage 4)
  # is the destination for a NON-AWAITED lifecycle hook step that fails after
  # the edge has already reported its outcome. It cannot be folded into the
  # edge's own `complete / not_applicable / failed` result — by the time it
  # fails the task has moved on and that result is history — so without a
  # durable row of its own the failure would be a log line nobody reads. See
  # `Platform.Lifecycle.Executor.settle_detached/2`.
  # `briefing` (task 01a15ee1-48c8-7000-a8f1-33a5586cb458 stage 1) is the
  # day's insight briefing: ONE row per person per `digest_date`, written and
  # refreshed only by `Platform.Inbox.upsert_briefing_item/2`, with
  # `source_type: "briefing"` and `source_id` = the `memory_briefings` id.
  @kinds ~w(chat_mention task_plan_review review_request_pending meeting_starting meeting_invited task_sponsor_assigned lifecycle_step_failed briefing)
  # `task_review` is the per-task rollup source for review-gate attention rows:
  # one durable row per (sponsor, task) regardless of how many review requests
  # the task fans out (see `Platform.Tasks.ReviewRequests`). Kept distinct from
  # the plain `task` source so a rollup dismissal never touches a
  # `task_sponsor_assigned` / `task_plan_review` row that shares the task id.
  @source_types ~w(chat_message task review_request meeting task_review briefing)

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

  @doc """
  The allowed `kind` values (extensible enum guarded by the changeset):
  core's own, then every registered extension's (`Platform.Extension`
  `inbox_kinds/0`). Read per call, never captured in an attribute, so a kind
  is accepted only while its extension is registered.
  """
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds ++ Enum.map(Platform.Extensions.inbox_kinds(), & &1.kind)

  @doc """
  The allowed `source_type` values: core's own, then every registered
  extension's, read per call like `kinds/0`.
  """
  @spec source_types() :: [String.t()]
  def source_types,
    do: Enum.uniq(@source_types ++ Enum.map(Platform.Extensions.inbox_kinds(), & &1.source_type))

  @doc "Core's own kinds, without any extension's (the clash check's reference list)."
  @spec core_kinds() :: [String.t()]
  def core_kinds, do: @kinds

  @doc "Core's own source types, without any extension's."
  @spec core_source_types() :: [String.t()]
  def core_source_types, do: @source_types

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
    |> validate_inclusion(:kind, kinds())
    |> validate_inclusion(:source_type, source_types())
    |> foreign_key_constraint(:user_id)
  end
end
