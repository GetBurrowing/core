defmodule Platform.Meetings.Archive do
  @moduledoc """
  Read model behind the meetings index's **archive** half — the meetings that
  are over (`ended` or `cancelled`), searched by text and ranked by relevance
  (task `019fb954-c848`).

  `scheduled` and `live` meetings are deliberately out of scope here. They
  belong to the calendar half of the index, which asks a different question
  ("what is coming up?") and orders by intended time, not by relevance.

  ## The result is a PARTITION, not a filter

  `search/2` never removes an in-scope meeting from its answer. It splits the
  in-scope set in two:

    * `:matches` — meetings whose text matched the query, most relevant first;
    * `:others` — every other in-scope meeting, most recent first.

  The archive UI renders both, the second dimmed under an "Also in this range,
  no match" heading. A reader who searched *bucket policy* and is looking at
  three hits still wants to see that there were forty other meetings in the
  range — a filtered list silently deletes that context, and with it the only
  cue that the query was too narrow. So the ordering below is a ranking of the
  matched partition, not a `WHERE` clause over the whole archive.

  A blank query is the un-queried archive: `:matches` is empty, `:others`
  carries everything. That is a **different state** from a query that matched
  nothing, and the renderer says different things about them ("47 meetings"
  vs. "No matches for *quokka* — 47 meetings in this range"). Both states
  produce `matched: 0` and the same two lists, so the result map also carries
  `:query` — the normalised query it answered — and a caller can tell them
  apart from the return value alone rather than having to remember what it
  passed in.

  ## Ranking is the feature, and it must not decay into recency

  Each candidate is scored with `ts_rank_cd/2` over the union of every search
  vector reachable from the meeting, against
  `websearch_to_tsquery('english', query)`.

  `websearch_to_tsquery` rather than `plainto_tsquery` because the input comes
  from a search box: quoted phrases, `or`, and a leading `-` for negation all
  behave the way a reader who has used a search engine expects, and malformed
  input yields an empty query instead of raising.

  `:matches` orders `desc: score, desc: ended_at`. **`ended_at` is a
  tie-break only.** Promoting it to the primary key turns the feature into a
  reverse-chronological list with a keyword filter bolted on, which is the
  thing the two-section design exists to avoid. `:others` has no score to sort
  on and orders `desc: coalesce(ended_at, cancelled_at)` — a cancelled meeting
  never ran, so its `ended_at` is `NULL` and its position in the archive is
  the moment it was called off.

  ## What is searched, and how it is weighted

  | Source | Weight | Column |
  | --- | --- | --- |
  | Meeting name | `A` | `meetings.search_vector` (stored) |
  | Canvas titles | `B` | `chat_canvases.title_search_vector` (stored) |
  | Action-item titles | `B` | computed per query — see below |
  | Transcript summary | `C` | `meeting_transcripts.search_vector` (stored) |
  | Transcript segments | `D` | `meeting_transcripts.search_vector` (stored) |

  The meeting **name is always searched**. It is the meeting's own label, not
  one of its artifacts, so no `:types` chip removes it — `:types` selects
  which *artifacts* are searched alongside it.

  `:summaries` and `:transcripts` share one stored column (stage 1 packed the
  summary at `C` and the segment text at `D` into
  `meeting_transcripts.search_vector`). When both are selected — the default —
  that column is read as-is. When exactly one is selected the corresponding
  half is recomputed at query time with `setweight/2`, which is unindexed but
  only pays that cost on a narrowed filter.

  ### Action-item titles are searched but NOT indexed

  Action items are `tasks` rows reached two hops from the meeting: meeting →
  `chat_canvases` in its chat space → `tasks` whose
  `metadata->>'source_canvas_id'` is that canvas. Their titles are turned into
  a `tsvector` at query time, at weight `B` (an action item is a deliberate
  label of one artifact, exactly like the canvas title it came from).

  There is no generated column on `tasks` because `tasks` is not this task's
  to change — a `tsvector` column there is a table rewrite on the busiest
  table in the schema and belongs to whoever owns it. The consequence is
  honest: the action-item half of the score cannot use a GIN index and is
  evaluated per candidate row.

  Relatedly, and for the same ownership reason, there is **no `meeting_id`
  column on `tasks`**. The two-hop join through the canvas is the only link
  that exists, and it is the one `Platform.Meetings.Triage` already uses.

  ## Join keys — the wrong ones look right

    * canvases have no FK to a meeting:
      `chat_canvases.space_id == meetings.chat_space_id`, `deleted_at IS NULL`;
    * transcripts join on `meeting_transcripts.space_id ==
      meetings.chat_space_id`. **Not** `meeting_transcripts.room_id`, which
      holds the LiveKit room identifier rather than a `meetings.id` — that
      join matches nothing, and every ranking assertion above it then passes
      vacuously on an empty candidate set.

  ## Cost

  The per-meeting vector is assembled from correlated sub-selects, so the GIN
  indexes cannot serve the outer match. That is inherent to partitioning
  rather than filtering: `:others` needs every in-scope row evaluated anyway,
  so there is no candidate set for an index to narrow. The scan is bounded by
  the viewer's own orgs, and further by `:project_id` / `:person_id` when the
  caller supplies them.

  The sub-selects concatenate their rows as `tsvector::text` and cast the
  result back, because Postgres ships no `tsvector` aggregate. The text form
  round-trips lexemes and their weights exactly; positions within one
  concatenated group are not renumbered, which can only affect cover density
  between two artifacts of the same kind, never the weight signal the
  ordering depends on.

  ## Authorization

  Scoping mirrors `Platform.Meetings.fetch_meeting_for_user/2`: join
  `Platform.Tasks.Project` and require its `org_id` to be one the viewer holds
  an `org_memberships` row for, with `Platform.Tenancy.fabrikam_admin?/1` seeing
  everything. Like that function this is org isolation, not project isolation
  — there is no `project_members` table in this codebase.

  It is also hand-rolled rather than routed through `Platform.Tenancy.scope/3`
  for exactly the reason that function documents: `Tenancy.visibility/1`
  bypasses on root membership at ANY role, this bypasses on root **admin**,
  and every OIDC signup holds a plain root membership. See the "Why this is
  still hand-rolled" section on `Platform.Meetings.fetch_meeting_for_user/2`.

  `Platform.Meetings.list_all_meetings_unscoped/0` is deliberately not reused here: it
  is unscoped (it carries its own `TODO(scope)`) and calling it from a
  viewer-facing search would ship a cross-tenant read.

  ## Artifacts — `artifacts_for/2`

  `search/2` answers *which* meetings; `artifacts_for/2` answers *what came
  out of them*, which is the row's primary content in the design. It is a
  second call rather than a wider `select` because the chips are one-to-many
  in three different directions at once — a row-per-meeting query that
  carried them would multiply the archive page by the cross product of its
  canvases, transcripts and action items.

  ### A canvas chip is a REVISION SPAN, not a title

  The design's chips read `Bucket policy canvas · rev 14` and `Bucket policy
  canvas · rev 1–3`: the *same* canvas hanging off *two* meetings a month
  apart, each labelled with the revisions that meeting produced. That is the
  whole point of the archive — you remember the artifact, not the date, and
  the span is what tells you which meeting to open.

  So a canvas's contribution to a meeting is
  `min(revision)..max(revision)` over `canvas_versions` rows whose
  `written_at` falls inside that meeting's **actual** window
  `[started_at, ended_at]`. A canvas sitting in the meeting's space with no
  version written during it contributes **no chip**: it was not touched here,
  and listing it would attribute someone else's work to this meeting.

  Two consequences worth stating because they look like bugs otherwise:

    * a cancelled meeting has a `NULL` `started_at`, so every window
      comparison is `NULL`, so it has no canvas chips at all — which is
      exactly what the design shows for a meeting that never ran;
    * revisions written *between* two meetings belong to neither.

  The span is rendered with an EN DASH (`–`, U+2013), not a hyphen, to match
  the design.

  ### The other three chips

    * **Summary** — the `meeting_transcripts` row for the meeting's chat
      space has a non-`NULL`, non-blank `summary`.
    * **Transcript** — that same row has a non-empty `segments` array. Both
      chips resolve from one row and are independent of each other: a
      transcript that is still recording has segments and no summary, and a
      summary imported without its source has the converse.
    * **Action items** — a *count*, `3 action items` (`3 actions` on mobile,
      hence the separate `:short_label`), over the same two-hop
      canvas → `tasks.metadata->>'source_canvas_id'` join `search/2` uses.

  ### Join keys, restated

  Same trap as above, and it fails silently in a worse way here: canvases are
  `chat_canvases.space_id == meetings.chat_space_id` with
  `deleted_at IS NULL`, and transcripts are `meeting_transcripts.space_id ==
  meetings.chat_space_id`. **Not** `meeting_transcripts.room_id` — that
  column holds a LiveKit room identifier, and its schema type (`:string`)
  does not even agree with its migration type. Joining on it yields the empty
  set, and an empty set satisfies every "this artifact is absent" assertion.

  ### Batching

  Four queries for a whole page, independent of how many rows are on it — one
  per chip family plus one for the row context. The page's ids are pushed
  into each as an `IN` list rather than each row fetching its own artifacts.
  """

  import Ecto.Query

  alias Platform.Chat.Canvas
  alias Platform.Chat.Canvas.Version, as: CanvasVersion
  alias Platform.Chat.Participant, as: ChatParticipant
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.Transcript
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tasks.Task, as: TaskRecord
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  @archived_statuses ~w(ended cancelled)
  @types [:canvases, :summaries, :action_items, :transcripts]
  @default_limit 50

  @type entry :: %{
          id: binary(),
          slug: String.t(),
          name: String.t(),
          status: String.t(),
          project_id: binary(),
          chat_space_id: binary(),
          started_at: DateTime.t() | nil,
          ended_at: DateTime.t() | nil,
          cancelled_at: DateTime.t() | nil,
          scheduled_start_at: DateTime.t() | nil,
          scheduled_end_at: DateTime.t() | nil,
          score: float()
        }

  @type chip ::
          %{
            required(:type) => :canvas,
            required(:canvas_id) => binary(),
            required(:title) => String.t(),
            required(:revision_min) => pos_integer(),
            required(:revision_max) => pos_integer(),
            required(:revision_label) => String.t(),
            required(:label) => String.t()
          }
          | %{required(:type) => :summary | :transcript, required(:label) => String.t()}
          | %{
              required(:type) => :action_items,
              required(:count) => pos_integer(),
              required(:label) => String.t(),
              required(:short_label) => String.t()
            }

  @type artifacts :: %{
          chips: [chip()],
          duration_minutes: non_neg_integer() | nil,
          host_name: String.t() | nil,
          attendee_count: non_neg_integer(),
          project_path: String.t(),
          cancelled_by_name: String.t() | nil,
          cancellation_notified_at: DateTime.t() | nil
        }

  @type result :: %{
          matches: [entry()],
          others: [entry()],
          total: non_neg_integer(),
          matched: non_neg_integer(),
          unfiltered_total: non_neg_integer(),
          type_counts: %{atom() => non_neg_integer()},
          query: String.t()
        }

  @doc """
  The artifact types `:types` may select. The meeting name is not among them
  — it is always searched.
  """
  @spec types() :: [atom()]
  def types, do: @types

  @doc """
  The statuses the archive covers. `scheduled` and `live` are the calendar's.
  """
  @spec archived_statuses() :: [String.t()]
  def archived_statuses, do: @archived_statuses

  @doc """
  Search the archive as `viewer`, returning both partitions.

  ## Options

    * `:query` — the search box's text. Blank (or absent) means "no query":
      `:matches` is empty and `:others` is the whole in-scope set.
    * `:types` — subset of `types/0` naming which artifacts to search
      alongside the meeting name. Absent or empty means all of them.
    * `:person_id` — a user id; narrows to meetings whose chat space that
      user participates in.
    * `:project_id` — narrows to one project.
    * `:limit` / `:offset` — page over the two partitions as one continuous
      stream: `:matches` first, then `:others`. A page can therefore contain
      the tail of `:matches` and the head of `:others`, which is exactly how
      the page scrolls.

  `:total` counts the in-scope set regardless of query, `:matched` counts the
  matched partition (not the page), and `:type_counts` counts matching
  meetings per artifact type — computed for **every** type, not just the
  selected ones, so an unselected filter chip can still show what it would
  reveal.

  `:unfiltered_total` counts what the viewer could see with NO query and NO
  `:person_id` / `:project_id` — the archive "at all". It exists because
  "you have nothing archived" and "your filters matched nothing" are two
  different answers with two different next actions, and `:total` cannot
  tell them apart: it already has the person and project filters applied, so
  a filter that excludes everything drives it to zero exactly as an empty
  archive does. The extra count is only issued when one of those two filters
  is actually set; the query narrows `:matches`, never the in-scope set.
  """
  @spec search(map() | nil, keyword()) :: result()
  def search(viewer, opts \\ []) do
    query_text = normalize_query(Keyword.get(opts, :query))
    types = normalize_types(Keyword.get(opts, :types))
    limit = normalize_limit(Keyword.get(opts, :limit))
    offset = normalize_offset(Keyword.get(opts, :offset))

    scoped = scoped_query(viewer, opts)

    result =
      if query_text == "" do
        blank_result(scoped, query_text, limit, offset)
      else
        queried_result(scoped, query_text, types, limit, offset)
      end

    Map.put(result, :unfiltered_total, unfiltered_total(viewer, opts, result.total))
  end

  defp unfiltered_total(viewer, opts, scoped_total) do
    if Keyword.get(opts, :person_id) || Keyword.get(opts, :project_id) do
      Repo.aggregate(scoped_query(viewer, []), :count, :id)
    else
      scoped_total
    end
  end

  @doc """
  The chip payload and row context for a whole page of archive rows, keyed by
  meeting id.

  `meetings` is the page — `search/2` entries, `Platform.Meetings.Meeting`
  structs, or bare ids, mixed freely. `viewer` re-scopes: ids reach this
  function from a `params` map by way of the page that rendered them, and a
  read that trusted them would be a cross-tenant leak one stale URL away.
  A meeting the viewer may not see, or one that is not archived, is simply
  absent from the result — callers must not assume a key exists.

  Each value is:

    * `:chips` — canvases (by title) with their revision span, then `Summary`,
      then `Transcript`, then the action-item count. Empty for a meeting that
      produced nothing, which is a real and renderable state.
    * `:duration_minutes` — whole minutes between the actuals, `nil` when the
      meeting never ran.
    * `:host_name` — the host participant's display name, `nil` if unset.
    * `:attendee_count` — distinct participants of the meeting's chat space.
    * `:project_path` — `"<org> / <project>"`, the row's trailing context.
    * `:cancelled_by_name` — the display name on `cancelled_by_participant_id`,
      `nil` for a meeting that was not cancelled AND for one whose canceller's
      participant row is gone (the FK nilifies).
    * `:cancellation_notified_at` — when the cancellation fan-out ran, `nil`
      when it did not. A renderer must not claim a notification on a `nil`.

  See the moduledoc for why a canvas chip carries a revision span and why an
  untouched canvas contributes nothing.
  """
  @spec artifacts_for(map() | nil, [map() | binary()]) :: %{binary() => artifacts()}
  def artifacts_for(viewer, meetings) do
    case meeting_ids(meetings) do
      [] ->
        %{}

      ids ->
        scoped = where(scoped_query(viewer, []), [m], m.id in ^ids)

        canvases = canvas_chips(scoped)
        transcripts = transcript_chips(scoped)
        actions = action_item_chips(scoped)

        scoped
        |> row_context()
        |> Map.new(fn {id, context} ->
          chips =
            Map.get(canvases, id, []) ++
              Map.get(transcripts, id, []) ++ Map.get(actions, id, [])

          {id, Map.put(context, :chips, chips)}
        end)
    end
  end

  defp meeting_ids(meetings) when is_list(meetings) do
    meetings
    |> Enum.map(fn
      %{id: id} -> id
      id when is_binary(id) -> id
    end)
    |> Enum.filter(&Platform.UUID.valid?/1)
    |> Enum.uniq()
  end

  defp meeting_ids(_), do: []

  # ── Chips ─────────────────────────────────────────────────────────────────

  # One row per (meeting, canvas) pair that has at least one version written
  # DURING the meeting. The window predicate lives in the join rather than a
  # `where`, so a canvas with no in-window version drops out of the inner
  # join entirely instead of surfacing as a chip with a NULL span.
  defp canvas_chips(scoped) do
    scoped
    |> join(:inner, [m], c in Canvas, on: c.space_id == m.chat_space_id and is_nil(c.deleted_at))
    |> join(:inner, [m, _p, c], v in CanvasVersion,
      on:
        v.canvas_id == c.id and v.written_at >= m.started_at and
          v.written_at <= m.ended_at
    )
    |> group_by([m, _p, c], [m.id, c.id, c.title])
    |> order_by([_m, _p, c], asc: c.title, asc: c.id)
    |> select([m, _p, c, v], %{
      meeting_id: m.id,
      canvas_id: c.id,
      title: c.title,
      revision_min: min(v.revision),
      revision_max: max(v.revision)
    })
    |> Repo.all()
    |> Enum.group_by(& &1.meeting_id, &canvas_chip/1)
  end

  defp canvas_chip(row) do
    title = canvas_title(row.title)
    revision_label = revision_label(row.revision_min, row.revision_max)

    %{
      type: :canvas,
      canvas_id: row.canvas_id,
      title: title,
      revision_min: row.revision_min,
      revision_max: row.revision_max,
      revision_label: revision_label,
      label: title <> " · " <> revision_label
    }
  end

  defp canvas_title(title) when is_binary(title) do
    case String.trim(title) do
      "" -> "Untitled canvas"
      trimmed -> trimmed
    end
  end

  defp canvas_title(_), do: "Untitled canvas"

  # `rev 14` for one revision, `rev 1–3` for a span. The separator is an EN
  # DASH (U+2013) — a hyphen here would be a different string from the one the
  # design specifies, and the whole chip is a string the reader scans.
  defp revision_label(revision, revision), do: "rev #{revision}"
  defp revision_label(min_revision, max_revision), do: "rev #{min_revision}–#{max_revision}"

  # Both chips come from the SAME transcript row and are computed
  # independently: `summary` present but `segments` empty is a real state (the
  # summariser ran on an externally-supplied text), and so is its converse (a
  # recording that never got summarised).
  defp transcript_chips(scoped) do
    scoped
    |> join(:inner, [m], t in Transcript, on: t.space_id == m.chat_space_id)
    |> group_by([m], m.id)
    |> select([m, _p, t], %{
      meeting_id: m.id,
      summary?: fragment("bool_or(? IS NOT NULL AND btrim(?) <> '')", t.summary, t.summary),
      transcript?: fragment("bool_or(jsonb_array_length(?) > 0)", t.segments)
    })
    |> Repo.all()
    |> Map.new(fn row ->
      chips =
        [
          {row.summary?, %{type: :summary, label: "Summary"}},
          {row.transcript?, %{type: :transcript, label: "Transcript"}}
        ]
        |> Enum.filter(fn {present?, _chip} -> present? end)
        |> Enum.map(fn {_present?, chip} -> chip end)

      {row.meeting_id, chips}
    end)
  end

  # The two-hop join `search/2` documents: there is no `meeting_id` on
  # `tasks`, so an action item is reached through the canvas that produced it.
  # `count(distinct)` because a task could in principle be reached twice if
  # two canvases in the space claimed it.
  defp action_item_chips(scoped) do
    scoped
    |> join(:inner, [m], c in Canvas, on: c.space_id == m.chat_space_id and is_nil(c.deleted_at))
    |> join(:inner, [m, _p, c], ai in TaskRecord,
      on:
        fragment("(? ->> 'source_canvas_id')", ai.metadata) == fragment("?::text", c.id) and
          is_nil(ai.deleted_at)
    )
    |> group_by([m], m.id)
    |> select([m, _p, _c, ai], %{meeting_id: m.id, count: count(ai.id, :distinct)})
    |> Repo.all()
    |> Map.new(fn %{meeting_id: id, count: count} -> {id, action_item_chips_for(count)} end)
  end

  defp action_item_chips_for(0), do: []

  defp action_item_chips_for(count) do
    [
      %{
        type: :action_items,
        count: count,
        label: "#{count} action #{pluralize("item", count)}",
        short_label: "#{count} #{pluralize("action", count)}"
      }
    ]
  end

  defp pluralize(word, 1), do: word
  defp pluralize(word, _count), do: word <> "s"

  # ── Row context ───────────────────────────────────────────────────────────

  # The subtitle the design renders under the meeting name:
  # "52 min · hosted by Rowan · 5 attended · Suite / Control Center".
  #
  # The attendee count is a correlated sub-select rather than a fifth join so
  # it cannot multiply this query's rows — it must stay one row per meeting,
  # since it is the map the other three fold into.
  #
  # The cancellation attribution rides here rather than on `search/2`'s entry
  # for the same reason the host name does: it is one more left join on
  # `chat_participants`, and the page pays for it ONCE instead of once per
  # cancelled row. A `Repo.preload(:cancelled_by_participant)` would need a
  # `%Meeting{}` per row, which the archive deliberately does not load.
  #
  # `cancelled_by_participant_id` is NILIFIED rather than cascaded when the
  # participant row goes, so a NULL `display_name` here is a real and expected
  # state — "Cancelled" with no attribution — not a missing join.
  defp row_context(scoped) do
    scoped
    |> join(:left, [m], hp in ChatParticipant, on: hp.id == m.host_participant_id)
    |> join(:left, [_m, p], o in Org, on: o.id == p.org_id)
    |> join(:left, [m], cbp in ChatParticipant, on: cbp.id == m.cancelled_by_participant_id)
    |> select([m, p, hp, o, cbp], %{
      id: m.id,
      started_at: m.started_at,
      ended_at: m.ended_at,
      host_name: hp.display_name,
      project_name: p.name,
      org_name: o.name,
      cancelled_by_name: cbp.display_name,
      cancellation_notified_at: m.cancellation_notified_at,
      attendee_count:
        fragment(
          """
          (SELECT count(DISTINCT (cp.participant_type, cp.participant_id))
           FROM chat_participants AS cp
           WHERE cp.space_id = ?)\
          """,
          m.chat_space_id
        )
    })
    |> Repo.all()
    |> Map.new(fn row ->
      {row.id,
       %{
         duration_minutes: duration_minutes(row.started_at, row.ended_at),
         host_name: row.host_name,
         attendee_count: row.attendee_count,
         project_path: project_path(row.org_name, row.project_name),
         cancelled_by_name: row.cancelled_by_name,
         cancellation_notified_at: row.cancellation_notified_at
       }}
    end)
  end

  # Whole minutes, truncated. A meeting that never ran has no duration at all
  # — `0` would claim it ran for under a minute.
  defp duration_minutes(%DateTime{} = started_at, %DateTime{} = ended_at) do
    started_at |> DateTime.diff(ended_at) |> abs() |> div(60)
  end

  defp duration_minutes(_started_at, _ended_at), do: nil

  defp project_path(nil, project_name), do: project_name || ""
  defp project_path(org_name, nil), do: org_name
  defp project_path(org_name, project_name), do: org_name <> " / " <> project_name

  # ── The two answer shapes ─────────────────────────────────────────────────

  # No query: nothing is scored, so the four correlated sub-selects are never
  # built. This is the archive's default view, so it is also the one worth
  # not paying for.
  defp blank_result(scoped, query_text, limit, offset) do
    total = Repo.aggregate(scoped, :count, :id)

    %{
      matches: [],
      others: others_page(scoped, nil, limit, offset),
      total: total,
      matched: 0,
      type_counts: Map.new(@types, &{&1, 0}),
      query: query_text
    }
  end

  defp queried_result(scoped, query_text, types, limit, offset) do
    vector = searchable_vector(types)
    match = match_dynamic(vector, query_text)
    counts = counts(scoped, match, query_text)

    matched = counts.matched

    # `:matches` and `:others` are one stream for paging purposes. Clamping
    # here rather than issuing two independently-offset queries is what keeps
    # a page that straddles the boundary from either repeating or dropping
    # rows at the seam.
    match_offset = min(offset, matched)
    match_limit = max(min(limit, matched - match_offset), 0)
    others_offset = max(offset - matched, 0)
    others_limit = limit - match_limit

    %{
      matches: matches_page(scoped, vector, match, query_text, match_limit, match_offset),
      others: others_page(scoped, match, others_limit, others_offset),
      total: counts.total,
      matched: matched,
      type_counts: Map.take(counts, @types),
      query: query_text
    }
  end

  # ── Pages ─────────────────────────────────────────────────────────────────

  defp matches_page(_scoped, _vector, _match, _query_text, 0, _offset), do: []

  defp matches_page(scoped, vector, match, query_text, limit, offset) do
    score = score_dynamic(vector, query_text)

    scoped
    |> where(^match)
    |> order_by(^[desc: score, desc: dynamic([m], m.ended_at)])
    |> limit(^limit)
    |> offset(^offset)
    |> select(^Map.put(entry_fields(), :score, score))
    |> Repo.all()
  end

  defp others_page(_scoped, _match, limit, _offset) when limit <= 0, do: []

  defp others_page(scoped, match, limit, offset) do
    scoped
    |> exclude_matches(match)
    |> order_by(^[desc: dynamic([m], coalesce(m.ended_at, m.cancelled_at))])
    |> limit(^limit)
    |> offset(^offset)
    |> select(^entry_fields())
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :score, 0.0))
  end

  defp exclude_matches(scoped, nil), do: scoped
  defp exclude_matches(scoped, match), do: where(scoped, ^dynamic(not (^match)))

  # ── Counts ────────────────────────────────────────────────────────────────

  # One aggregate pass: the in-scope total, the matched count, and a matched
  # count per artifact type. The per-type counts are deliberately independent
  # of `:types` — a chip that is off still shows how many meetings turning it
  # on would surface.
  defp counts(scoped, match, query_text) do
    fields =
      Enum.reduce(@types, %{total: dynamic([m], count(m.id)), matched: count_where(match)}, fn
        type, acc ->
          type_match = match_dynamic(type_vector(type), query_text)
          Map.put(acc, type, count_where(type_match))
      end)

    scoped
    |> select(^fields)
    |> Repo.one()
  end

  defp count_where(condition) do
    dynamic(fragment("count(*) FILTER (WHERE ?)", ^condition))
  end

  # ── Scope ─────────────────────────────────────────────────────────────────

  defp scoped_query(viewer, opts) do
    from(m in Meeting,
      join: p in Project,
      on: p.id == m.project_id,
      where: m.status in ^@archived_statuses
    )
    |> narrow_to_viewer_orgs(viewer)
    |> maybe_filter_project(Keyword.get(opts, :project_id))
    |> maybe_filter_person(Keyword.get(opts, :person_id))
  end

  # NOT `Tenancy.scope/3`, deliberately — see "Authorization" in the
  # moduledoc. This mirrors `Meetings.fetch_meeting_for_user/2`'s
  # `fabrikam_admin?/1` bypass, which is narrower than `visibility/1`'s
  # `root_member?/1`. Converting widens who can read the archive.
  defp narrow_to_viewer_orgs(query, viewer) do
    if Tenancy.fabrikam_admin?(viewer) do
      query
    else
      from([_m, p] in query, where: p.org_id in subquery(viewer_org_ids(viewer)))
    end
  end

  defp viewer_org_ids(%{id: user_id}) when is_binary(user_id) do
    from(om in OrgMembership, where: om.user_id == ^user_id, select: om.org_id)
  end

  # No identifiable viewer is no memberships — not "everything". Expressed as
  # an empty subquery rather than an early return so the org narrowing stays
  # a single clause on a single code path.
  defp viewer_org_ids(_viewer) do
    from(om in OrgMembership, where: fragment("false"), select: om.org_id)
  end

  defp maybe_filter_project(query, nil), do: query

  defp maybe_filter_project(query, project_id) do
    if Platform.UUID.valid?(project_id) do
      where(query, [m], m.project_id == ^project_id)
    else
      selects_nothing(query)
    end
  end

  defp maybe_filter_person(query, nil), do: query

  defp maybe_filter_person(query, person_id) do
    if Platform.UUID.valid?(person_id) do
      spaces =
        from(cp in Platform.Chat.Participant,
          where: cp.participant_type == "user" and cp.participant_id == ^person_id,
          select: cp.space_id
        )

      where(query, [m], m.chat_space_id in subquery(spaces))
    else
      selects_nothing(query)
    end
  end

  # Both filter ids reach this module straight off a LiveView `params` map,
  # and `where: m.project_id == ^value` raises `Ecto.Query.CastError` on a
  # malformed one exactly as `Repo.get/2` would — hence the
  # `Platform.UUID.valid?/1` guards above.
  #
  # A malformed id narrows to nothing rather than dropping the filter. An
  # unparseable `?project=` in the URL must not silently widen the archive to
  # every project the viewer can see: failing open on an authorization-shaped
  # filter is how a "no results" page becomes a directory listing.
  defp selects_nothing(query), do: where(query, fragment("false"))

  # ── Scoring ───────────────────────────────────────────────────────────────

  defp score_dynamic(vector, query_text) do
    dynamic(fragment("ts_rank_cd(?, websearch_to_tsquery('english', ?))", ^vector, ^query_text))
  end

  defp match_dynamic(vector, query_text) do
    dynamic(fragment("(? @@ websearch_to_tsquery('english', ?))", ^vector, ^query_text))
  end

  # The meeting's own name is always part of the vector; `types` only adds
  # artifacts to it.
  defp searchable_vector(types) do
    types
    |> vector_parts()
    |> Enum.reduce(meeting_name_vector(), fn part, acc ->
      dynamic(fragment("(? || ?)", ^acc, ^part))
    end)
  end

  # `:summaries` and `:transcripts` share one stored column. Selecting both
  # reads it directly; selecting one recomputes that half at query time.
  defp vector_parts(types) do
    canvases = if :canvases in types, do: [type_vector(:canvases)], else: []
    actions = if :action_items in types, do: [type_vector(:action_items)], else: []

    transcripts =
      case {:summaries in types, :transcripts in types} do
        {true, true} -> [stored_transcript_vector()]
        {true, false} -> [type_vector(:summaries)]
        {false, true} -> [type_vector(:transcripts)]
        {false, false} -> []
      end

    canvases ++ transcripts ++ actions
  end

  defp meeting_name_vector do
    dynamic([m], fragment("coalesce(?, ''::tsvector)", field(m, :search_vector)))
  end

  defp type_vector(:canvases) do
    dynamic(
      [m],
      fragment(
        """
        coalesce((
          SELECT string_agg(cv.title_search_vector::text, ' ')
          FROM chat_canvases AS cv
          WHERE cv.space_id = ? AND cv.deleted_at IS NULL
        )::tsvector, ''::tsvector)\
        """,
        m.chat_space_id
      )
    )
  end

  defp type_vector(:summaries) do
    dynamic(
      [m],
      fragment(
        """
        coalesce((
          SELECT string_agg(
                   setweight(to_tsvector('english', coalesce(mt.summary, '')), 'C')::text, ' ')
          FROM meeting_transcripts AS mt
          WHERE mt.space_id = ?
        )::tsvector, ''::tsvector)\
        """,
        m.chat_space_id
      )
    )
  end

  defp type_vector(:transcripts) do
    dynamic(
      [m],
      fragment(
        """
        coalesce((
          SELECT string_agg(
                   setweight(
                     to_tsvector(
                       'english',
                       coalesce(jsonb_path_query_array(mt.segments, '$[*].text')::text, '')
                     ),
                     'D'
                   )::text,
                   ' ')
          FROM meeting_transcripts AS mt
          WHERE mt.space_id = ?
        )::tsvector, ''::tsvector)\
        """,
        m.chat_space_id
      )
    )
  end

  defp type_vector(:action_items) do
    dynamic(
      [m],
      fragment(
        """
        coalesce((
          SELECT string_agg(
                   setweight(to_tsvector('english', coalesce(ai.title, '')), 'B')::text, ' ')
          FROM chat_canvases AS cv
          JOIN tasks AS ai ON (ai.metadata ->> 'source_canvas_id') = cv.id::text
          WHERE cv.space_id = ? AND cv.deleted_at IS NULL AND ai.deleted_at IS NULL
        )::tsvector, ''::tsvector)\
        """,
        m.chat_space_id
      )
    )
  end

  defp stored_transcript_vector do
    dynamic(
      [m],
      fragment(
        """
        coalesce((
          SELECT string_agg(mt.search_vector::text, ' ')
          FROM meeting_transcripts AS mt
          WHERE mt.space_id = ?
        )::tsvector, ''::tsvector)\
        """,
        m.chat_space_id
      )
    )
  end

  # ── Shapes ────────────────────────────────────────────────────────────────

  defp entry_fields do
    %{
      id: dynamic([m], m.id),
      slug: dynamic([m], m.slug),
      name: dynamic([m], m.name),
      status: dynamic([m], m.status),
      project_id: dynamic([m], m.project_id),
      chat_space_id: dynamic([m], m.chat_space_id),
      started_at: dynamic([m], m.started_at),
      ended_at: dynamic([m], m.ended_at),
      cancelled_at: dynamic([m], m.cancelled_at),
      scheduled_start_at: dynamic([m], m.scheduled_start_at),
      scheduled_end_at: dynamic([m], m.scheduled_end_at)
    }
  end

  # ── Option normalisation ──────────────────────────────────────────────────

  defp normalize_query(nil), do: ""
  defp normalize_query(query) when is_binary(query), do: String.trim(query)
  defp normalize_query(_), do: ""

  defp normalize_types(nil), do: @types

  defp normalize_types(types) when is_list(types) do
    case Enum.filter(@types, &(&1 in types)) do
      [] -> @types
      selected -> selected
    end
  end

  defp normalize_types(_), do: @types

  defp normalize_limit(nil), do: @default_limit
  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: limit
  defp normalize_limit(_), do: @default_limit

  defp normalize_offset(offset) when is_integer(offset) and offset > 0, do: offset
  defp normalize_offset(_), do: 0
end
