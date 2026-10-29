defmodule Platform.Meetings.MeetingBriefings do
  @moduledoc """
  Builds the after-action briefing for a concluded meeting (task
  `01a1694a-676e-7000-a653-5e1e6db65205`): one `Platform.Meetings.MeetingBriefing`
  row per meeting, shared by every attendee.

  ## What a briefing holds

  **Items** — the things the meeting produced that an attendee can act on,
  keyed by `"m" <> first 16 hex of sha256(ref)` (the same shape as
  `Platform.Memory.Insights.BriefingCard.node_key/1`, with an `m` prefix):

    * **tasks filed** — exactly `Platform.Meetings.meeting_tasks_query/1`,
      the one rule for "which tasks belong to this meeting". This module
      runs no other task query. Kind `"task"`, ref `"task:<id>"`.
    * **canvases created** — this meeting's `meeting_candidates` carrying a
      `canvas_id` whose canvas is not soft-deleted. Kind `"canvas"`, ref
      `"canvas:<id>"`.

  **Content** — rebuilt on every run and stored under the reserved key
  `"_content"`, which is not an item:

    * `"open_questions"` — accepted candidates classified `open_question`;
    * `"unfiled_action_items"` — accepted candidates classified `action_items` that
      never got a task;
    * `"transcript_url"` — `/meetings/<slug>`.

  Both candidate lists leave out a candidate closed as `retracted`,
  `duplicate` or `vetoed`: those were taken back in the meeting.

  **Summary** — complete transcripts explicitly owned by this meeting, or
  historical transcripts captured within its start/end bounds. Space-level
  completion timestamps never associate transcripts with a meeting.

  ## Delivery

  Completion callbacks and the 30-second completion sweeper recompute readiness
  from the durable captured snapshot. Delivery waits for every owned summary,
  the committed full filing ledger, and any synthesis prerequisite registered
  for that snapshot. The fallback deadline is `ended_at + 20 minutes`.
  Inbox uniqueness arbitrates each attendee's first push; later merges do not
  push. No automatic delivery runs inside a filing transaction.

  ## Reading and acting (stage 3)

  `get_for_attendee/2` is the ONLY way a caller loads a briefing for a
  person: the attendee check is in the query, so a non-attendee, a forged
  meeting id and a malformed id all answer `nil` and cannot be told apart.
  `view/2` is a pure read. `act/5` resolves one item with one of three verbs
  — `:revert`, `:confirm`, `:ask` — and writes ONE shared receipt: once an
  item has a receipt, every later act on it, by anyone, is
  `{:error, :already_resolved, briefing}` and does nothing. No receipt has an
  inverse (a declared deviation, matching the daily briefing's
  `revert`/`delete` `:no_inverse`).

  ## Synthesis findings (task 01a16974)

  An item of kind `"finding"` (ref `"finding:<id>"`, added by
  `add_finding/2`) points at a shared `Platform.Meetings.SynthesisFinding`
  row that can sit in several meetings' briefings. Its receipt is the
  FINDING's `receipt`, never this briefing's `receipts` map: `view/2` reads
  it from the finding and `act/5` writes it there, under a `FOR UPDATE` lock
  on the finding row. So one click from any briefing resolves the item in
  every briefing that carries it, and a second click from any of them is
  `{:error, :already_resolved, briefing}`. A finding item whose finding row
  no longer exists is left out of `view/2`.

  ## Pure merge

  `build/1` never removes or overwrites: an existing item key keeps its
  value, every receipt is kept as it is, and attendees are unioned. The row
  is read `FOR UPDATE` inside one transaction, so two concurrent builds
  serialise instead of racing on the merge.
  """

  import Ecto.Query

  require Logger

  alias Platform.Access.Scope
  alias Platform.Chat.Canvas
  alias Platform.Inbox
  alias Platform.Meetings
  alias Platform.Meetings.CompletionRun
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.MeetingBriefing
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Meetings.SynthesisFinding
  alias Platform.Meetings.SynthesisFindings
  alias Platform.Meetings.Transcript
  alias Platform.Repo

  @content_key "_content"
  @verbs [:revert, :confirm, :ask]
  @receipt_verbs %{revert: "reverted", confirm: "confirmed", ask: "asked"}
  @withdrawn_reasons [:retracted, :duplicate, :vetoed]

  @type build_result ::
          {:ok, MeetingBriefing.t(), %{new_keys: [String.t()], new_attendees: [binary()]}}
          | {:error, :not_concluded}

  @doc "The reserved `items` key holding rebuilt-each-run content."
  @spec content_key() :: String.t()
  def content_key, do: @content_key

  @doc """
  The item key for `ref` (`"task:<id>"`, `"canvas:<id>"`): stable across
  rebuilds and opaque.
  """
  @spec node_key(String.t()) :: String.t()
  def node_key(ref) when is_binary(ref) do
    "m" <> (:crypto.hash(:sha256, ref) |> Base.encode16(case: :lower) |> binary_part(0, 16))
  end

  @doc """
  Build, or merge into, the briefing for `meeting`.

  Returns `{:ok, briefing, %{new_keys: keys, new_attendees: ids}}`, where
  `new_keys` are item keys this run added and `new_attendees` are user ids
  this run added. A meeting whose status is not `"ended"` returns
  `{:error, :not_concluded}` and writes nothing.

  The meeting is re-read, so a stale struct cannot build a briefing for a
  meeting that is no longer (or not yet) ended.
  """
  @spec build(Meeting.t()) :: build_result()
  def build(%Meeting{id: id}) do
    case Repo.get(Meeting, id) do
      %Meeting{status: "ended"} = meeting -> do_build(meeting)
      _ -> {:error, :not_concluded}
    end
  end

  defp do_build(%Meeting{} = meeting) do
    {:ok, result} =
      Repo.transaction(fn ->
        existing = lock_row!(meeting)

        computed_items = Map.new(task_items(meeting) ++ canvas_items(meeting))
        existing_items = Map.delete(existing.items || %{}, @content_key)

        new_keys =
          computed_items
          |> Map.keys()
          |> Enum.reject(&Map.has_key?(existing_items, &1))
          |> Enum.sort()

        items =
          computed_items
          |> Map.merge(existing_items)
          |> Map.put(@content_key, content(meeting))

        existing_attendees = existing.attendee_user_ids || []
        attendees_now = Meetings.human_attendee_ids(meeting)
        new_attendees = Enum.reject(attendees_now, &(&1 in existing_attendees))

        attrs =
          %{
            items: items,
            attendee_user_ids: Enum.sort(existing_attendees ++ new_attendees),
            # Receipts are carried through unchanged — a build never writes one.
            receipts: existing.receipts || %{}
          }
          |> Map.merge(summary_attrs(meeting))

        briefing =
          existing
          |> MeetingBriefing.changeset(attrs)
          |> Repo.update!()

        {briefing, %{new_keys: new_keys, new_attendees: new_attendees}}
      end)

    {briefing, delta} = result
    {:ok, briefing, delta}
  end

  # Insert-if-absent, then lock. Inserting first (ON CONFLICT DO NOTHING)
  # means two concurrent first builds cannot both miss the row and race on
  # the unique index; both reach the same row and the lock serialises them.
  defp lock_row!(%Meeting{id: meeting_id}) do
    Repo.insert!(%MeetingBriefing{meeting_id: meeting_id},
      on_conflict: :nothing,
      conflict_target: :meeting_id
    )

    Repo.one!(
      from(b in MeetingBriefing,
        where: b.meeting_id == ^meeting_id,
        lock: "FOR UPDATE"
      )
    )
  end

  @doc """
  Add `finding` as a `"finding"` item to `meeting`'s briefing (creating the
  row if the meeting has none yet). Idempotent: an item already present is
  left as it is, so its key and resolution survive. Pure merge, like
  `build/1`: no receipt is written or removed.

  Returns `{:ok, briefing, %{new_keys: keys}}`; `{:error, :not_found}` when
  the meeting does not exist or is not in `finding.meeting_ids`.
  """
  @spec add_finding(Meeting.t() | binary(), SynthesisFinding.t()) ::
          {:ok, MeetingBriefing.t(), %{new_keys: [String.t()]}} | {:error, :not_found}
  def add_finding(%Meeting{id: id}, finding), do: add_finding(id, finding)

  def add_finding(meeting_id, %SynthesisFinding{} = finding) when is_binary(meeting_id) do
    with true <- meeting_id in (finding.meeting_ids || []),
         %Meeting{} = meeting <- Repo.get(Meeting, meeting_id) do
      {:ok, result} =
        Repo.transaction(fn ->
          row = lock_row!(meeting)
          {key, item} = SynthesisFindings.item(finding)
          items = row.items || %{}

          if Map.has_key?(items, key) do
            {row, %{new_keys: []}}
          else
            updated =
              row
              |> MeetingBriefing.changeset(%{items: Map.put(items, key, item)})
              |> Repo.update!()

            {updated, %{new_keys: [key]}}
          end
        end)

      {briefing, delta} = result
      {:ok, briefing, delta}
    else
      _ -> {:error, :not_found}
    end
  end

  # ── Items ─────────────────────────────────────────────────────────────────

  defp task_items(%Meeting{} = meeting) do
    meeting
    |> Meetings.meeting_tasks_query()
    |> select([task: t], %{id: t.id, title: t.title, status: t.status})
    |> Repo.all()
    |> Enum.map(fn task ->
      item("task", "task:" <> task.id, task.title, task.status)
    end)
  end

  defp canvas_items(%Meeting{id: meeting_id}) do
    from(c in MeetingCandidate,
      join: cv in Canvas,
      on: cv.id == c.canvas_id and is_nil(cv.deleted_at),
      where: c.meeting_id == ^meeting_id,
      distinct: cv.id,
      order_by: [asc: cv.id, asc: c.inserted_at],
      select: %{id: cv.id, title: cv.title}
    )
    |> Repo.all()
    |> Enum.map(fn canvas -> item("canvas", "canvas:" <> canvas.id, canvas.title, "created") end)
  end

  defp item(kind, ref, title, filed_status) do
    {node_key(ref),
     %{"kind" => kind, "ref" => ref, "title" => title || "", "filed_status" => filed_status}}
  end

  # ── Content ───────────────────────────────────────────────────────────────

  defp content(%Meeting{} = meeting) do
    candidates =
      from(c in MeetingCandidate,
        where: c.meeting_id == ^meeting.id,
        where: c.classified_intent in ["open_question", "action_items"],
        where: c.disposition == :accepted,
        where: is_nil(c.closed_reason) or c.closed_reason not in ^@withdrawn_reasons,
        order_by: [asc: c.inserted_at, asc: c.id],
        select: %{
          id: c.id,
          intent: c.classified_intent,
          quote: c.evidence_quote,
          task_id: c.task_id
        }
      )
      |> Repo.all()

    filed_candidate_ids = filed_candidate_ids(meeting)

    %{
      "open_questions" => for(%{intent: "open_question"} = c <- candidates, do: content_entry(c)),
      "unfiled_action_items" =>
        for(
          %{intent: "action_items", task_id: nil} = c <- candidates,
          not MapSet.member?(filed_candidate_ids, c.id),
          do: content_entry(c)
        ),
      "missing_prerequisites" => readiness(meeting).missing,
      "transcript_url" => "/meetings/" <> meeting.slug
    }
  end

  # Only identity can reconcile a candidate with a final checklist item. A
  # shared canvas or similar title is not evidence that this action was filed.
  # Keep the task query canonical, including its soft-deletion/access scope.
  defp filed_candidate_ids(meeting) do
    tasks =
      meeting
      |> Meetings.meeting_tasks_query()
      |> select([task: t], %{id: t.id, metadata: t.metadata})
      |> Repo.all()

    task_ids = MapSet.new(tasks, & &1.id)
    direct_ids = Enum.map(tasks, & &1.metadata["candidate_id"])

    ledger_ids =
      case Repo.get_by(CompletionRun, meeting_id: meeting.id) do
        nil ->
          []

        run ->
          for {_item_id, entry} <- run.item_results || %{},
              entry["status"] == "processed",
              Enum.any?(
                (entry["task_ids"] || []) ++ (entry["existing_task_ids"] || []),
                &MapSet.member?(task_ids, &1)
              ),
              candidate_id <- entry["candidate_ids"] || [],
              do: candidate_id
      end

    MapSet.new(direct_ids ++ ledger_ids)
  end

  defp content_entry(candidate), do: %{"id" => candidate.id, "text" => candidate.quote || ""}

  # ── Summary ───────────────────────────────────────────────────────────────

  defp summary_attrs(meeting) do
    transcripts = owned_transcripts(meeting) |> Enum.filter(&(&1.status == "complete"))

    case List.last(transcripts) do
      nil ->
        %{}

      transcript ->
        summaries =
          Enum.map(transcripts, & &1.summary)
          |> Enum.filter(&(is_binary(&1) && String.trim(&1) != ""))

        %{
          summary: if(summaries == [], do: nil, else: Enum.join(summaries, "\n\n")),
          transcript_id: transcript.id
        }
    end
  end

  defp owned_transcripts(meeting) do
    Repo.all(
      from(t in Transcript,
        where: t.space_id == ^meeting.chat_space_id,
        order_by: [asc: t.started_at, asc: t.id]
      )
    )
    |> Enum.filter(&Platform.Meetings.Completion.belongs_to_meeting?(&1, meeting))
  end

  @doc "Durable delivery gates, recomputed from the current captured snapshot."
  def readiness(meeting, now \\ DateTime.utc_now()) do
    run = Repo.get_by(CompletionRun, meeting_id: meeting.id)
    snapshot = Platform.Meetings.Completion.snapshot(meeting)

    current? =
      case snapshot do
        {:ok, snap, _} ->
          run && run.capture_finished_at &&
            run.snapshot_hash == Platform.Meetings.Completion.snapshot_hash(run, snap)

        _ ->
          false
      end

    transcripts = owned_transcripts(meeting)

    summary? =
      current? && transcripts != [] &&
        Enum.all?(transcripts, fn t ->
          Transcript.summary_current?(t) && is_binary(t.summary) && String.trim(t.summary) != ""
        end)

    triage? = current? && run.status == "filed"

    synthesis? =
      is_nil(run) || run.synthesis == %{} ||
        run.synthesis["snapshot_hash"] != run.snapshot_hash ||
        run.synthesis["status"] == "complete"

    missing =
      for {part, ready} <- [
            {"summary", summary?},
            {"triage filing", triage?},
            {"synthesis", synthesis?}
          ],
          !ready,
          do: part

    deadline? = not is_nil(meeting.ended_at) && DateTime.diff(now, meeting.ended_at) >= 1200
    %{ready?: missing == [], deadline?: deadline?, missing: missing}
  end

  # ── Delivery ──────────────────────────────────────────────────────────────

  @doc """
  Build the briefing for `meeting` and deliver it to every attendee's Inbox.

  Returns `{:ok, %{created: n, updated: m}}`, counting attendees whose row
  was created and updated by this call, or `{:error, :not_concluded}` for a
  meeting that is not ended (nothing written, nobody pushed).

  Push is sent through `:notifications_module` (default
  `Platform.Notifications`), the same indirection `Platform.Inbox` uses, and
  only for a `:created` row. Each Inbox write broadcasts
  `{:inbox_changed, user_id}` on that user's topic.
  """
  @spec deliver(Meeting.t()) ::
          {:ok, %{created: non_neg_integer(), updated: non_neg_integer()}}
          | {:ok, :pending}
          | {:error, :not_concluded}
  def deliver(%Meeting{} = meeting) do
    if Repo.in_transaction?(), do: {:ok, :pending}, else: deliver_committed(meeting)
  end

  defp deliver_committed(%Meeting{id: id}) do
    # Lock in the same order as completion callbacks. Inbox insert uniqueness
    # arbitrates pushes; push only AFTER the transaction which writes the row.
    {:ok, outcome} =
      Repo.transaction(fn ->
        Meetings.lock_transcript_space(Repo.get(Meeting, id))
        Repo.one(from(r in CompletionRun, where: r.meeting_id == ^id, lock: "FOR UPDATE"))
        meeting = Repo.one(from(m in Meeting, where: m.id == ^id, lock: "FOR UPDATE"))

        cond do
          is_nil(meeting) or meeting.status != "ended" ->
            {:error, :not_concluded}

          true ->
            gates = readiness(meeting)

            if gates.ready? or gates.deadline? do
              {:ok, briefing, delta} = build(meeting)
              count = briefing |> item_keys() |> length()

              fields = %{
                title: meeting.name,
                body: items_label(count),
                url: inbox_url(meeting),
                new_items?: delta.new_keys != []
              }

              outcomes =
                Enum.map(briefing.attendee_user_ids, fn user_id ->
                  case Inbox.upsert_meeting_briefing_item(briefing, user_id, fields) do
                    {:ok, _, status} -> {user_id, status}
                    {:error, _} -> {user_id, :error}
                  end
                end)

              {:delivered, meeting, count, outcomes}
            else
              {:ok, :pending}
            end
        end
      end)

    case outcome do
      {:delivered, meeting, count, outcomes} ->
        Enum.each(outcomes, fn
          {user_id, :created} -> push(user_id, meeting, count)
          _ -> :ok
        end)

        {:ok,
         %{
           created: Enum.count(outcomes, &(elem(&1, 1) == :created)),
           updated: Enum.count(outcomes, &(elem(&1, 1) == :updated))
         }}

      other ->
        other
    end
  end

  @doc "Refresh only the meeting owning this transcript, using capture-time legacy bounds."
  def refresh_for_transcript(%Transcript{space_id: nil}), do: :ok

  def refresh_for_transcript(%Transcript{} = transcript) do
    query =
      from(m in Meeting, where: m.status == "ended" and m.chat_space_id == ^transcript.space_id)

    Repo.all(query)
    |> Enum.filter(&Platform.Meetings.Completion.belongs_to_meeting?(transcript, &1))
    |> Enum.each(&deliver/1)

    :ok
  end

  def refresh_for_transcript(_), do: :ok

  @doc """
  Whether the Inbox row for briefing `briefing_id` may be cleared
  (`Platform.Inbox.reconcile_for_user/1`, ADR 0049): the briefing row EXISTS
  and its meeting ended more than `Platform.Memory.Insight.default_ttl_days/0`
  days ago. A missing briefing, a missing meeting, a meeting with no
  `ended_at`, or a malformed id is NOT confirmation: `false`, the row stays.

  Options: `:now` (default `DateTime.utc_now/0`).
  """
  @spec inbox_row_stale?(term(), keyword()) :: boolean()
  def inbox_row_stale?(briefing_id, opts \\ [])

  def inbox_row_stale?(briefing_id, opts) when is_binary(briefing_id) do
    with true <- Platform.UUID.valid?(briefing_id),
         %DateTime{} = ended_at <-
           Repo.one(
             from(b in MeetingBriefing,
               join: m in Meeting,
               on: m.id == b.meeting_id,
               where: b.id == ^briefing_id,
               select: m.ended_at
             )
           ) do
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
      DateTime.diff(now, ended_at, :second) > Platform.Memory.Insight.default_ttl_days() * 86_400
    else
      _ -> false
    end
  end

  def inbox_row_stale?(_briefing_id, _opts), do: false

  @doc "The Inbox detail URL for `meeting`'s briefing."
  @spec inbox_url(Meeting.t() | binary()) :: String.t()
  def inbox_url(%Meeting{id: id}), do: inbox_url(id)
  def inbox_url(meeting_id) when is_binary(meeting_id), do: "/inbox/meeting/" <> meeting_id

  defp item_keys(%MeetingBriefing{items: items}) do
    (items || %{}) |> Map.delete(@content_key) |> Map.keys()
  end

  defp items_label(1), do: "1 item"
  defp items_label(count), do: "#{count} items"

  # A push failure never fails delivery: the Inbox row is the durable record
  # and is already written.
  defp push(user_id, %Meeting{} = meeting, count) do
    notification =
      Platform.Push.Notification.new(%{
        kind: "meeting_briefing",
        title: "Meeting briefing",
        body: meeting.name <> " · " <> items_label(count),
        url: inbox_url(meeting)
      })

    notifications_module().fan_out_to_user(user_id, notification)
    :ok
  rescue
    error ->
      Logger.warning("[meeting_briefings] push failed: " <> Exception.message(error))
      :ok
  end

  defp notifications_module do
    Application.get_env(:platform, :notifications_module, Platform.Notifications)
  end

  # ── Reading ───────────────────────────────────────────────────────────────

  @doc "PubSub topic carrying `{:meeting_briefing_changed, briefing_id}`."
  @spec topic(binary()) :: String.t()
  def topic(briefing_id), do: "meeting_briefing:" <> briefing_id

  @doc "Subscribe the calling process to `topic/1`."
  @spec subscribe(binary()) :: :ok | {:error, term()}
  def subscribe(briefing_id), do: Phoenix.PubSub.subscribe(Platform.PubSub, topic(briefing_id))

  @doc """
  The briefing for `meeting_id` IF `user_id` is one of its attendees, else
  `nil`.

  The attendee check is IN the query (`user_id = ANY(attendee_user_ids)`),
  not a check after the load, and both ids are UUID-guarded first. So a
  non-attendee, a meeting id that names no briefing, and a malformed id all
  return the same `nil`: the answer is no oracle for whether a meeting
  exists. The meeting is preloaded.
  """
  @spec get_for_attendee(term(), term()) :: MeetingBriefing.t() | nil
  def get_for_attendee(meeting_id, user_id) when is_binary(meeting_id) and is_binary(user_id) do
    if Platform.UUID.valid?(meeting_id) and Platform.UUID.valid?(user_id) do
      Repo.one(
        from(b in MeetingBriefing,
          where: b.meeting_id == ^meeting_id,
          where: fragment("?::uuid = ANY(?)", type(^user_id, :binary_id), b.attendee_user_ids),
          preload: :meeting
        )
      )
    end
  end

  def get_for_attendee(_meeting_id, _user_id), do: nil

  @doc """
  The briefings among `briefing_ids` that `user_id` is an attendee of, as
  `%{briefing_id => briefing}` with `:meeting` preloaded — the Inbox list's
  batch read for its meeting rows (task 01a1694a stage 4). Same rule as
  `get_for_attendee/2`: the attendee check is in the query, so an id the
  person is not on is simply absent. Malformed ids are dropped.
  """
  @spec list_for_attendee([binary()], binary()) :: %{binary() => MeetingBriefing.t()}
  def list_for_attendee(briefing_ids, user_id)
      when is_list(briefing_ids) and is_binary(user_id) do
    ids = Enum.filter(briefing_ids, &(is_binary(&1) and Platform.UUID.valid?(&1)))

    if ids == [] or not Platform.UUID.valid?(user_id) do
      %{}
    else
      from(b in MeetingBriefing,
        where: b.id in ^ids,
        where: fragment("?::uuid = ANY(?)", type(^user_id, :binary_id), b.attendee_user_ids),
        preload: :meeting
      )
      |> Repo.all()
      |> Map.new(&{&1.id, &1})
    end
  end

  def list_for_attendee(_briefing_ids, _user_id), do: %{}

  @doc """
  A pure read of `briefing` for rendering.

  Returns `%{meeting, summary, transcript_url, open_questions,
  unfiled_action_items, counts: %{total, open, resolved}, open, resolved}`.
  `open` and `resolved` are lists of
  `%{key, kind, title, ref, receipt, revertible?, actions}`:

    * `receipt` is nil, or `%{verb, at, by, by_name, ref, kind}`. `by_name`
      is resolved through `Platform.Accounts.get_users_map/2` with
      `include_archived: true` — a receipt is a historical attribution, so
      an actor archived since is still named.
    * `revertible?` is true only for a `task` item whose task is still
      returned by `Platform.Meetings.meeting_tasks_query/1` (not deleted,
      still this meeting's under THE rule) and is still `"backlog"`.
    * `actions` is `[]` once resolved; otherwise
      `[:revert, :ask]` for a revertible task, `[:ask]` for other filed tasks,
      and `[:confirm, :ask]` for non-task changes.

  `scope` is the viewer's and controls whether Revert is offered. The action
  re-checks task access and current revertibility inside its transaction.
  """
  @spec view(MeetingBriefing.t(), Scope.t() | nil) :: map()
  def view(%MeetingBriefing{} = briefing, scope) do
    briefing = Repo.preload(briefing, :meeting)
    meeting = briefing.meeting
    content = Map.get(briefing.items || %{}, @content_key, %{})

    {items, receipts} =
      resolve_findings(Map.delete(briefing.items || %{}, @content_key), briefing.receipts || %{})

    revertible = revertible_task_ids(meeting, items)

    names =
      receipts
      |> Map.values()
      |> Enum.map(& &1["by"])
      |> Enum.filter(&is_binary/1)
      |> Platform.Accounts.get_users_map(include_archived: true)

    entries =
      items
      |> Enum.map(fn {key, item} ->
        receipt = receipt_view(receipts[key], names)
        revertible? = item_revertible?(item, revertible) and task_write_allowed?(item, scope)

        %{
          key: key,
          kind: item["kind"],
          title: item["title"],
          ref: item["ref"],
          receipt: receipt,
          revertible?: revertible?,
          availability: task_availability(item, meeting),
          actions: actions(receipt, revertible?, item["kind"])
        }
      end)
      |> Enum.sort_by(&{&1.kind != "task", &1.title || "", &1.key})

    {resolved, open} = Enum.split_with(entries, &(&1.receipt != nil))

    %{
      meeting: meeting,
      summary: briefing.summary,
      missing_prerequisites: content["missing_prerequisites"] || [],
      transcript_url: content["transcript_url"] || "/meetings/" <> meeting.slug,
      open_questions: content["open_questions"] || [],
      unfiled_action_items: content["unfiled_action_items"] || [],
      counts: %{total: length(entries), open: length(open), resolved: length(resolved)},
      open: open,
      resolved: resolved
    }
  end

  # Finding items take their receipt from the shared finding row, never from
  # this briefing's receipts map; a finding item whose row is gone is dropped.
  defp resolve_findings(items, receipts) do
    finding_ids =
      for {_key, %{"kind" => "finding", "ref" => "finding:" <> id}} <- items, do: id

    findings = SynthesisFindings.get_many(finding_ids)

    Enum.reduce(items, {%{}, receipts}, fn
      {key, %{"kind" => "finding", "ref" => "finding:" <> id} = item}, {acc, rcpts} ->
        case Map.get(findings, id) do
          %SynthesisFinding{receipt: nil} -> {Map.put(acc, key, item), Map.delete(rcpts, key)}
          %SynthesisFinding{receipt: r} -> {Map.put(acc, key, item), Map.put(rcpts, key, r)}
          nil -> {acc, Map.delete(rcpts, key)}
        end

      {key, %{"kind" => "finding"}}, {acc, rcpts} ->
        {acc, Map.delete(rcpts, key)}

      {key, item}, {acc, rcpts} ->
        {Map.put(acc, key, item), rcpts}
    end)
  end

  defp actions(nil, true, "task"), do: [:revert, :ask]
  defp actions(nil, false, "task"), do: [:ask]
  defp actions(nil, _revertible?, _kind), do: [:confirm, :ask]
  defp actions(_receipt, _revertible?, _kind), do: []

  defp receipt_view(nil, _names), do: nil

  defp receipt_view(%{} = receipt, names) do
    by = receipt["by"]

    %{
      verb: receipt["verb"],
      at: receipt["at"],
      by: by,
      by_name: display_name(Map.get(names, by)),
      ref: receipt["ref"],
      kind: receipt["kind"]
    }
  end

  defp display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp display_name(%{email: email}) when is_binary(email), do: email
  defp display_name(_), do: "Someone"

  defp task_write_allowed?(%{"ref" => "task:" <> id}, %Scope{} = scope),
    do: match?({:ok, _}, authorize_task_write(scope, id))

  defp task_write_allowed?(_item, _scope), do: false

  defp task_availability(%{"kind" => "task", "ref" => "task:" <> id}, meeting) do
    case Platform.UUID.valid?(id) && Repo.get(Platform.Tasks.Task, id) do
      %{deleted_at: %DateTime{}} ->
        "This task was removed."

      %{project_id: project_id} when project_id != meeting.project_id ->
        "This task moved to another project."

      %{status: status} ->
        "Filed task · " <> status

      _ ->
        "This task is unavailable."
    end
  end

  defp task_availability(_item, _meeting), do: nil

  defp item_revertible?(%{"kind" => "task", "ref" => "task:" <> id}, revertible),
    do: MapSet.member?(revertible, id)

  defp item_revertible?(_item, _revertible), do: false

  # The task ids among `items` that are revertible right now: still this
  # meeting's under `Meetings.meeting_tasks_query/1` AND still backlog. ONE
  # query for the whole briefing.
  defp revertible_task_ids(%Meeting{} = meeting, items) do
    ids =
      for {_key, %{"kind" => "task", "ref" => "task:" <> id}} <- items,
          Platform.UUID.valid?(id),
          do: id

    if ids == [] do
      MapSet.new()
    else
      meeting
      |> Meetings.meeting_tasks_query()
      |> where(
        [task: t],
        t.id in ^ids and t.status == "backlog" and t.project_id == ^meeting.project_id
      )
      |> select([task: t], t.id)
      |> Repo.all()
      |> MapSet.new()
    end
  end

  @doc "Resolve a durable task reference to its shared attendee-only briefing card."
  def card_for_task(task_id, user_id) when is_binary(task_id) and is_binary(user_id) do
    ref = "task:" <> task_id

    from(b in MeetingBriefing,
      where: ^user_id in b.attendee_user_ids,
      where:
        fragment(
          "EXISTS (SELECT 1 FROM jsonb_each(?) AS entry WHERE entry.value->>'kind' = 'task' AND entry.value->>'ref' = ?)",
          b.items,
          ^ref
        )
    )
    |> Repo.all()
    |> Enum.find_value(fn briefing ->
      case Enum.find(briefing.items || %{}, fn {_key, item} ->
             is_map(item) and item["kind"] == "task" and item["ref"] == ref
           end) do
        {key, _item} ->
          if get_for_attendee(briefing.meeting_id, user_id),
            do: %{meeting_id: briefing.meeting_id, key: key}

        nil ->
          nil
      end
    end)
  end

  def card_for_task(_task_id, _user_id), do: nil

  # ── Acting ────────────────────────────────────────────────────────────────

  @doc """
  Resolve item `key` of `briefing` with `verb` (`:revert | :confirm | :ask`)
  as the person `scope` is for. `scope` must be rebuilt per click.

  ONE transaction:

    1. the row is re-read `FOR UPDATE`, so two clicks on one item serialise;
    2. `{:error, :not_found}` unless the clicker is in `attendee_user_ids`
       and is not an external member of the meeting's org
       (`Platform.Meetings.meeting_org_guest?/2`);
    3. `{:error, :not_found}` unless `key` names an item (`"_content"` is
       not one);
    4. **`{:error, :already_resolved, briefing}` when the item already has a
       receipt** — the shared-resolution guard. A stale client's click is a
       no-op and the fresh `briefing` it returns re-renders the item as
       resolved;
    5. the verb:
       * `:revert` — re-checks revertibility live (`:not_revertible`
         otherwise), requires `Platform.Access.task_target(scope,
         {:task, id}, "tasks.write")` (`:unauthorized` otherwise), then
         `Platform.Tasks.soft_delete_task/1`. Receipt `"reverted"`, ref
         `task:<id>`;
       * `:confirm` — no side effect. Receipt `"confirmed"`;
       * `:ask` — `{:error, :blank}` for a blank `params["question"]`.
         Otherwise posts the question as the clicker into the meeting's chat
         space with `Platform.Chat.post_message/2`. `post_message/2` does NOT
         ensure participation — it requires a `participant_id` and posts as
         whoever that row is — so the clicker's row comes from
         `Platform.Meetings.Membership.ensure_chat_space_participant/3`,
         which returns it or, for an attendee who has none, adds one with
         their display name (an attendee of the meeting belongs in its
         space). The item's title is quoted as inert text: mention tokens in
         it are broken so a task title can never summon anyone. Receipt
         `"asked"`, ref `message:<id>`;
    6. the receipt `%{"verb", "at", "by", "ref", "kind"}` is written.

  For a `"finding"` item, step 4 and step 6 use the shared
  `Platform.Meetings.SynthesisFinding` row instead of this briefing's
  `receipts`: the finding is locked `FOR UPDATE` after the briefing,
  `{:error, :not_found}` unless it still lists this meeting and the clicker
  as a recipient, `:already_resolved` when `finding.receipt` is set, and the
  receipt is written to the finding. After the commit `{:inbox_changed, _}`
  goes to every recipient and `{:meeting_briefing_changed, _}` to every
  briefing of a meeting in `finding.meeting_ids`.

  A failed verb rolls the whole transaction back: no receipt, no side
  effect. After the commit, `{:inbox_changed, user_id}` is broadcast to
  EVERY attendee and `{:meeting_briefing_changed, briefing_id}` on
  `topic/1`.

  Returns `{:ok, briefing}`, `{:error, :already_resolved, briefing}`, or
  `{:error, reason}`.
  """
  @spec act(MeetingBriefing.t(), String.t(), atom(), Scope.t(), map()) ::
          {:ok, MeetingBriefing.t()}
          | {:error, :already_resolved, MeetingBriefing.t()}
          | {:error, atom() | term()}
  def act(briefing, key, verb, scope, params \\ %{})

  def act(%MeetingBriefing{id: id}, key, verb, %Scope{} = scope, params)
      when verb in @verbs and is_binary(key) do
    user_id = scope_user_id(scope)

    result =
      Repo.transaction(fn ->
        with %MeetingBriefing{} = row <- lock_briefing(id),
             :ok <- ensure_attendee(row, user_id),
             {:ok, item} <- fetch_item(row, key),
             {:ok, finding} <- lock_finding(row, item, user_id),
             :ok <- ensure_unresolved(row, key, finding),
             {:ok, ref} <- run_verb(verb, row, item, scope, user_id, params || %{}) do
          receipt = %{
            "verb" => Map.fetch!(@receipt_verbs, verb),
            "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "by" => user_id,
            "ref" => ref,
            "kind" => item["kind"]
          }

          write_receipt!(row, key, finding, receipt)
        else
          nil -> Repo.rollback(:not_found)
          {:already_resolved, row} -> Repo.rollback({:already_resolved, row})
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {briefing, %SynthesisFinding{} = finding}} ->
        broadcast_finding_changed(briefing, finding)
        {:ok, briefing}

      {:ok, briefing} ->
        broadcast_changed(briefing)
        {:ok, briefing}

      {:error, {:already_resolved, row}} ->
        {:error, :already_resolved, row}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def act(_briefing, _key, _verb, _scope, _params), do: {:error, :not_found}

  defp scope_user_id(%Scope{actor: %{id: id}}) when is_binary(id), do: id
  defp scope_user_id(_scope), do: nil

  defp lock_briefing(id) do
    Repo.one(
      from(b in MeetingBriefing, where: b.id == ^id, lock: "FOR UPDATE", preload: :meeting)
    )
  end

  defp ensure_attendee(%MeetingBriefing{} = row, user_id) when is_binary(user_id) do
    if user_id in (row.attendee_user_ids || []) and
         not Meetings.meeting_org_guest?(row.meeting, user_id),
       do: :ok,
       else: {:error, :not_found}
  end

  defp ensure_attendee(_row, _user_id), do: {:error, :not_found}

  defp fetch_item(_row, @content_key), do: {:error, :not_found}

  defp fetch_item(%MeetingBriefing{items: items}, key) do
    case Map.get(items || %{}, key) do
      %{} = item -> {:ok, item}
      _ -> {:error, :not_found}
    end
  end

  # A finding item's resolution lives on the shared finding row, locked
  # FOR UPDATE here so clicks from DIFFERENT briefings serialise on it (the
  # briefing lock alone only serialises clicks within one briefing). Lock
  # order is always briefing, then finding. The finding must still list this
  # briefing's meeting and the clicker as a recipient.
  defp lock_finding(row, %{"kind" => "finding", "ref" => "finding:" <> finding_id}, user_id) do
    case SynthesisFindings.lock(finding_id) do
      %SynthesisFinding{} = finding ->
        if row.meeting_id in (finding.meeting_ids || []) and
             user_id in (finding.recipient_user_ids || []),
           do: {:ok, finding},
           else: {:error, :not_found}

      nil ->
        {:error, :not_found}
    end
  end

  defp lock_finding(_row, %{"kind" => "finding"}, _user_id), do: {:error, :not_found}
  defp lock_finding(_row, _item, _user_id), do: {:ok, nil}

  defp ensure_unresolved(row, _key, %SynthesisFinding{receipt: receipt}) do
    if is_nil(receipt), do: :ok, else: {:already_resolved, row}
  end

  defp ensure_unresolved(%MeetingBriefing{receipts: receipts} = row, key, nil) do
    if Map.has_key?(receipts || %{}, key), do: {:already_resolved, row}, else: :ok
  end

  defp write_receipt!(row, _key, %SynthesisFinding{} = finding, receipt) do
    updated = finding |> SynthesisFinding.receipt_changeset(receipt) |> Repo.update!()
    {row, updated}
  end

  defp write_receipt!(row, key, nil, receipt) do
    row
    |> MeetingBriefing.changeset(%{receipts: Map.put(row.receipts || %{}, key, receipt)})
    |> Repo.update!()
  end

  defp run_verb(:confirm, _row, item, _scope, _user_id, _params), do: {:ok, item["ref"]}

  defp run_verb(:revert, row, %{"kind" => "task", "ref" => "task:" <> task_id}, scope, _uid, _p) do
    with :ok <- ensure_revertible(row.meeting, task_id),
         {:ok, _typed} <- authorize_task_write(scope, task_id),
         %Platform.Tasks.Task{} = task <- Platform.Tasks.get_task_record(task_id),
         {:ok, _deleted} <- Platform.Tasks.soft_delete_task(task) do
      {:ok, "task:" <> task_id}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_revertible}
    end
  end

  defp run_verb(:revert, _row, _item, _scope, _user_id, _params), do: {:error, :not_revertible}

  defp run_verb(:ask, row, item, _scope, user_id, params) do
    question = params |> Map.get("question", Map.get(params, :question, "")) |> to_string()

    if String.trim(question) == "" do
      {:error, :blank}
    else
      space_id = row.meeting.chat_space_id

      with {:ok, participant} <-
             Platform.Meetings.Membership.ensure_chat_space_participant(
               space_id,
               user_id,
               asker_display_name(user_id)
             ),
           {:ok, message} <-
             Platform.Chat.post_message(%{
               space_id: space_id,
               participant_id: participant.id,
               content_type: "text",
               content: ask_content(item, question)
             }) do
        {:ok, "message:" <> message.id}
      end
    end
  end

  # Live re-check at click time: the build-time verdict may be stale (the
  # task moved past backlog, or was deleted, since the briefing rendered).
  defp ensure_revertible(%Meeting{} = meeting, task_id) do
    items = %{"live" => %{"kind" => "task", "ref" => "task:" <> task_id}}

    if MapSet.member?(revertible_task_ids(meeting, items), task_id),
      do: :ok,
      else: {:error, :not_revertible}
  end

  defp authorize_task_write(scope, task_id) do
    case Platform.Access.task_target(scope, {:task, task_id}, "tasks.write") do
      {:ok, typed} -> {:ok, typed}
      :not_found -> {:error, :unauthorized}
    end
  end

  defp asker_display_name(user_id) do
    case Platform.Accounts.get_user(user_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      %{email: email} when is_binary(email) -> email
      _ -> nil
    end
  end

  # The title is quoted, never interpreted: a mention token (`@[...]`) inside
  # a task title would otherwise summon whoever it names when the clicker
  # posts. A word joiner between `@` and `[` breaks the token and renders
  # invisibly.
  defp ask_content(item, question) do
    title =
      (item["title"] || "")
      |> String.replace("@[", "@\u2060[")
      |> String.replace("\n", " ")

    "> " <> title <> "\n\n" <> String.trim(question)
  end

  # A finding resolution changes every briefing carrying it: tell every
  # recipient's Inbox and every one of those briefings' topics.
  defp broadcast_finding_changed(%MeetingBriefing{} = briefing, %SynthesisFinding{} = finding) do
    meeting_ids = finding.meeting_ids || []

    briefing_ids =
      from(b in MeetingBriefing, where: b.meeting_id in ^meeting_ids, select: b.id)
      |> Repo.all()

    users =
      Enum.uniq((finding.recipient_user_ids || []) ++ (briefing.attendee_user_ids || []))

    Enum.each(users, fn user_id ->
      Phoenix.PubSub.broadcast(Platform.PubSub, Inbox.topic(user_id), {:inbox_changed, user_id})
    end)

    briefing_ids
    |> Enum.concat([briefing.id])
    |> Enum.uniq()
    |> Enum.each(fn briefing_id ->
      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        topic(briefing_id),
        {:meeting_briefing_changed, briefing_id}
      )
    end)
  end

  defp broadcast_changed(%MeetingBriefing{} = briefing) do
    Enum.each(briefing.attendee_user_ids || [], fn user_id ->
      Phoenix.PubSub.broadcast(Platform.PubSub, Inbox.topic(user_id), {:inbox_changed, user_id})
    end)

    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      topic(briefing.id),
      {:meeting_briefing_changed, briefing.id}
    )
  end
end
