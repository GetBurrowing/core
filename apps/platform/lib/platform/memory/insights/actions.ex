defmodule Platform.Memory.Insights.Actions do
  @moduledoc """
  What a click on an insight does. Task
  `01a13867-3213-7001-a128-6b4c6b34283f`, stage 2. Called through
  `Platform.Memory.Insights.act/3`, `reroute/3`, `dismiss/2`, `revert/2` and
  `edit/3`.

  ## Every action is the CLICKER's

  Each function takes the clicker's `%Platform.Access.Scope{}`. The caller
  re-loads it for the click (it is never the one built at mount), and this
  module decides on it alone: an insight carries no authority of its own.

  ## Nothing runs late

  Every function re-reads the insight row first. A row that is gone (the
  purge deleted it) or whose `expires_at` is at or before now answers
  `{:error, :expired}` and executes nothing. This is what keeps an admin who
  approves a `needs_call` insight after its TTL from running it.

  ## act/3

  The tier is re-checked (`Platform.Memory.Insights.Tier.classify/1`). A
  `needs_call` insight is executed only when
  `Platform.Access.authorize_install/1` is `:ok` (today's admin-only check);
  anyone else gets `{:error, :unauthorized}`. Then, by action type:

    * `page_edit`: the clicker needs `memory.write` on `{:memory, key}`.
      The hunks are applied to the CURRENT content only on an exact match
      (`Platform.Memory.Insights.Hunks`), else `{:error, :stale}` and the
      page is untouched. The write is `Wiki.upsert_page/3` with
      `expected_version` set to the version the hunks were applied to, so a
      concurrent edit is also `:stale`. The pre-image (content and version)
      is stored on the insight and `artefact_ref` is `"page:<key>@v<n>"`.
    * `task`: filed through the fenced Tasks write path:
      `Platform.Access.task_target/3` on `{:project, id}` with
      `tasks.write`, then `Platform.Tasks.create_task/2` with the
      addressee as sponsor. A project outside the clicker's fence, and a
      missing one, are both `{:error, :not_found}`.
    * `question`, `briefing` (stage 4): delivered NOW into the addressee's
      briefing for today, creating the day's canvas or adding to it
      (`Platform.Memory.Insights.Disseminator.deliver_now/3`). This works
      with dissemination OFF, because a person is acting. Refused for a
      guest; `{:error, :no_addressee}` for an unrouted insight,
      `{:error, :opted_out}` when the addressee opted out, `{:error,
      :no_agent}` when nobody holds `memory.dreaming`. The insight stays
      `open` and gets `delivered_at`: the recipient's Looks right, Flag or
      Answer is its outcome.

  A successful page_edit or task act records the outcome (`state: "done"`)
  and the `accepted` signal through
  `Platform.Memory.Insights.record_outcome/3`. Its `:acted` broadcast goes
  out only after the transaction commits, here and in `answer/4` (stage 6),
  so another session's re-read sees the committed row.

  ## looks_right/3 and answer/4 (stage 4)

  The recipient's two answers to a delivered item. `looks_right/3` takes an
  open `briefing` and records it acted (`accepted` signal). `answer/4` takes
  an open `question` and a non-blank answer, appends an org journal entry
  AUTHORED BY THE ANSWERER that cites the canvas and the evidence (with a
  `<correction target=...>` block when the question names a page, so the
  Historian applies the fact), and records it acted with `artefact_ref`
  `journal:<entry_id>`. Both settle the item on every briefing canvas that
  renders it (`Platform.Memory.Insights.Briefings.settle/2`).

  Text a person or an agent wrote is written to the journal with `<` and
  `>` escaped, so an answer cannot open a `<synthesis-insight>` or a
  `<correction>` block of its own.

  ## reject/4, dismiss/3, reroute/4 (stage 5)

  The Insights tab's Reject, Dismiss and Reroute carry the same `needs_call`
  gate as `act/3`: in this slice only a root admin decides a `needs_call`
  insight, whichever button is pressed. Without it on Reroute, a member
  could reroute a `needs_call` insight to an internal person, which
  re-runs the tier to `reversible`, and then act on it.

  ## apply_unattended/2 (task 01a15587 stage 2)

  Acts on an insight with NO person clicking, as the identity
  `Platform.Memory.Insights.Unattended` names. It re-reads the row (live
  and `open`), requires the tier to be `:reversible` now
  (`{:error, :unauthorized}` otherwise) and the insight to be
  `Unattended.eligible?/1`, i.e. authored by the `memory.dreaming` holder
  (`{:error, :not_eligible}` otherwise). Then:

    * `page_edit`: the source is RE-GROUNDED through
      `Platform.Memory.Insights.Grounding.ground/1` (`grounded?/1`). One that no longer
      resolves is rewritten into the question `Grounding.ground/1` produces
      (`Insight.downgrade_changeset/2`, held to the question threshold) and
      the answer is `{:ok, :downgraded, insight}`, with nothing written to
      the page. A grounded one runs the same write body as `act/3` under
      the Historian's scope (`Unattended.page_edit_actor/1`: the wiki gate
      AND `memory.write`); `{:error, :no_historian}` or
      `{:error, :unauthorized}` writes nothing. The page's `updated_by` and
      the insight's `acted_by` are the Historian's agent id.
    * `task`: an insight with no addressee is `{:error, :no_sponsor}` and
      nothing is filed. Otherwise the same write body as `act/3` runs under
      the `memory.dreaming` holder's scope (`Unattended.task_actor/0`),
      filing into backlog with no assignee, `auto_approve_plan` false, the
      addressee as sponsor, and `reported_by` / `metadata` naming the
      insight and the agent.

  The stored `pre_image` carries `"unattended" => true` and
  `"acting_agent_id"` (with the page pre-image for a `page_edit`), so an
  undo knows the act was automatic and whose identity performed it.

  ## revert/2

  Only for an acted `page_edit` whose pre-image the row still holds, which
  is only while the row lives: pages have no revision table, so once the
  row is purged there is nothing to revert to (the TTL is 7 days,
  `Platform.Memory.Insight`'s `@default_ttl_days`; it is not extended for
  undo). The page must still be at the version the act wrote,
  `pre_image["written_version"]` (`{:error, :stale}` otherwise, page
  untouched), and only the stored pre-image content is written, as a new
  version. A person's act returns to `open`; an unattended act is
  `dismissed` instead, so the next digest run does not apply it again.

  ## Undo from the briefing (task 01a15587 stage 4)

  An unattended act is done FOR the person whose briefing lists it, who
  often lacks `memory.write` or `tasks.write` themselves. So the RECIPIENT
  (a user with a `memory_briefings` row rendering this insight,
  `Platform.Memory.Insights.Briefings.containing/1`) may undo THIS
  insight's own artefact, and the undo runs as the identity that acted
  (`Platform.Memory.Insights.Unattended.undo_page_edit_actor/2` /
  `undo_task_actor/1`, from `pre_image["acting_agent_id"]`). The clicker is
  the actor of the verdict that `Platform.Memory.Insights` records for the
  undo, not of the write.

    * `revert/2` on an unattended page_edit: for the recipient, the write
      is the acting agent's (`updated_by` = that agent, its wiki gate and
      `memory.write` re-checked now). Anyone else needs `memory.write`
      themselves, exactly as for a person's act.
    * `delete_filed_task/3`: recipient only, unattended `task` only. The
      task is the one `artefact_ref` names
      (`Platform.Memory.Insights.BriefingCard.filed_task_id/1`), it must
      carry this insight's id in its metadata, still be `backlog` and not
      deleted (else `{:error, :not_retractable}`), and the acting agent's
      scope must still have `tasks.write` on it. Then
      `Platform.Tasks.soft_delete_task/1`, and the insight is `dismissed`.
  """

  alias Platform.Access
  alias Platform.Access.Scope
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights
  alias Platform.Memory.Insights.BriefingCard
  alias Platform.Memory.Insights.Briefings
  alias Platform.Memory.Insights.Disseminator
  alias Platform.Memory.Insights.Grounding
  alias Platform.Memory.Insights.Hunks
  alias Platform.Memory.Insights.Routing
  alias Platform.Memory.Insights.Tier
  alias Platform.Memory.Insights.Unattended
  alias Platform.Org.Wiki
  alias Platform.Org.Wiki.Journal
  alias Platform.Repo
  alias Platform.Tasks

  @type error ::
          :expired
          | :unauthorized
          | :stale
          | :not_found
          | :not_open
          | :not_supported
          | :not_revertible
          | :invalid
          | :blank
          | :no_addressee
          | :no_agent
          | :opted_out
          | :not_eligible
          | :no_sponsor
          | :no_historian
          | :not_retractable

  @title_max 255

  # ── act ──────────────────────────────────────────────────────────────

  @doc "Execute an insight for `scope`. See the moduledoc."
  @spec act(Insight.t() | binary(), Scope.t(), keyword()) ::
          {:ok, Insight.t()} | {:error, error() | Ecto.Changeset.t()}
  def act(insight_or_id, %Scope{} = scope, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, insight} <- live(insight_or_id, now),
         :ok <- open(insight),
         :ok <- tier_permits(insight, scope) do
      execute(insight, scope, now, nil)
    end
  end

  defp tier_permits(insight, scope) do
    case Tier.classify(insight) do
      :reversible -> :ok
      :needs_call -> if Access.authorize_install(scope) == :ok, do: :ok, else: unauthorized()
    end
  end

  # The one write body for a page_edit and a task, shared by the person's
  # `act/3` (`acting` nil) and `apply_unattended/2` (`acting` the agent that
  # acts). `scope` is whose authority the write runs under in both cases.
  defp execute(%Insight{action_type: "page_edit"} = insight, scope, now, acting) do
    key = Map.get(insight.action, "target")

    with true <- is_binary(key) || {:error, :invalid},
         :ok <- may_write_memory(scope, key),
         %{} = page <- Wiki.get_page(key, workspace_id: insight.workspace_id) || not_found(),
         {:ok, content} <- apply_hunks(page.content, insight.action["hunks"]) do
      Repo.transaction(fn ->
        with {:ok, written} <-
               Wiki.upsert_page(
                 page.file_key,
                 %{content: content, updated_by: actor_id(scope)},
                 workspace_id: insight.workspace_id,
                 expected_version: page.version
               ),
             {:ok, acted} <-
               Insights.record_outcome(insight, :acted,
                 broadcast: false,
                 actor_id: actor_id(scope),
                 now: now,
                 artefact_ref: "page:#{written.file_key}@v#{written.version}",
                 pre_image:
                   Map.merge(
                     %{
                       "file_key" => page.file_key,
                       "content" => page.content,
                       "version" => page.version,
                       "written_version" => written.version
                     },
                     unattended_marker(acting)
                   )
               ) do
          acted
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> broadcast_ok(:acted)
    end
  end

  defp execute(%Insight{action_type: "task"} = insight, scope, now, acting) do
    project_id = Map.get(insight.action, "project_id") || Map.get(insight.action, "target")

    case Access.task_target(scope, {:project, project_id}, "tasks.write") do
      {:ok, {:project, project_id}} ->
        Repo.transaction(fn ->
          with {:ok, task} <- Tasks.create_task(task_attrs(insight, project_id, acting)),
               {:ok, acted} <-
                 Insights.record_outcome(insight, :acted,
                   broadcast: false,
                   actor_id: actor_id(scope),
                   now: now,
                   artefact_ref: "task:#{task.id}",
                   pre_image: unattended_pre_image(acting)
                 ) do
            acted
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
        |> broadcast_ok(:acted)

      _ ->
        not_found()
    end
  end

  defp execute(%Insight{action_type: type} = insight, scope, now, nil)
       when type in ["question", "briefing"] do
    with :ok <- internal(scope),
         user_id when is_binary(user_id) <- insight.addressee_user_id || {:error, :no_addressee},
         {:ok, _added} <- Disseminator.deliver_now(user_id, [insight], now: now) do
      {:ok, Insights.get(insight.id) || insight}
    end
  end

  defp execute(%Insight{}, _scope, _now, _acting), do: {:error, :not_supported}

  # A person's act files with the defaults. An unattended act files into
  # backlog with no assignee and no auto-approval, and names the insight
  # and the filing agent, so the task is a proposal a person picks up.
  defp task_attrs(insight, project_id, acting) do
    base = %{
      project_id: project_id,
      title: task_title(insight),
      description: insight.body <> "\n\n_Filed from a dreaming insight (#{insight.id})._",
      sponsor_user_id: insight.addressee_user_id
    }

    case acting do
      nil ->
        base

      %Agent{} = agent ->
        Map.merge(base, %{
          status: "backlog",
          auto_approve_plan: false,
          reported_by: "dreaming insight #{insight.id} (agent #{agent.slug})",
          metadata: %{"insight_id" => insight.id, "filed_by_agent_id" => agent.id}
        })
    end
  end

  # What `revert/2` and the stage-4 undo read to know an act was unattended
  # and who acted.
  defp unattended_marker(nil), do: %{}

  defp unattended_marker(%Agent{id: id}),
    do: %{"unattended" => true, "acting_agent_id" => id}

  defp unattended_pre_image(nil), do: nil
  defp unattended_pre_image(%Agent{} = agent), do: unattended_marker(agent)

  defp task_title(insight) do
    insight.action
    |> Map.get("title")
    |> Kernel.||(insight.body |> String.split("\n", trim: true) |> List.first() || "Insight")
    |> String.trim()
    |> String.slice(0, @title_max)
  end

  defp apply_hunks(content, hunks) do
    case Hunks.apply_all(content || "", hunks) do
      {:ok, new_content} -> {:ok, new_content}
      :stale -> {:error, :stale}
    end
  end

  # ── apply_unattended (task 01a15587 stage 2) ─────────────────────────

  @doc """
  Act on an insight with no person clicking. See "apply_unattended/2" in
  the moduledoc.
  """
  @spec apply_unattended(Insight.t() | binary(), keyword()) ::
          {:ok, Insight.t()}
          | {:ok, :downgraded, Insight.t()}
          | {:error, error() | Ecto.Changeset.t()}
  def apply_unattended(insight_or_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, insight} <- live(insight_or_id, now),
         :ok <- open(insight),
         :ok <- reversible(insight),
         :ok <- eligible(insight) do
      unattended(insight, now)
    end
  end

  defp reversible(insight) do
    case Tier.classify(insight) do
      :reversible -> :ok
      :needs_call -> unauthorized()
    end
  end

  defp eligible(insight),
    do: if(Unattended.eligible?(insight), do: :ok, else: {:error, :not_eligible})

  defp unattended(%Insight{action_type: "page_edit"} = insight, now) do
    case Grounding.ground(Map.from_struct(insight)) do
      %{action_type: "page_edit"} ->
        with key when is_binary(key) <- Map.get(insight.action, "target") || {:error, :invalid},
             {:ok, agent, scope} <- Unattended.page_edit_actor(key) do
          execute(insight, scope, now, agent)
        end

      question ->
        downgrade(insight, question)
    end
  end

  defp unattended(%Insight{action_type: "task"} = insight, now) do
    with user_id when is_binary(user_id) <- insight.addressee_user_id || {:error, :no_sponsor},
         {:ok, agent, scope} <- Unattended.task_actor() do
      execute(insight, scope, now, agent)
    end
  end

  defp unattended(%Insight{}, _now), do: {:error, :not_supported}

  # The source no longer resolves: rewrite the row into the question
  # grounding would have produced at ingest. Nothing touches the page.
  defp downgrade(%Insight{} = insight, grounded) do
    question = struct(insight, Map.take(grounded, [:action_type, :addressee_user_id, :action]))

    attrs =
      grounded
      |> Map.take([
        :action_type,
        :downgraded_from,
        :body,
        :action,
        :addressee_user_id,
        :addressee_reason
      ])
      |> Map.merge(%{
        tier: Tier.label(Tier.classify(question)),
        disseminable: Insights.disseminable?(question)
      })

    case insight |> Insight.downgrade_changeset(attrs) |> Repo.update() do
      {:ok, downgraded} ->
        Insights.broadcast(:edited, downgraded)
        {:ok, :downgraded, downgraded}

      {:error, _changeset} = error ->
        error
    end
  end

  # ── looks_right / answer (stage 4) ───────────────────────────────────

  @doc "The recipient confirms a delivered briefing line. See the moduledoc."
  @spec looks_right(Insight.t() | binary(), Scope.t(), keyword()) ::
          {:ok, Insight.t()} | {:error, error() | Ecto.Changeset.t()}
  def looks_right(insight_or_id, %Scope{} = scope, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, insight} <- live(insight_or_id, now),
         :ok <- open(insight),
         :ok <- of_type(insight, "briefing"),
         :ok <- internal(scope),
         {:ok, acted} <-
           Insights.record_outcome(insight, :acted, actor_id: actor_id(scope), now: now) do
      # "Looks right" means confirmed for now, not final: the line keeps a
      # Flag-only row (stage 6), and `Insights.flag/3` accepts a done insight.
      Briefings.settle(acted.id, "Marked as right.", flag: true)
      {:ok, acted}
    end
  end

  @doc "The recipient answers a delivered question. See the moduledoc."
  @spec answer(Insight.t() | binary(), Scope.t(), String.t() | nil, keyword()) ::
          {:ok, Insight.t()} | {:error, error() | Ecto.Changeset.t()}
  def answer(insight_or_id, %Scope{} = scope, answer, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, insight} <- live(insight_or_id, now),
         :ok <- open(insight),
         :ok <- of_type(insight, "question"),
         :ok <- internal(scope),
         {:ok, text} <- non_blank(answer),
         author when is_binary(author) <- actor_id(scope) || unauthorized() do
      content = answer_entry(insight, text, Keyword.get(opts, :canvas_id))

      Repo.transaction(fn ->
        with {:ok, entry} <-
               Journal.append(
                 %{
                   content: content,
                   date: DateTime.to_date(now),
                   workspace_id: insight.workspace_id,
                   org_id: insight.org_id,
                   authored_by: author,
                   metadata: %{"source" => "insight_answer", "insight_id" => insight.id}
                 },
                 namespace: "org"
               ),
             {:ok, acted} <-
               Insights.record_outcome(insight, :acted,
                 broadcast: false,
                 actor_id: author,
                 now: now,
                 artefact_ref: "journal:#{entry.id}"
               ) do
          acted
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> broadcast_ok(:acted)
      |> case do
        {:ok, acted} ->
          Briefings.settle(acted.id, "Answered: " <> text)
          {:ok, acted}

        error ->
          error
      end
    end
  end

  @page_target ~r/^[A-Za-z0-9_\-\/\.]+$/

  @doc """
  The journal entry `answer/4` writes (public for tests):
  `Answer to: <question> - <answer> (source: briefing canvas <canvas_id>;
  evidence: <evidence>)`, plus a `<correction target="<page>">` block when
  the question names a page.
  """
  @spec answer_entry(Insight.t(), String.t(), binary() | nil) :: String.t()
  def answer_entry(%Insight{} = insight, answer, canvas_id) do
    question = inert(insight.body)
    answer = inert(answer)
    source = if is_binary(canvas_id), do: "briefing canvas #{canvas_id}", else: "Insights tab"

    evidence =
      case insight.evidence do
        e when is_binary(e) and e != "" -> inert(e)
        _ -> "none"
      end

    line = "Answer to: #{question} - #{answer} (source: #{source}; evidence: #{evidence})"

    case target_page(insight) do
      nil ->
        line

      page ->
        line <>
          "\n\n<correction target=\"#{page}\">\n#{question}\nAnswer: #{answer}\n</correction>"
    end
  end

  defp target_page(%Insight{action: %{"target" => target}}) when is_binary(target) do
    target = String.trim(target)
    if target != "" and Regex.match?(@page_target, target), do: target, else: nil
  end

  defp target_page(_insight), do: nil

  # Agent- or person-written text going into a journal: no tag may open.
  defp inert(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp inert(_text), do: ""

  defp non_blank(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, :blank}
      trimmed -> {:ok, trimmed}
    end
  end

  defp non_blank(_text), do: {:error, :blank}

  defp of_type(%Insight{action_type: type}, type), do: :ok
  defp of_type(_insight, _type), do: {:error, :not_supported}

  # ── revert ───────────────────────────────────────────────────────────

  @doc "Write an acted page_edit's pre-image back. See the moduledoc."
  @spec revert(Insight.t() | binary(), Scope.t(), keyword()) ::
          {:ok, Insight.t()} | {:error, error() | Ecto.Changeset.t()}
  def revert(insight_or_id, %Scope{} = scope, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, insight} <- live(insight_or_id, now),
         {:ok, pre} <- pre_image(insight),
         {:ok, writer} <- revert_writer(insight, pre, scope),
         %{} = page <-
           Wiki.get_page(pre["file_key"], workspace_id: insight.workspace_id) || not_found(),
         true <- page.version == pre["written_version"] || {:error, :stale} do
      Repo.transaction(fn ->
        with {:ok, _restored} <-
               Wiki.upsert_page(
                 page.file_key,
                 %{content: pre["content"], updated_by: actor_id(writer)},
                 workspace_id: insight.workspace_id,
                 expected_version: page.version
               ),
             {:ok, undone} <- undo_outcome(insight, pre) do
          undone
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> broadcast_ok(:reverted)
    end
  end

  # Whose authority the revert's write runs under (see "Undo from the
  # briefing"): the acting agent's for the recipient of an unattended act,
  # else the clicker's own `memory.write`.
  defp revert_writer(insight, %{"unattended" => true} = pre, scope) do
    if recipient?(insight, scope) do
      case Unattended.undo_page_edit_actor(pre["acting_agent_id"], pre["file_key"]) do
        {:ok, _agent, acting} -> {:ok, acting}
        {:error, _reason} -> unauthorized()
      end
    else
      clicker_writer(scope, pre["file_key"])
    end
  end

  defp revert_writer(_insight, pre, scope), do: clicker_writer(scope, pre["file_key"])

  defp clicker_writer(scope, key) do
    with :ok <- may_write_memory(scope, key), do: {:ok, scope}
  end

  # A person's act reopens; an unattended one is dismissed so the digest
  # does not select it and apply it again.
  defp undo_outcome(insight, pre) do
    state = if unattended?(pre), do: "dismissed", else: "open"

    insight
    |> Insight.outcome_changeset(%{
      state: state,
      acted_by: nil,
      acted_at: nil,
      artefact_ref: nil,
      pre_image: nil
    })
    |> Repo.update()
  end

  defp unattended?(%{"unattended" => true}), do: true
  defp unattended?(_pre), do: false

  # The recipient: a person with a briefing row that renders this insight.
  # Read from the rows, never from the click.
  defp recipient?(%Insight{id: id}, %Scope{actor: %User{id: user_id}} = scope)
       when is_binary(user_id) do
    not Scope.guest?(scope) and
      Enum.any?(Briefings.containing(id), &(&1.user_id == user_id))
  end

  defp recipient?(_insight, _scope), do: false

  # ── delete_filed_task (task 01a15587 stage 4) ────────────────────────

  @doc """
  Soft-delete the backlog task an unattended `task` insight filed, for the
  recipient of the briefing that lists it, as the agent that filed it. See
  "Undo from the briefing" in the moduledoc.
  """
  @spec delete_filed_task(Insight.t() | binary(), Scope.t(), keyword()) ::
          {:ok, Insight.t()} | {:error, error() | Ecto.Changeset.t()}
  def delete_filed_task(insight_or_id, %Scope{} = scope, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, insight} <- live(insight_or_id, now),
         {:ok, agent_id, task_id} <- filed_by_agent(insight),
         true <- recipient?(insight, scope) || unauthorized(),
         {:ok, _agent, acting} <- task_undo_actor(agent_id),
         {:ok, _typed} <- task_writable(acting, task_id),
         %Tasks.Task{} = task <- Tasks.get_task_record(task_id) || not_found(),
         :ok <- retractable(task, insight) do
      Repo.transaction(fn ->
        with {:ok, _deleted} <- Tasks.soft_delete_task(task),
             {:ok, undone} <- undo_outcome(insight, insight.pre_image) do
          undone
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> broadcast_ok(:task_deleted)
    end
  end

  defp filed_by_agent(
         %Insight{
           state: "done",
           pre_image: %{"unattended" => true, "acting_agent_id" => agent_id}
         } =
           insight
       ) do
    case BriefingCard.filed_task_id(insight) do
      task_id when is_binary(task_id) -> {:ok, agent_id, task_id}
      nil -> {:error, :not_retractable}
    end
  end

  defp filed_by_agent(_insight), do: {:error, :not_retractable}

  defp task_undo_actor(agent_id) do
    case Unattended.undo_task_actor(agent_id) do
      {:ok, _agent, _scope} = ok -> ok
      {:error, _reason} -> unauthorized()
    end
  end

  defp task_writable(scope, task_id) do
    case Access.task_target(scope, {:task, task_id}, "tasks.write") do
      {:ok, typed} -> {:ok, typed}
      :not_found -> not_found()
    end
  end

  # Only the task this insight filed, only while nobody has picked it up.
  defp retractable(%Tasks.Task{} = task, %Insight{id: insight_id}) do
    if task.status == "backlog" and is_nil(task.deleted_at) and
         is_map(task.metadata) and task.metadata["insight_id"] == insight_id,
       do: :ok,
       else: {:error, :not_retractable}
  end

  defp pre_image(%Insight{
         action_type: "page_edit",
         state: "done",
         pre_image: %{"file_key" => key, "content" => content} = pre
       })
       when is_binary(key) and is_binary(content),
       do: {:ok, pre}

  defp pre_image(_insight), do: {:error, :not_revertible}

  # ── reroute / edit / dismiss ─────────────────────────────────────────

  @doc """
  Send an open insight to someone else. `addressee` is a user email, a user
  id or an agent slug (`Routing.addressee/1`); one that names nobody is
  `{:error, :not_found}`. Sets the addressee with reason
  `"rerouted by <name>"` and re-runs the tier. Refused for a guest.
  """
  @spec reroute(Insight.t() | binary(), Scope.t(), String.t(), keyword()) ::
          {:ok, Insight.t()} | {:error, error() | Ecto.Changeset.t()}
  def reroute(insight_or_id, %Scope{} = scope, addressee, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, insight} <- live(insight_or_id, now),
         :ok <- open(insight),
         :ok <- internal(scope),
         :ok <- tier_permits(insight, scope),
         {:ok, user_id} <- reroute_target(addressee) do
      action = Map.put(insight.action, "addressee", user_id)
      rerouted = %{insight | addressee_user_id: user_id, action: action}

      insight
      |> Insight.routing_changeset(%{
        addressee_user_id: user_id,
        addressee_reason: "rerouted by #{actor_name(scope)}",
        action: action,
        tier: Tier.label(Tier.classify(rerouted))
      })
      |> Repo.update()
      |> broadcast_ok(:rerouted)
    end
  end

  defp reroute_target(addressee) do
    case Routing.addressee(addressee) do
      {user_id, _reason} when is_binary(user_id) -> {:ok, user_id}
      _ -> not_found()
    end
  end

  @doc """
  Change an open insight before acting on it: `attrs` may carry `"body"`
  and, for a `page_edit`, `"hunks"` (a list of `%{"old", "new"}`). The tier
  is re-run. Allowed to whoever could act on the insight as it stands.
  """
  @spec edit(Insight.t() | binary(), Scope.t(), map(), keyword()) ::
          {:ok, Insight.t()} | {:error, error() | Ecto.Changeset.t()}
  def edit(insight_or_id, %Scope{} = scope, attrs, opts \\ []) when is_map(attrs) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, insight} <- live(insight_or_id, now),
         :ok <- open(insight),
         :ok <- internal(scope),
         :ok <- tier_permits(insight, scope),
         :ok <- may_edit(insight, scope) do
      body = Map.get(attrs, "body") || insight.body

      action =
        case {insight.action_type, Map.get(attrs, "hunks")} do
          {"page_edit", hunks} when is_list(hunks) -> Map.put(insight.action, "hunks", hunks)
          _ -> insight.action
        end

      edited = %{insight | body: body, action: action}

      insight
      |> Insight.routing_changeset(%{
        body: body,
        action: action,
        tier: Tier.label(Tier.classify(edited))
      })
      |> Repo.update()
      |> broadcast_ok(:edited)
    end
  end

  defp may_edit(%Insight{action_type: "page_edit", action: %{"target" => key}}, scope)
       when is_binary(key),
       do: may_write_memory(scope, key)

  defp may_edit(_insight, _scope), do: :ok

  @doc """
  Dismiss an open insight without a reason (no verdict, no signal). Refused
  for a guest.
  """
  @spec dismiss(Insight.t() | binary(), Scope.t(), keyword()) ::
          {:ok, Insight.t()} | {:error, error() | Ecto.Changeset.t()}
  def dismiss(insight_or_id, %Scope{} = scope, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, insight} <- live(insight_or_id, now),
         :ok <- open(insight),
         :ok <- internal(scope),
         :ok <- tier_permits(insight, scope) do
      Insights.record_outcome(insight, :dismissed)
    end
  end

  @doc """
  Reject an open insight as the clicker `scope`, with a required reason
  (task 01a13867 stage 5, the Insights tab's Reject). The same gates as
  `dismiss/3` (live, open, not a guest, and a `needs_call` insight needs
  `Access.authorize_install/1`), then `Platform.Memory.Insights.reject/3`,
  which writes the durable `rejected` verdict. A blank or missing reason is
  `{:error, :blank}` and nothing is written.
  """
  @spec reject(Insight.t() | binary(), Scope.t(), String.t() | nil, keyword()) ::
          {:ok, Insight.t()} | {:error, error() | Ecto.Changeset.t()}
  def reject(insight_or_id, %Scope{} = scope, reason, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, insight} <- live(insight_or_id, now),
         :ok <- open(insight),
         :ok <- internal(scope),
         :ok <- tier_permits(insight, scope),
         {:ok, text} <- non_blank(reason) do
      Insights.reject(insight, text, actor_id: actor_id(scope))
    end
  end

  @doc """
  True when `scope` may press the buttons on `insight` as it stands: every
  insight for an internal member, and a `needs_call` one only with
  `Access.authorize_install/1`. Presentation only; every action re-checks.
  """
  @spec may_handle?(Insight.t(), Scope.t()) :: boolean()
  def may_handle?(%Insight{} = insight, %Scope{} = scope),
    do: internal(scope) == :ok and tier_permits(insight, scope) == :ok

  # ── shared ───────────────────────────────────────────────────────────

  @doc false
  # For `Insights.flag/3`: the same re-read every action here starts with.
  def fetch_live(insight_or_id, now), do: live(insight_or_id, now)

  @doc false
  def scope_actor_id(%Scope{} = scope), do: actor_id(scope)
  def scope_actor_id(_scope), do: nil

  # Re-read the row: a gone or expired row executes nothing.
  defp live(%Insight{id: id}, now), do: live(id, now)

  defp live(id, now) when is_binary(id) do
    case Insights.get(id) do
      %Insight{expires_at: %DateTime{} = expires_at} = insight ->
        if DateTime.compare(expires_at, now) == :gt, do: {:ok, insight}, else: {:error, :expired}

      _ ->
        {:error, :expired}
    end
  end

  defp live(_id, _now), do: {:error, :expired}

  defp open(%Insight{state: "open"}), do: :ok
  defp open(_insight), do: {:error, :not_open}

  defp may_write_memory(scope, key) when is_binary(key) do
    if Access.can?(scope, "memory.write", {:memory, key}), do: :ok, else: unauthorized()
  end

  defp may_write_memory(_scope, _key), do: unauthorized()

  defp internal(%Scope{actor: :system}), do: :ok
  defp internal(%Scope{actor: nil}), do: unauthorized()

  defp internal(%Scope{} = scope),
    do: if(Scope.guest?(scope), do: unauthorized(), else: :ok)

  defp actor_id(%Scope{actor: %AgentRuntime{agent_id: agent_id}}), do: agent_id
  defp actor_id(%Scope{actor: %{id: id}}) when is_binary(id), do: id
  defp actor_id(_scope), do: nil

  defp actor_name(%Scope{actor: %AgentRuntime{} = runtime}),
    do: runtime.display_name || runtime.runtime_id

  defp actor_name(%Scope{actor: %{name: name}}) when is_binary(name) and name != "", do: name
  defp actor_name(%Scope{actor: %{email: email}}) when is_binary(email), do: email
  defp actor_name(%Scope{actor: :system}), do: "system"
  defp actor_name(_scope), do: "someone"

  defp broadcast_ok({:ok, %Insight{} = insight} = ok, event) do
    Insights.broadcast(event, insight)
    ok
  end

  defp broadcast_ok(other, _event), do: other

  defp unauthorized, do: {:error, :unauthorized}
  defp not_found, do: {:error, :not_found}
end
