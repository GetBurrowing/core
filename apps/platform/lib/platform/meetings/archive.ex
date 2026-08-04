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

  `Platform.Meetings.list_all_meetings/0` is deliberately not reused here: it
  is unscoped (it carries its own `TODO(scope)`) and calling it from a
  viewer-facing search would ship a cross-tenant read.
  """

  import Ecto.Query

  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy
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

  @type result :: %{
          matches: [entry()],
          others: [entry()],
          total: non_neg_integer(),
          matched: non_neg_integer(),
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
  """
  @spec search(map() | nil, keyword()) :: result()
  def search(viewer, opts \\ []) do
    query_text = normalize_query(Keyword.get(opts, :query))
    types = normalize_types(Keyword.get(opts, :types))
    limit = normalize_limit(Keyword.get(opts, :limit))
    offset = normalize_offset(Keyword.get(opts, :offset))

    scoped = scoped_query(viewer, opts)

    if query_text == "" do
      blank_result(scoped, query_text, limit, offset)
    else
      queried_result(scoped, query_text, types, limit, offset)
    end
  end

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
