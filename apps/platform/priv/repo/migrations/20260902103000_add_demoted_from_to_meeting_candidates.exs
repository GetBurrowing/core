defmodule Platform.Repo.Migrations.AddDemotedFromToMeetingCandidates do
  use Ecto.Migration

  @moduledoc """
  Make the two causes of an `off_topic` candidate distinguishable
  (task 01a06575 stage 1).

  ## The ambiguity this column removes

  `Platform.Meetings.IntentClassifier`'s evidence gate DEMOTES a
  positive classification to `off_topic` when the model's
  `evidence_quote` is blank, is not a verbatim span of the chunk, or
  sits in a cancelling frame (`parse_content/3`). The demotion
  deliberately preserves the model's original confidence, so the row it
  produces is byte-identical to a genuine decline — same intent, same
  target role, same number in `classifier_confidence`.

  Consequence, before this column: an `off_topic` row at confidence 0.95
  is EITHER "the model looked and said there is nothing here" OR "the
  model found something and the evidence gate destroyed it", and no
  query over `meeting_candidates` can tell those apart. Production
  carries 268 such rows and every one of them is unreadable.

  `demoted_from` names the intent that WAS downgraded. It is:

    * `NULL` for every row the model classified as-answered — including
      a genuine `off_topic`; and
    * the original intent string (`"create_task"`, `"visual_adjust"`, …)
      for a row the evidence gate demoted.

  So `classified_intent = 'off_topic' AND demoted_from IS NULL` is the
  decline population, `demoted_from IS NOT NULL` is the gate's own
  output, and the two are finally separable in SQL.

  ## Why a plain nullable string

  The set of intents is the classifier prompt's enum, which changes with
  the prompt and is versioned there rather than in the database — the
  same reason `classified_intent` and `target_role` are already
  `:string` on this table rather than `Ecto.Enum`-backed check
  constraints. A `demoted_from` that could not hold an intent the
  prompt had just learned would turn a prompt edit into a migration.

  No index: nothing dispatches or sweeps on this column. It is read by
  measurement queries that are already scoped to a meeting or an org,
  and those hit `meeting_candidates_meeting_id_index` first.

  ## No backfill, and the honest reason

  The 268 existing rows CANNOT be classified retroactively. The
  demotion left no durable trace anywhere — it emitted telemetry and
  dropped the key at `classify_and_enqueue/4` — so any backfill would be
  guessing, and a guessed value here is worse than a NULL because it
  reads as measured. `NULL` on a pre-existing row means "unknown, this
  row predates the column", which is the truth.

  Reversible: `add/3` inverts to `remove/1` under `change/0`.
  """

  def change do
    alter table(:meeting_candidates) do
      # The intent the evidence gate downgraded to `off_topic`, or NULL
      # when this classification is the model's own answer. See moduledoc.
      add(:demoted_from, :string)
    end
  end
end
