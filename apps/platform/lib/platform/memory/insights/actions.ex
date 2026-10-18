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

  ## revert/2

  Only for an acted `page_edit` whose pre-image the row still holds, which
  is only while the row lives: pages have no revision table, so once the
  row is purged there is nothing to revert to. The page must still be at
  the version the act wrote (`{:error, :stale}` otherwise, page untouched).
  The pre-image content is written back as a new version and the insight
  returns to `open`.
  """

  alias Platform.Access
  alias Platform.Access.Scope
  alias Platform.Agents.AgentRuntime
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights
  alias Platform.Memory.Insights.Briefings
  alias Platform.Memory.Insights.Disseminator
  alias Platform.Memory.Insights.Hunks
  alias Platform.Memory.Insights.Routing
  alias Platform.Memory.Insights.Tier
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
      execute(insight, scope, now)
    end
  end

  defp tier_permits(insight, scope) do
    case Tier.classify(insight) do
      :reversible -> :ok
      :needs_call -> if Access.authorize_install(scope) == :ok, do: :ok, else: unauthorized()
    end
  end

  defp execute(%Insight{action_type: "page_edit"} = insight, scope, now) do
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
                 pre_image: %{
                   "file_key" => page.file_key,
                   "content" => page.content,
                   "version" => page.version,
                   "written_version" => written.version
                 }
               ) do
          acted
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> broadcast_ok(:acted)
    end
  end

  defp execute(%Insight{action_type: "task"} = insight, scope, now) do
    project_id = Map.get(insight.action, "project_id") || Map.get(insight.action, "target")

    case Access.task_target(scope, {:project, project_id}, "tasks.write") do
      {:ok, {:project, project_id}} ->
        Repo.transaction(fn ->
          with {:ok, task} <- Tasks.create_task(task_attrs(insight, project_id)),
               {:ok, acted} <-
                 Insights.record_outcome(insight, :acted,
                   broadcast: false,
                   actor_id: actor_id(scope),
                   now: now,
                   artefact_ref: "task:#{task.id}"
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

  defp execute(%Insight{action_type: type} = insight, scope, now)
       when type in ["question", "briefing"] do
    with :ok <- internal(scope),
         user_id when is_binary(user_id) <- insight.addressee_user_id || {:error, :no_addressee},
         {:ok, _added} <- Disseminator.deliver_now(user_id, [insight], now: now) do
      {:ok, Insights.get(insight.id) || insight}
    end
  end

  defp execute(%Insight{}, _scope, _now), do: {:error, :not_supported}

  defp task_attrs(insight, project_id) do
    %{
      project_id: project_id,
      title: task_title(insight),
      description: insight.body <> "\n\n_Filed from a dreaming insight (#{insight.id})._",
      sponsor_user_id: insight.addressee_user_id
    }
  end

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
         :ok <- may_write_memory(scope, pre["file_key"]),
         %{} = page <-
           Wiki.get_page(pre["file_key"], workspace_id: insight.workspace_id) || not_found(),
         true <- page.version == pre["written_version"] || {:error, :stale} do
      Repo.transaction(fn ->
        with {:ok, _restored} <-
               Wiki.upsert_page(
                 page.file_key,
                 %{content: pre["content"], updated_by: actor_id(scope)},
                 workspace_id: insight.workspace_id,
                 expected_version: page.version
               ),
             {:ok, reopened} <-
               insight
               |> Insight.outcome_changeset(%{
                 state: "open",
                 acted_by: nil,
                 acted_at: nil,
                 artefact_ref: nil,
                 pre_image: nil
               })
               |> Repo.update() do
          reopened
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> broadcast_ok(:reverted)
    end
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
