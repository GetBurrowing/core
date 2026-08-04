defmodule Platform.Repo.Migrations.AddMeetingSearchVectors do
  use Ecto.Migration

  @moduledoc """
  Task `019fb954-c848`: weighted full-text search vectors over the meeting
  archive's text artifacts.

  The archive is search-first — a reader arrives with a phrase, not with a
  date — so the three tables that hold a meeting's words each gain a
  `tsvector` column and a GIN index. Ranking then falls out of
  `ts_rank_cd/2`, which reads the weight letters below, instead of every
  call site inventing its own scoring.

  ## Why STORED GENERATED columns

  Every expression here is single-table and IMMUTABLE, so Postgres can
  maintain the vector itself on write. That rules out the two alternatives
  and their failure modes:

    * a trigger has to be kept in step with the column list by hand, and a
      missed `UPDATE OF` clause leaves stale vectors that nothing detects;
    * a materialized view needs a refresh path, and a refresh path that is
      not run is a search index that silently stops seeing new meetings.

  A generated column has neither — there is no refresh to forget.

  ## What is searched, and with what weight

    * `A` — `meetings.name`. The strongest signal: a person naming a
      meeting is labelling the whole conversation.
    * `B` — `chat_canvases.title`. A canvas title is a deliberate label
      too, but of one artifact rather than the whole meeting.
    * `C` — `meeting_transcripts.summary`. Generated prose about the
      meeting, so it is about the right subject but nobody chose the words.
    * `D` — the text of `meeting_transcripts.segments`, extracted with
      `jsonb_path_query_array(segments, '$[*].text')`. Raw speech: the
      largest surface and the noisiest, so it ranks last.

  ## What is deliberately NOT searched

    * **Canvas document bodies.** `chat_canvases.document` is a node tree
      whose text lives at different prop keys per node kind; the only
      reliable extractor is `Platform.Chat.Canvas.MarkdownExporter`, which
      is application code and cannot appear inside an IMMUTABLE generated
      expression. Titles carry the signal the settled archive design ranks
      on, so the body is not needed to make the design work.
    * **Action-item task titles.** Those are reached by a join from the
      meeting's chat space through to `tasks`, and adding a generated
      column to `tasks` is outside this task's ownership.

  ## Join keys the readers of these columns must use

  Recorded here because both have a wrong-looking-right alternative:

    * canvases have **no** FK to a meeting —
      `chat_canvases.space_id == meetings.chat_space_id`, filtered on
      `deleted_at IS NULL`;
    * transcripts likewise join on
      `meeting_transcripts.space_id == meetings.chat_space_id`. **Not** on
      `meeting_transcripts.room_id`, which holds the LiveKit room
      identifier rather than a `meetings.id`; that join returns nothing and
      every ranking assertion above it passes vacuously on empty input.

  ## No backfill

  A `STORED` generated column is computed for every existing row when the
  column is added, so there is nothing to backfill. The table rewrite is
  the cost of the migration.
  """

  def change do
    alter table(:meetings) do
      add(:search_vector, :tsvector,
        generated: """
        ALWAYS AS (
          setweight(to_tsvector('english', coalesce(name, '')), 'A')
        ) STORED\
        """
      )
    end

    create(index(:meetings, [:search_vector], using: :gin))

    alter table(:chat_canvases) do
      add(:title_search_vector, :tsvector,
        generated: """
        ALWAYS AS (
          setweight(to_tsvector('english', coalesce(title, '')), 'B')
        ) STORED\
        """
      )
    end

    create(index(:chat_canvases, [:title_search_vector], using: :gin))

    alter table(:meeting_transcripts) do
      add(:search_vector, :tsvector,
        generated: """
        ALWAYS AS (
          setweight(to_tsvector('english', coalesce(summary, '')), 'C') ||
          setweight(
            to_tsvector(
              'english',
              coalesce(jsonb_path_query_array(segments, '$[*].text')::text, '')
            ),
            'D'
          )
        ) STORED\
        """
      )
    end

    create(index(:meeting_transcripts, [:search_vector], using: :gin))
  end
end
