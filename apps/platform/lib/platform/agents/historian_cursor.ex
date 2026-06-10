defmodule Platform.Agents.HistorianCursor do
  @moduledoc """
  Schema for `org_historian_cursors` — per-workspace, per-corpus progress
  tracking for the Historian agent.

  The Historian (T6) walks four corpora and remembers where it left off:

    * `"pages"`       — `org_context_files`
    * `"journal"`     — `org_memory_entries`
    * `"messages"`    — `chat_messages`
    * `"transcripts"` — `meeting_transcripts`

  Composite primary key `(workspace_id, corpus)` — one cursor row per
  workspace per corpus. `workspace_id` is nullable to support the V1
  org-scope-only fan-out (see `t6-design-lock.md`).

  `last_processed_id` is opaque text so corpora that use a UUID and corpora
  that use a bigserial string both round-trip cleanly.

  All writes go through `Platform.Agents.Historian` — the scheduler stays
  a pure dispatcher.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  @valid_corpora ~w(pages journal messages transcripts)

  schema "org_historian_cursors" do
    field(:workspace_id, :binary_id, primary_key: true)
    field(:corpus, :string, primary_key: true)
    field(:last_processed_id, :string)
    field(:last_processed_at, :utc_datetime_usec)
    field(:last_run_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(corpus)a
  @optional ~w(workspace_id last_processed_id last_processed_at last_run_at)a

  @doc "Changeset for inserts and updates. `workspace_id` may be nil (org-scope)."
  def changeset(cursor, attrs) do
    cursor
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:corpus, @valid_corpora)
  end

  @doc "List of valid corpus keys."
  def valid_corpora, do: @valid_corpora
end
