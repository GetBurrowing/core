defmodule Platform.Agents.HistorianCursor do
  @moduledoc """
  Schema for `org_historian_cursors` — per-workspace, per-corpus progress
  tracking for the Historian agent.

  The Historian (T6) walks five corpora and remembers where it left off:

    * `"pages"`       — `org_wiki_pages` (excluding catalog cards)
    * `"journal"`     — `org_wiki_journal_entries`
    * `"messages"`    — `chat_messages`
    * `"transcripts"` — `meeting_transcripts`
    * `"files"`       — `org_wiki_pages`, catalog cards only

  ## `@valid_corpora` is a SILENT gate — read this before editing it

  `Platform.Agents.Historian.mark_run_started/1` wraps its per-corpus
  upsert in an `Enum.each` inside a `Repo.transaction` and discards the
  `{:error, changeset}` this `validate_inclusion/3` produces, then
  returns `:ok`. A corpus registered everywhere EXCEPT here therefore
  never gets a cursor row, `cursor_last_processed_at/2` keeps returning
  `nil`, and that corpus re-dispatches its entire history on every pass,
  forever — with `:ok` returned and nothing logged.

  `Platform.Agents.HistorianCorpusRegistrationTest` is the checklist that
  catches this, and it names this file explicitly when it fires.

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

  @valid_corpora ~w(pages journal messages transcripts files)

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
