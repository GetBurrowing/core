defmodule Platform.Memory.Insights.Briefings do
  @moduledoc """
  Reads and in-place updates of delivered briefing canvases. Task
  `01a13867-3213-7001-a128-6b4c6b34283f`, stage 4.

  ## Authority comes from the row, never from the click

  A briefing canvas click carries a node key (`insight_ok:<key>`), never an
  insight id. `get_by_canvas/1` finds the `memory_briefings` row by the id of
  the canvas that was CLICKED, and `insight_id/2` reads the insight id out of
  that row's `items`. A key that is not on the clicked canvas's row resolves
  to nothing, whatever the action value says.

  ## Node ids per item

  `Platform.Memory.Insights.BriefingCard` renders each item under ids derived
  from its node key:

    * the line: `done-<key>`, `question-<key>`, `call-<key>` or, for a
      page edit or task applied unattended (task 01a15587 stage 4),
      `applied-<key>`;
    * the controls: `done-actions-<key>` (Looks right / Flag),
      `applied-actions-<key>` (Revert / Flag, or Delete task / Flag),
      `applied-link-<key>` (a filed task's link, removed with the buttons
      once the item is settled, since the task may be gone),
      `insight_flag_reason:<key>` (the inline flag form, opened by Flag) or
      `insight_answer:<key>` (a question's answer form);
    * a note that replaces the controls once the item is settled: `note-<key>`;
    * after Looks right, a Flag-only row beside the note: `flag-actions-<key>`
      (stage 6). Looks right means "confirmed for now", not final, so the
      line can still be flagged; the row opens the same inline flag form.

  An item is SETTLED when its canvas carries a note, or none of its
  controls. Settling is what Looks right, Answer and Flag do, so a second
  click finds no Looks right or Answer to press. `settled_nodes/2` is how
  the disseminator keeps a settled item settled when it re-renders the
  day's canvas: the line, the note and whatever Flag row or open flag form
  sits beside it are kept as they are.

  ## Writes

  Every update reads the canvas's live document from its server, then
  patches only the nodes of one item (`set_props`, `delete_node`, or
  `replace_children` on the card that holds the controls). Canvas writes are
  `:system`: the person's own authority was already checked by the caller.

  ## Briefings with no canvas (task 01a15ee1 stage 1)

  A briefing delivered to the Inbox has `canvas_id: nil`. `settle/3`,
  `retract/2` and `open_flag_form/2` skip such a row without raising (there
  is no canvas to patch); historical rows that have a canvas are patched as
  before. `containing/1` still returns every row, canvas or not, because
  `Platform.Memory.Insights.Actions.recipient?/2` authorises the recipient
  through it.

  ## The Inbox briefing (task 01a15ee1 stage 3)

  `view/2` is the read model the Inbox renders; `handle/5` and `undo/3` are
  every button on it. Backend only: the rendering is stage 4 and 5.

  ### view(briefing, scope)

  Pure read. Returns `%{date, counts: %{total, open, calls, handled},
  needs_call, fyi, done}`; each section is a list of items
  `%{key, insight, kind, section, receipt, project, email, draft,
  may_handle?, actions}`, oldest first. `kind` is `:question | :page_edit |
  :task | :briefing | :outside` (an insight whose addressee is an email
  outside the org is `:outside` whatever its action type,
  `Platform.Memory.Insights.Outside.outside?/1`).

    * **needs_call**: OPEN items that are a question, a `needs_call`-tier
      item, an outside message, a `page_edit` while `apply_page_edits` is
      off, or a task with no inferable project (recomputed with
      `ProjectInference.infer/1`, never read from a stored flag; its
      `project` is nil). Any other open item that is not a `briefing` (an
      unapplied page edit or unfiled task whose toggle is on) is here too.
    * **fyi**: open `briefing` items.
    * **done**: items with a receipt in `memory_briefings.receipts`, plus
      items applied unattended (state `done` with `pre_image["unattended"]`),
      whose receipt is derived (`auto?: true`, no undo).

  A purged insight renders from its receipt alone (`insight: nil`, kind
  from the receipt's `"kind"`, `may_handle?` false, no inverse that can
  succeed). A purged insight with NO receipt is not rendered. An item
  handled somewhere else (the Insights tab, an old canvas) has no receipt
  and is not rendered, but counts as handled. `counts.total` is rendered
  items plus those; `open` is needs_call plus fyi; `calls` is needs_call.

  `receipt` is `%{verb, at, by, ref, undo, auto?, detail}`; `detail` reads
  `ref` (`ref_detail/1`): `page:<key>@v<n>` gives path and version,
  `task:<id>` the task (and `project` its CURRENT project's `%{id, name}`),
  `journal:<id>` the answer's entry, `user:<id>` plus `name` the reroute
  target, `verdict:<id>` Not useful's verdict. `draft` is `%{id, status,
  to}` for an outside message drafted by
  `Platform.Memory.Insights.Outside`, else nil. `may_handle?` is
  `Actions.may_handle?/2` for the briefing's owner and false for anyone
  else; it is presentation only. `actions` lists the buttons: open items by
  kind (`:answer`, `:reroute`, `:apply`, `:edit_apply`, `:file`, `:got_it`,
  `:dismiss`, `:not_useful`), done items `:undo` when the receipt has an
  inverse, `:revert` / `:delete` for an unattended page edit / task, and
  `:move` for a filed task.

  ### handle(briefing, key, verb, scope, params)

  The insight is resolved ONLY from the reloaded row's `items[key]`, never
  from a client id; a key not in `items` is `{:error, :not_found}`. The
  clicker must be `briefing.user_id` (`{:error, :unauthorized}`). The verb
  calls the EXISTING action, which re-checks authority itself (`handle/5`
  adds none), and the receipt is written in the SAME transaction:

  | verb | action | receipt `ref` / `undo` |
  |---|---|---|
  | `answer` | `Actions.answer/4` (`params["answer"]`) | `journal:<id>` / `unanswer` |
  | `reroute` | `Actions.reroute/4` (`params["addressee"]`) | `user:<id>`, `name`, `previous` / reroute to `previous` (none when there was no previous user) |
  | `apply` | `Actions.act/3` | artefact / `revert` (page) or `delete` (task) |
  | `edit_apply` | `Actions.edit/4` (`"body"`, `"hunks"`), then `act/3` | as `apply` |
  | `file` | `Actions.act/3` with `project_id:` and `title:` | `task:<id>`, `project_id` / `delete` |
  | `got_it` | `Actions.looks_right/3` | nil / `restore` |
  | `dismiss` | `Actions.dismiss/3` | nil / `restore` |
  | `not_useful` | `Actions.reject/4` (`params["reason"]`) | `verdict:<id>` / `restore` with that `verdict_id` |
  | `revert` | `Actions.revert/2` | `page:<key>` / NONE |
  | `delete` | `Actions.delete_filed_task/3` | `task:<id>` / NONE |
  | `move` | `Actions.move_filed_task/4` (`params["project_id"]`) | `project:<id>`, `task_id` / move back |

  Every stored receipt is `%{"verb", "at", "by", "ref", "undo", "kind"}`
  plus the extras above; one that replaces an earlier receipt keeps it as
  `"prev"`. Errors return `{:error, reason}` (`:no_project` and
  `:not_found` from filing pass through as `act/3` returns them) and roll
  everything back, so the item does not move.

  ### undo(briefing, key, scope)

  The receipt's persistent inverse, kept for the rest of the day (a 5 s
  toast alone fails WCAG 2.2.1): `revert` is `Actions.revert/2`, `delete`
  `Actions.delete_filed_task/3`, `move` a move back, `reroute` a reroute to
  the stored previous addressee, `restore`
  `Platform.Memory.Insights.restore/3` (deleting Not useful's verdict row by
  id; the experiment signal is append-only and stays) and `unanswer`
  `Actions.unanswer/3` (appends `Retracted answer to: ...`; the answer's
  entry stays, journals are append-only). The receipt is then removed, or
  replaced by its `"prev"`.

  DECLARED DEVIATION: `revert` and `delete` of an item applied unattended
  have NO inverse (`{:error, :no_inverse}`): re-applying would need the
  insight reopened and re-grounded.

  Both broadcast `{:inbox_changed, user_id}` on the owner's Inbox topic
  after the commit; the insight broadcasts the actions make are held until
  then (`Platform.Memory.Insights.with_deferred_broadcasts/1`).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Platform.Access.Scope
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.CanvasDocument
  alias Platform.Mail.Drafts
  alias Platform.Memory.Briefing
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights
  alias Platform.Memory.Insights.Actions
  alias Platform.Memory.Insights.BriefingCard
  alias Platform.Memory.Insights.Outside
  alias Platform.Memory.Insights.ProjectInference
  alias Platform.Memory.Insights.Routing
  alias Platform.Memory.Insights.Settings
  alias Platform.Memory.Insights.Tier
  alias Platform.Repo
  alias Platform.Tasks

  @doc "The briefing row whose canvas is `canvas_id`, or nil."
  @spec get_by_canvas(term()) :: Briefing.t() | nil
  def get_by_canvas(canvas_id) when is_binary(canvas_id) do
    # `canvas_id` is the id of a canvas row the caller already loaded (the
    # clicked canvas), never a client string; the guard keeps any other
    # caller's malformed id a nil rather than a CastError.
    if Platform.UUID.valid?(canvas_id),
      do: Repo.get_by(Briefing, canvas_id: canvas_id),
      else: nil
  end

  def get_by_canvas(_canvas_id), do: nil

  @doc "The insight id `briefing` renders under `key`, or nil."
  @spec insight_id(Briefing.t(), term()) :: binary() | nil
  def insight_id(%Briefing{items: %{} = items}, key) when is_binary(key) do
    case Map.get(items, key) do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  def insight_id(_briefing, _key), do: nil

  @doc """
  `user_id`'s briefing for `digest_date`, or nil. The Inbox's
  `/inbox/briefing/:date` route reads through this, so a person only ever
  reaches their own row (task 01a15ee1 stage 4).
  """
  @spec for_user_on(term(), term()) :: Briefing.t() | nil
  def for_user_on(user_id, %Date{} = digest_date) when is_binary(user_id) do
    if Platform.UUID.valid?(user_id),
      do: Repo.get_by(Briefing, user_id: user_id, digest_date: digest_date),
      else: nil
  end

  def for_user_on(_user_id, _digest_date), do: nil

  @doc """
  The briefing `briefing_id` when it belongs to `user_id`, else nil (task
  01a15ee1 stage 5). The owner check is in the query, so another person's
  id reads exactly like a missing one. The Inbox detail and its toast's
  Undo read through this.
  """
  @spec get_for_user(term(), term()) :: Briefing.t() | nil
  def get_for_user(briefing_id, user_id) when is_binary(briefing_id) and is_binary(user_id) do
    if Platform.UUID.valid?(briefing_id) and Platform.UUID.valid?(user_id),
      do: Repo.get_by(Briefing, id: briefing_id, user_id: user_id),
      else: nil
  end

  def get_for_user(_briefing_id, _user_id), do: nil

  @doc """
  The briefings among `briefing_ids` that belong to `user_id`, as
  `%{id => briefing}` (task 01a15ee1 stage 5). Ids that are not uuids, name
  nothing, or name another person's briefing are left out.
  """
  @spec list_for_user([term()], term()) :: %{binary() => Briefing.t()}
  def list_for_user(briefing_ids, user_id) when is_list(briefing_ids) and is_binary(user_id) do
    ids = Enum.filter(briefing_ids, &(is_binary(&1) and Platform.UUID.valid?(&1)))

    if ids == [] or not Platform.UUID.valid?(user_id) do
      %{}
    else
      from(b in Briefing, where: b.id in ^ids and b.user_id == ^user_id)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})
    end
  end

  def list_for_user(_briefing_ids, _user_id), do: %{}

  @doc "Every briefing row that renders `insight_id`."
  @spec containing(binary()) :: [Briefing.t()]
  def containing(insight_id) when is_binary(insight_id) do
    key = BriefingCard.node_key(insight_id)

    from(b in Briefing, where: fragment("jsonb_exists(?, ?)", b.items, ^key))
    |> Repo.all()
    |> Enum.filter(&(insight_id(&1, key) == insight_id))
  end

  # ── Inbox clearing (task 01a15ee1 stage 1, ADR 0049) ─────────────────

  @doc """
  Whether the Inbox row for briefing `briefing_id` can be cleared:
  `Platform.Inbox`'s reconciler dismisses it when this is true.

  True iff the briefing row EXISTS and its `digest_date` is more than
  `Platform.Memory.Insight.default_ttl_days/0` days before today
  (America/Chicago, the zone `digest_date` is written in), when every item
  it carried has expired.

  Handling every item does NOT make the row stale (task 01a15ee1 stage 6,
  overruling stage 1): the row stays listed for the day and reads "All done
  · nothing waiting" (`Platform.Inbox.briefing_summary/1`), as
  the prototype inventory specifies, and an Undo that reopens an item finds
  the row still there.

  A missing briefing row or a malformed id is NOT confirmation, so the row
  survives (the reconciler's never-dismiss-what-you-cannot-confirm-dead
  rule).

  Options: `:today` (a `Date`, default today in America/Chicago).
  """
  @spec inbox_row_stale?(term(), keyword()) :: boolean()
  def inbox_row_stale?(briefing_id, opts \\ [])

  def inbox_row_stale?(briefing_id, opts) when is_binary(briefing_id) do
    with true <- Platform.UUID.valid?(briefing_id),
         %Briefing{} = briefing <- Repo.get(Briefing, briefing_id) do
      today =
        Keyword.get_lazy(opts, :today, fn ->
          Platform.Memory.Insights.Disseminator.local_date(DateTime.utc_now())
        end)

      expired?(briefing, today)
    else
      _ -> false
    end
  end

  def inbox_row_stale?(_briefing_id, _opts), do: false

  defp expired?(%Briefing{digest_date: %Date{} = date}, today),
    do: Date.diff(today, date) > Platform.Memory.Insight.default_ttl_days()

  defp expired?(_briefing, _today), do: false

  @doc """
  Whether `briefing` has an item still waiting on its owner: a key with no
  `receipts` entry whose insight is `open`. Purged items, and items settled
  elsewhere (`done` / `dismissed` without a receipt), are not open.
  """
  @spec open_item?(Briefing.t()) :: boolean()
  def open_item?(%Briefing{items: %{} = items} = briefing) when map_size(items) > 0 do
    receipts = briefing.receipts || %{}

    ids =
      for {key, id} <- items,
          not Map.has_key?(receipts, key),
          is_binary(id) and Platform.UUID.valid?(id),
          do: id

    ids != [] and
      Repo.exists?(from(i in Insight, where: i.id in ^ids and i.state == "open"))
  end

  def open_item?(_briefing), do: false

  # Belt and braces for the stage 6 rule above: when a handle or an undo
  # leaves the briefing with an open item and its Inbox row is dismissed (by
  # the pre-stage-6 reconciler rule, or by hand), bring the row back.
  # Reopening an item is new pending work, so a hand dismissal does not
  # keep it hidden; an expired briefing stays dismissed (the reconciler
  # would dismiss it again).
  defp maybe_relist(%Briefing{} = briefing) do
    if open_item?(briefing) and not inbox_row_stale?(briefing.id),
      do: Platform.Inbox.relist_briefing_item(briefing),
      else: :ok
  end

  # ── The Inbox briefing: view model, verbs, inverses (task 01a15ee1 stage 3)

  @verbs ~w(answer reroute apply edit_apply file got_it dismiss not_useful revert delete move)

  @doc "The verbs `handle/5` accepts, as strings."
  @spec verbs() :: [String.t()]
  def verbs, do: @verbs

  @doc """
  The read model the Inbox renders for `briefing` as seen by `scope`. Pure
  read: nothing is written. See "The Inbox briefing" in the moduledoc for
  the section rules and the item shape.
  """
  @spec view(Briefing.t(), Scope.t()) :: map()
  def view(%Briefing{} = briefing, %Scope{} = scope) do
    items = briefing.items || %{}
    receipts = briefing.receipts || %{}
    insights = load_insights(Map.values(items))
    settings = Settings.get()
    owner? = owner?(briefing, scope)

    placed =
      items
      |> Enum.map(fn {key, id} ->
        insight = Map.get(insights, id)
        receipt = Map.get(receipts, key)
        {key, insight, receipt, place(insight, receipt, settings)}
      end)
      |> Enum.sort_by(fn {key, insight, receipt, _} -> {sort_time(insight, receipt), key} end)

    rendered =
      for {key, insight, receipt, section} <- placed, section in [:needs_call, :fyi, :done] do
        {section, item(key, insight, receipt, section, scope, owner?)}
      end

    elsewhere = Enum.count(placed, fn {_, _, _, section} -> section == :elsewhere end)
    by_section = fn s -> for {^s, item} <- rendered, do: item end
    calendar = Platform.Calendar.AgentAccess.view(briefing, scope)
    needs_call = by_section.(:needs_call) ++ Enum.filter(calendar, &(&1.section == :needs_call))
    fyi = by_section.(:fyi)
    done = by_section.(:done) ++ Enum.filter(calendar, &(&1.section == :done))
    total = length(rendered) + elsewhere + length(calendar)
    open = length(needs_call) + length(fyi)

    %{
      date: briefing.digest_date,
      counts: %{total: total, open: open, calls: length(needs_call), handled: total - open},
      needs_call: needs_call,
      fyi: fyi,
      done: done
    }
  end

  defp load_insights(ids) do
    ids = Enum.filter(ids, &(is_binary(&1) and Platform.UUID.valid?(&1)))

    from(i in Insight, where: i.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  # Which section an item is in. A purged insight with no receipt is not
  # rendered (it expired unhandled); one handled somewhere else (the
  # Insights tab, an old canvas) is not rendered either, but counts as
  # handled.
  defp place(nil, nil, _settings), do: :purged
  defp place(_insight, %{} = _receipt, _settings), do: :done

  defp place(%Insight{state: "done", pre_image: %{"unattended" => true}}, nil, _settings),
    do: :done

  defp place(%Insight{state: "open"} = insight, nil, settings) do
    cond do
      needs_call?(insight, settings) -> :needs_call
      insight.action_type == "briefing" -> :fyi
      # An open page edit or task that is neither of the above (its toggle
      # is on but it was not applied) still waits on a person.
      true -> :needs_call
    end
  end

  defp place(%Insight{}, nil, _settings), do: :elsewhere

  defp needs_call?(%Insight{} = insight, settings) do
    insight.action_type == "question" or insight.tier == "needs_call" or
      Outside.outside?(insight) or
      (insight.action_type == "page_edit" and not settings.apply_page_edits) or
      needs_project?(insight)
  end

  # Recomputed, never read back: `Insight.needs_project` is in memory only.
  defp needs_project?(%Insight{action_type: "task", state: "open"} = insight),
    do: is_nil(ProjectInference.infer(insight))

  defp needs_project?(_insight), do: false

  defp sort_time(%Insight{inserted_at: %DateTime{} = at}, _receipt), do: DateTime.to_iso8601(at)
  defp sort_time(_insight, %{"at" => at}) when is_binary(at), do: at
  defp sort_time(_insight, _receipt), do: ""

  defp item(key, insight, receipt, section, scope, owner?) do
    kind = kind(insight, receipt)
    view_receipt = view_receipt(insight, receipt, section)

    %{
      key: key,
      insight: insight,
      kind: kind,
      filed_task_id: BriefingCard.filed_task_id(insight),
      meeting_card:
        Platform.Meetings.MeetingBriefings.card_for_task(
          BriefingCard.filed_task_id(insight),
          Actions.scope_actor_id(scope)
        ),
      section: section,
      receipt: view_receipt,
      project: project(kind, insight, view_receipt),
      email: insight && Outside.email(insight),
      draft: draft(kind, insight),
      may_handle?: owner? and insight != nil and Actions.may_handle?(insight, scope),
      actions: actions(section, kind, insight, view_receipt)
    }
  end

  @kinds %{
    "question" => :question,
    "page_edit" => :page_edit,
    "task" => :task,
    "briefing" => :briefing,
    "outside" => :outside
  }

  defp kind(%Insight{} = insight, _receipt) do
    if Outside.outside?(insight),
      do: :outside,
      else: Map.get(@kinds, insight.action_type, :briefing)
  end

  defp kind(nil, %{"kind" => kind}), do: Map.get(@kinds, kind, :briefing)
  defp kind(nil, _receipt), do: :briefing

  # The receipt as rendered: the stored one, or, for an item applied
  # unattended (no click, so no stored receipt), one derived from the
  # insight with `auto?: true` and no undo. `detail` is what the receipt
  # line names, read from `ref`.
  defp view_receipt(_insight, %{} = stored, :done) do
    %{
      verb: stored["verb"],
      at: stored["at"],
      by: stored["by"],
      ref: stored["ref"],
      undo: stored["undo"],
      auto?: false,
      detail: Map.merge(ref_detail(stored["ref"]), stored_detail(stored))
    }
  end

  defp view_receipt(%Insight{} = insight, nil, :done) do
    %{
      verb: if(insight.action_type == "task", do: "filed", else: "applied"),
      at: insight.acted_at && DateTime.to_iso8601(insight.acted_at),
      by: insight.acted_by,
      ref: insight.artefact_ref,
      undo: nil,
      auto?: true,
      detail: ref_detail(insight.artefact_ref)
    }
  end

  defp view_receipt(_insight, _receipt, _section), do: nil

  defp stored_detail(stored) do
    [name: "name", task_id: "task_id", project_id: "project_id", previous: "previous"]
    |> Enum.flat_map(fn {atom, string} ->
      case Map.fetch(stored, string) do
        {:ok, value} -> [{atom, value}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  @doc """
  What a receipt or artefact `ref` names: `page:<key>@v<n>` gives `%{path,
  version}`, `task:<id>` `%{task_id}`, `journal:<id>` `%{journal_entry_id}`,
  `user:<id>` `%{user_id}`, `project:<id>` `%{project_id}`, `verdict:<id>`
  `%{verdict_id}`, `page:<key>` `%{path}`; anything else `%{}`.
  """
  @spec ref_detail(term()) :: map()
  def ref_detail("page:" <> rest) do
    case Regex.run(~r/^(.+)@v(\d+)$/, rest) do
      [_, path, version] -> %{path: path, version: String.to_integer(version)}
      _ -> %{path: rest}
    end
  end

  def ref_detail("task:" <> id), do: %{task_id: id}
  def ref_detail("journal:" <> id), do: %{journal_entry_id: id}
  def ref_detail("user:" <> id), do: %{user_id: id}
  def ref_detail("project:" <> id), do: %{project_id: id}
  def ref_detail("verdict:" <> id), do: %{verdict_id: id}
  def ref_detail(_ref), do: %{}

  # A task item's project: where the filed task is NOW, else (open) the one
  # `ProjectInference` would file into. Nil for a task nobody can place.
  defp project(:task, insight, receipt) do
    task_id =
      (receipt && receipt.detail[:task_id]) || (insight && BriefingCard.filed_task_id(insight))

    project_id =
      cond do
        is_binary(task_id) ->
          Tasks.project_id_for_task(task_id)

        match?(%Insight{state: "open"}, insight) ->
          case ProjectInference.infer(insight) do
            {id, _reason} -> id
            nil -> nil
          end

        true ->
          nil
      end

    project_summary(project_id)
  end

  defp project(_kind, _insight, _receipt), do: nil

  defp project_summary(id) when is_binary(id) do
    case Tasks.get_project(id) do
      %{id: id, name: name} -> %{id: id, name: name}
      _ -> nil
    end
  end

  defp project_summary(_id), do: nil

  defp draft(:outside, %Insight{action: %{"mail_draft_id" => id}} = insight) when is_binary(id) do
    case Drafts.get(Tier.org_id(insight), id) do
      %{} = draft -> %{id: draft.id, status: draft.status, to: draft.to_addresses}
      nil -> nil
    end
  end

  defp draft(_kind, _insight), do: nil

  # The buttons an item offers. Every one is re-checked by the action.
  defp actions(:done, kind, insight, receipt) do
    undo = if match?({:ok, _}, inverse(%{"undo" => receipt.undo})), do: [:undo], else: []

    auto =
      case {receipt.auto?, kind} do
        {true, :page_edit} -> [:revert]
        {true, :task} -> [:delete]
        _ -> []
      end

    move =
      if kind == :task and match?(%Insight{state: "done"}, insight) and
           receipt.verb not in ["delete", "revert"],
         do: [:move],
         else: []

    undo ++ auto ++ move
  end

  defp actions(_open, :question, _insight, _receipt),
    do: [:answer, :reroute, :dismiss, :not_useful]

  defp actions(_open, :page_edit, _insight, _receipt),
    do: [:apply, :edit_apply, :dismiss, :not_useful]

  defp actions(_open, :task, _insight, _receipt), do: [:file, :dismiss, :not_useful]
  defp actions(_open, :briefing, _insight, _receipt), do: [:got_it, :dismiss, :not_useful]
  defp actions(_open, :outside, _insight, _receipt), do: [:dismiss, :not_useful]

  # ── handle / undo ────────────────────────────────────────────────────

  @doc """
  Handle item `key` of `briefing` with `verb` as `scope`, the clicker. See
  "The Inbox briefing" in the moduledoc. Returns `{:ok, briefing}` (the row
  with its new receipt) or `{:error, reason}`, and then nothing moved.
  """
  @spec handle(Briefing.t(), term(), term(), Scope.t(), map()) ::
          {:ok, Briefing.t()} | {:error, term()}
  def handle(briefing, key, verb, scope, params \\ %{})

  def handle(%Briefing{} = briefing, "calendar:" <> _ = key, verb, %Scope{} = scope, _params),
    do: Platform.Calendar.AgentAccess.handle(briefing, key, verb, scope)

  def handle(%Briefing{id: briefing_id}, key, verb, %Scope{} = scope, params) do
    params = if is_map(params), do: params, else: %{}

    with %Briefing{} = briefing <- Repo.get(Briefing, briefing_id) || {:error, :not_found},
         :ok <- owner(briefing, scope),
         insight_id when is_binary(insight_id) <-
           insight_id(briefing, key) || {:error, :not_found},
         {:ok, verb} <- known_verb(verb),
         :ok <- ensure_unfiled(insight_id, verb) do
      prev = Map.get(briefing.receipts || %{}, key)

      in_transaction(briefing, fn ->
        with {:ok, outcome} <- run_verb(verb, insight_id, scope, params) do
          receipt =
            outcome
            |> Map.drop([:insight])
            |> Map.merge(%{
              "verb" => verb,
              "at" => DateTime.to_iso8601(DateTime.utc_now()),
              "by" => Actions.scope_actor_id(scope),
              "kind" => receipt_kind(outcome[:insight])
            })
            |> Map.new(fn {k, v} -> {to_string(k), v} end)
            |> maybe_prev(prev)

          put_receipt(briefing.id, key, receipt)
        end
      end)
    end
  end

  @doc """
  The persistent inverse of item `key`'s receipt (the receipt's Undo /
  Restore / Delete / Revert / Move back), as `scope`, the clicker. See "The
  Inbox briefing" in the moduledoc. `{:error, :no_inverse}` for a receipt
  without one (revert and delete).
  """
  @spec undo(Briefing.t(), term(), Scope.t()) :: {:ok, Briefing.t()} | {:error, term()}
  def undo(%Briefing{id: briefing_id}, key, %Scope{} = scope) do
    with %Briefing{} = briefing <- Repo.get(Briefing, briefing_id) || {:error, :not_found},
         :ok <- owner(briefing, scope),
         insight_id when is_binary(insight_id) <-
           insight_id(briefing, key) || {:error, :not_found},
         %{} = receipt <- Map.get(briefing.receipts || %{}, key) || {:error, :not_found},
         {:ok, inverse} <- inverse(receipt) do
      in_transaction(briefing, fn ->
        with {:ok, _result} <- run_undo(inverse, insight_id, scope) do
          put_receipt(briefing.id, key, receipt["prev"])
        end
      end)
    end
  end

  defp inverse(%{"undo" => %{"verb" => verb} = inverse}) when is_binary(verb), do: {:ok, inverse}
  defp inverse(_receipt), do: {:error, :no_inverse}

  defp owner(%Briefing{user_id: user_id}, %Scope{actor: %User{id: user_id}} = scope)
       when is_binary(user_id) do
    if Scope.guest?(scope), do: {:error, :unauthorized}, else: :ok
  end

  defp owner(_briefing, _scope), do: {:error, :unauthorized}

  defp owner?(briefing, scope), do: owner(briefing, scope) == :ok

  defp known_verb(verb) when is_atom(verb) and not is_nil(verb),
    do: known_verb(Atom.to_string(verb))

  defp known_verb(verb) when verb in @verbs, do: {:ok, verb}
  defp known_verb(_verb), do: {:error, :not_supported}

  # ONE transaction for the action and its receipt; the insight broadcasts
  # the action makes are held until it commits, then `{:inbox_changed,
  # user_id}` goes out.
  defp in_transaction(%Briefing{user_id: user_id}, fun) do
    Insights.with_deferred_broadcasts(fn ->
      Repo.transaction(fn ->
        case fun.() do
          {:ok, value} -> value
          {:error, reason} -> Repo.rollback(reason)
          other -> Repo.rollback(other)
        end
      end)
    end)
    |> case do
      {:ok, briefing} ->
        maybe_relist(briefing)

        Phoenix.PubSub.broadcast(
          Platform.PubSub,
          Platform.Inbox.topic(user_id),
          {:inbox_changed, user_id}
        )

        {:ok, briefing}

      {:error, _} = error ->
        error
    end
  end

  defp ensure_unfiled(id, verb) when verb in ["apply", "file", "edit_apply"] do
    if BriefingCard.filed_task_id(Insights.get(id)),
      do: {:error, :already_handled},
      else: :ok
  end

  defp ensure_unfiled(_id, _verb), do: :ok

  defp run_verb("answer", id, scope, params) do
    with {:ok, acted} <- Actions.answer(id, scope, params["answer"]) do
      {:ok, %{insight: acted, ref: acted.artefact_ref, undo: %{"verb" => "unanswer"}}}
    end
  end

  defp run_verb("reroute", id, scope, params) do
    before = Insights.get(id)
    previous = before && before.addressee_user_id

    with {:ok, rerouted} <- Actions.reroute(id, scope, params["addressee"]) do
      to = rerouted.addressee_user_id

      {:ok,
       %{
         insight: rerouted,
         ref: "user:" <> to,
         name: Map.get(Routing.names([to]), to),
         previous: previous,
         # Back to whoever had it; an insight that had no resolvable
         # addressee (an outside email, an unrouted one) cannot be routed
         # back to nobody, so it has no inverse.
         undo: if(is_binary(previous), do: %{"verb" => "reroute", "addressee" => previous})
       }}
    end
  end

  defp run_verb("apply", id, scope, _params) do
    with {:ok, acted} <- Actions.act(id, scope), do: {:ok, acted_outcome(acted)}
  end

  defp run_verb("edit_apply", id, scope, params) do
    with {:ok, _edited} <- Actions.edit(id, scope, Map.take(params, ["body", "hunks"])),
         {:ok, acted} <- Actions.act(id, scope) do
      {:ok, acted_outcome(acted)}
    end
  end

  defp run_verb("file", id, scope, params) do
    with {:ok, acted} <-
           Actions.act(id, scope, project_id: params["project_id"], title: params["title"]) do
      {:ok, acted_outcome(acted)}
    end
  end

  defp run_verb("got_it", id, scope, _params) do
    with {:ok, acted} <- Actions.looks_right(id, scope),
         do: {:ok, %{insight: acted, ref: nil, undo: %{"verb" => "restore"}}}
  end

  defp run_verb("dismiss", id, scope, _params) do
    with {:ok, dismissed} <- Actions.dismiss(id, scope),
         do: {:ok, %{insight: dismissed, ref: nil, undo: %{"verb" => "restore"}}}
  end

  defp run_verb("not_useful", id, scope, params) do
    with {:ok, rejected} <- Actions.reject(id, scope, params["reason"]) do
      verdict_id = Actions.latest_rejection_id(rejected, Actions.scope_actor_id(scope))

      {:ok,
       %{
         insight: rejected,
         ref: verdict_id && "verdict:" <> verdict_id,
         undo: %{"verb" => "restore", "verdict_id" => verdict_id}
       }}
    end
  end

  defp run_verb("revert", id, scope, _params) do
    path =
      case Insights.get(id) do
        %Insight{pre_image: %{"file_key" => key}} when is_binary(key) -> "page:" <> key
        _ -> nil
      end

    with {:ok, reverted} <- Actions.revert(id, scope),
         do: {:ok, %{insight: reverted, ref: path, undo: nil}}
  end

  defp run_verb("delete", id, scope, _params) do
    task_id = filed_task_id(Insights.get(id))

    with {:ok, undone} <- Actions.delete_filed_task(id, scope),
         do: {:ok, %{insight: undone, ref: task_id && "task:" <> task_id, undo: nil}}
  end

  defp run_verb("move", id, scope, params) do
    before = Insights.get(id)
    task_id = filed_task_id(before)
    from_project = task_id && Tasks.project_id_for_task(task_id)

    with {:ok, moved} <- Actions.move_filed_task(id, scope, params["project_id"]) do
      {:ok,
       %{
         insight: before,
         ref: "project:" <> moved.project_id,
         task_id: moved.id,
         project_id: moved.project_id,
         undo: %{"verb" => "move", "project_id" => from_project}
       }}
    end
  end

  defp filed_task_id(%Insight{} = insight), do: BriefingCard.filed_task_id(insight)
  defp filed_task_id(_insight), do: nil

  defp acted_outcome(%Insight{} = acted) do
    undo =
      case acted.action_type do
        "page_edit" -> %{"verb" => "revert"}
        "task" -> %{"verb" => "delete"}
        _ -> nil
      end

    task_id = BriefingCard.filed_task_id(acted)

    base = %{insight: acted, ref: acted.artefact_ref, undo: undo}

    if task_id,
      do: Map.merge(base, %{task_id: task_id, project_id: Tasks.project_id_for_task(task_id)}),
      else: base
  end

  defp run_undo(%{"verb" => "revert"}, id, scope), do: Actions.revert(id, scope)
  defp run_undo(%{"verb" => "delete"}, id, scope), do: Actions.delete_filed_task(id, scope)

  defp run_undo(%{"verb" => "move", "project_id" => project_id}, id, scope),
    do: Actions.move_filed_task(id, scope, project_id)

  defp run_undo(%{"verb" => "reroute", "addressee" => addressee}, id, scope),
    do: Actions.reroute(id, scope, addressee)

  defp run_undo(%{"verb" => "restore"} = inverse, id, scope),
    do: Insights.restore(id, scope, verdict_id: inverse["verdict_id"])

  defp run_undo(%{"verb" => "unanswer"}, id, scope), do: Actions.unanswer(id, scope)
  defp run_undo(_inverse, _id, _scope), do: {:error, :no_inverse}

  defp receipt_kind(%Insight{} = insight) do
    if Outside.outside?(insight), do: "outside", else: insight.action_type
  end

  defp receipt_kind(_insight), do: nil

  # A receipt that replaces an earlier one (a move after a filing) keeps it,
  # so the move's undo puts the earlier receipt back.
  defp maybe_prev(receipt, %{} = prev), do: Map.put(receipt, "prev", prev)
  defp maybe_prev(receipt, _prev), do: receipt

  # Under a row lock, so an action that wrote receipts itself in this
  # transaction (`Actions.move_filed_task/4`) is read, not overwritten
  # blind. `nil` removes the key.
  defp put_receipt(briefing_id, key, receipt) do
    briefing = Repo.one(from(b in Briefing, where: b.id == ^briefing_id, lock: "FOR UPDATE"))

    receipts =
      case receipt do
        nil -> Map.delete(briefing.receipts || %{}, key)
        %{} -> Map.put(briefing.receipts || %{}, key, receipt)
      end

    briefing |> Briefing.changeset(%{receipts: receipts}) |> Repo.update()
  end

  # ── Node ids ─────────────────────────────────────────────────────────

  @doc "The ids of an item's line nodes (whichever section it is in)."
  @spec line_ids(String.t()) :: [String.t()]
  def line_ids(key),
    do: ["done-" <> key, "question-" <> key, "call-" <> key, "applied-" <> key]

  @doc "The ids of an item's controls (see the moduledoc)."
  @spec control_ids(String.t()) :: [String.t()]
  def control_ids(key),
    do: [
      "done-actions-" <> key,
      "applied-actions-" <> key,
      "applied-link-" <> key,
      "insight_flag_reason:" <> key,
      "insight_answer:" <> key
    ]

  @doc "The id of the note that replaces an item's controls."
  @spec note_id(String.t()) :: String.t()
  def note_id(key), do: "note-" <> key

  @doc "The id of the Flag-only row a Looks-right line keeps (stage 6)."
  @spec flag_actions_id(String.t()) :: String.t()
  def flag_actions_id(key), do: "flag-actions-" <> key

  @doc """
  The stored nodes of a SETTLED item on `document` (its line, its note and,
  after Looks right, its Flag row or open flag form), or nil when the item
  has no note and still has a control, or has no line at all.
  """
  @spec settled_nodes(map(), String.t()) :: [map()] | nil
  def settled_nodes(document, key) when is_map(document) and is_binary(key) do
    controls? = Enum.any?(control_ids(key), &CanvasDocument.get_node(document, &1))
    note = CanvasDocument.get_node(document, note_id(key))

    line =
      Enum.find_value(line_ids(key), fn id ->
        case CanvasDocument.get_node(document, id) do
          %{} = node -> node
          nil -> nil
        end
      end)

    cond do
      is_nil(line) ->
        nil

      note != nil ->
        flag =
          Enum.find_value([flag_actions_id(key), "insight_flag_reason:" <> key], fn id ->
            CanvasDocument.get_node(document, id)
          end)

        Enum.map(Enum.reject([line, note, flag], &is_nil/1), &strip_children/1)

      controls? ->
        nil

      line["id"] == "call-" <> key and not retracted?(line) ->
        nil

      true ->
        [strip_children(line)]
    end
  end

  def settled_nodes(_document, _key), do: nil

  defp retracted?(%{"props" => %{"value" => "Retracted: " <> _}}), do: true
  defp retracted?(_node), do: false

  defp strip_children(node), do: Map.delete(node, "children")

  # ── Updates ──────────────────────────────────────────────────────────

  @doc """
  Replace the Looks right / Flag row of `key` on `briefing`'s canvas, the
  Revert or Delete task / Flag row of an applied item, or the Flag-only row
  a Looks-right line keeps, with the inline flag form
  (`insight_flag_reason:<key>`, one required `reason`).
  `{:error, :not_found}` when neither row is there (retracted, answered, or
  the form is already open).
  """
  @spec open_flag_form(Briefing.t(), String.t()) :: :ok | {:error, term()}
  def open_flag_form(%Briefing{} = briefing, key) when is_binary(key) do
    form =
      node("form", "insight_flag_reason:" <> key, %{
        "title" => "Why is this wrong?",
        "submit_label" => "Flag",
        "fields" => [
          %{
            "name" => "reason",
            "type" => "textarea",
            "label" => "Required. Your reason is kept and used to teach dreaming.",
            "required" => true
          }
        ]
      })

    rows = ["done-actions-" <> key, "applied-actions-" <> key, flag_actions_id(key)]

    patch_canvas(briefing.canvas_id, fn document ->
      case Enum.find_value(rows, &non_empty(swap_ops(document, &1, [form]))) do
        nil -> {:error, :not_found}
        ops -> {:ok, ops}
      end
    end)
  end

  @doc """
  Settle `insight_id` on every briefing that renders it: its controls are
  replaced by a note reading `note`. The line itself is kept.

  `flag: true` (Looks right, stage 6) keeps a Flag-only row
  (`flag-actions-<key>`) under the note, because a confirmed line can still
  turn out wrong.
  """
  @spec settle(binary(), String.t(), keyword()) :: :ok
  def settle(insight_id, note, opts \\ []) when is_binary(insight_id) and is_binary(note) do
    key = BriefingCard.node_key(insight_id)
    note_node = text(note_id(key), note, "text-sm text-subtle")

    flag_row =
      if Keyword.get(opts, :flag, false),
        do: [
          node("action_row", flag_actions_id(key), %{
            "actions" => [
              %{"label" => "Flag", "value" => "insight_flag:" <> key, "variant" => "ghost"}
            ]
          })
        ],
        else: []

    each_canvas(insight_id, fn document ->
      {:ok, settle_ops(document, control_ids(key), [note_node | flag_row])}
    end)
  end

  @doc """
  Retract `insight_id` on every briefing that renders it: the line reads
  `"Retracted: <reason>"` and its controls are removed, as are a Looks-right
  note and Flag row.
  """
  @spec retract(binary(), String.t()) :: :ok
  def retract(insight_id, reason) when is_binary(insight_id) and is_binary(reason) do
    key = BriefingCard.node_key(insight_id)

    each_canvas(insight_id, fn document ->
      line_ops =
        for id <- line_ids(key), CanvasDocument.get_node(document, id) do
          {:set_props, id, %{"value" => "Retracted: " <> String.trim(reason)}}
        end

      # The controls go first: `replace_children` rewrites the card from the
      # document as read, so a `set_props` before it would be overwritten.
      removed = control_ids(key) ++ [flag_actions_id(key), note_id(key)]
      {:ok, settle_ops(document, removed, []) ++ line_ops}
    end)
  end

  defp non_empty([]), do: nil
  defp non_empty(ops), do: ops

  # The first of `ids` present on `document` is swapped for `replacement`
  # (in place, so the note sits where the buttons were); the rest are
  # deleted.
  defp settle_ops(document, ids, replacement) do
    present = Enum.filter(ids, &CanvasDocument.get_node(document, &1))

    case present do
      [] ->
        []

      [first | rest] ->
        swap_ops(document, first, replacement) ++ Enum.map(rest, &{:delete_node, &1})
    end
  end

  # One `replace_children` on the parent of `node_id`, putting `replacement`
  # where `node_id` was. `[]` when the node is not on the document.
  defp swap_ops(document, node_id, replacement) do
    case parent_of(document["root"], node_id) do
      %{"id" => parent_id, "children" => children} ->
        new_children =
          Enum.flat_map(children, fn
            %{"id" => ^node_id} -> replacement
            child -> [child]
          end)

        [{:replace_children, parent_id, new_children}]

      nil ->
        []
    end
  end

  defp parent_of(%{"children" => children} = node, node_id) when is_list(children) do
    if Enum.any?(children, &match?(%{"id" => ^node_id}, &1)),
      do: node,
      else: Enum.find_value(children, &parent_of(&1, node_id))
  end

  defp parent_of(_node, _node_id), do: nil

  # Only rows that have a canvas: an Inbox briefing (canvas_id nil) has
  # nothing to patch.
  defp each_canvas(insight_id, ops_fun) do
    insight_id
    |> containing()
    |> Enum.each(fn briefing -> patch_canvas(briefing.canvas_id, ops_fun) end)
  end

  # No canvas, nothing to patch: a skip, never a raise. `open_flag_form/2`
  # reads it as "no flag row to open".
  defp patch_canvas(nil, _ops_fun), do: {:error, :not_found}
  defp patch_canvas(canvas_id, ops_fun), do: patch(canvas_id, ops_fun)

  defp patch(canvas_id, ops_fun) do
    with %Canvas{} = canvas <- Chat.get_canvas(canvas_id) || {:error, :canvas_not_found},
         {:ok, %{document: document}} <- CanvasServer.describe(canvas.id),
         {:ok, ops} when ops != [] <- ops_fun.(document),
         {:ok, _canvas} <- Chat.patch_canvas(:system, canvas, ops) do
      :ok
    else
      {:ok, []} ->
        :ok

      {:error, :not_found} = error ->
        error

      other ->
        Logger.warning(
          "[insight_briefings] canvas #{canvas_id} not updated: " <> inspect(other, limit: 5)
        )

        {:error, :canvas_update_failed}
    end
  end

  defp text(id, value, class),
    do: node("text", id, %{"value" => value, "class_overrides" => class})

  defp node(type, id, props), do: %{"type" => type, "id" => id, "props" => props}
end
