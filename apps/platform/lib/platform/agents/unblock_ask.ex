defmodule Platform.Agents.UnblockAsk do
  @moduledoc """
  One ask the lead agent puts to the one human who can unstick a subject
  (task 01a1b6de stage 4). Written and changed only by
  `Platform.Agents.UnblockAsks`.

  ## Fields

    * `subject_type` / `subject_id` — `"agent"` (an `agents` id) or
      `"person"` (a `users` id). A loose pointer, not a foreign key.
    * `class` — the blocker class: `access`, `credentials`, `toolchain`,
      `spend_consent`, `offline` (from `TeamCheck.Classifier`), or
      `person_setup` for a person stuck on setup steps.
    * `state_fingerprint` — a digest of the classified state the ask was
      written for (`UnblockAsks.fingerprint/1`).
    * `owner_user_id` — the fixer whose Inbox carries the ask: the agent's
      sponsor (its runtime's `owner_user_id`) or the install owner; for a
      person, the person.
    * `status` — `open | verifying | resolved | dismissed`. `dismissed` is
      "Not now": still live, re-asked after the interval.
    * `evidence` — the one-line stage-3 evidence ("Why?").
    * `details` — the placeholder values the template renders with
      (`agent`, `account`, `org`, `repo`, `setting`, `steps`).
    * `still_missing` — what the last "I did it, check again" found missing.
    * `variant` / `reask_after_hours` — the
      `agents.unblock_ask.reask_interval` arm and interval this ask used.
    * `ask_count` — how many times it was sent (the first ask and re-asks).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @subject_types ~w(agent person)
  @statuses ~w(open verifying resolved dismissed)
  @live_statuses ~w(open verifying dismissed)

  @type t :: %__MODULE__{}

  schema "unblock_asks" do
    field(:subject_type, :string)
    field(:subject_id, :binary_id)
    field(:class, :string)
    field(:state_fingerprint, :string)
    field(:owner_user_id, :binary_id)
    field(:status, :string, default: "open")
    field(:evidence, :string)
    field(:details, :map, default: %{})
    field(:still_missing, :string)
    field(:variant, :string)
    field(:reask_after_hours, :integer)
    field(:ask_count, :integer, default: 1)
    field(:asked_at, :utc_datetime_usec)
    field(:last_asked_at, :utc_datetime_usec)
    field(:checked_at, :utc_datetime_usec)
    field(:resolved_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The subject types."
  def subject_types, do: @subject_types

  @doc "The statuses."
  def statuses, do: @statuses

  @doc "The statuses of a live (not resolved) ask."
  def live_statuses, do: @live_statuses

  @cast ~w(subject_type subject_id class state_fingerprint owner_user_id status evidence
           details still_missing variant reask_after_hours ask_count asked_at last_asked_at
           checked_at resolved_at)a

  @doc "Changeset for insert and update."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(ask, attrs) do
    ask
    |> cast(attrs, @cast)
    |> validate_required(
      ~w(subject_type subject_id class state_fingerprint owner_user_id status asked_at last_asked_at)a
    )
    |> validate_inclusion(:subject_type, @subject_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:ask_count, greater_than_or_equal_to: 1)
    |> foreign_key_constraint(:owner_user_id)
    |> unique_constraint([:subject_type, :subject_id, :class],
      name: :unblock_asks_live_subject_class_index
    )
  end
end
