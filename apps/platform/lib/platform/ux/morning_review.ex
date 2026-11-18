defmodule Platform.Ux.MorningReview do
  @moduledoc """
  The designer's morning review: after each `ux.friction_watch` cron fire,
  ONE canvas titled "<agent name> · <date>" showing what the watch noticed,
  what it thinks it means and the fixes it proposes, posted where the
  escalation human reads it in the morning. Each proposed fix is a
  `ux_decision` Inbox row (`Platform.Ux.Decisions`) to that human; the
  designer ships nothing on its own.

  ## Switch

  Off unless the `ux.friction_watch` row's `trigger_config` carries
  `"morning_review" => true`. Read with `config/0`. Other keys:

    * `"fix_project_id"` — the project an approved fix is filed in. Unset,
      an approval is recorded on the finding and no task is filed.
    * `"escalate_user_id"` — the recipient (`Platform.Designer`).

  ## Where the canvas goes

  The 1:1 DM between the designer agent and the recipient
  (`Platform.Chat.find_or_create_agent_dm/2`), else the agent's digest
  space (`Platform.Ux.Digest.digest_space/1`). Nothing new this run, no
  canvas.

  ## Answers (`after_answer/1`, called by `Platform.Ux.Decisions.answer/4`)

    * "Build it" / "Try the other option" — files ONE task for the chosen
      option in `fix_project_id`: `auto_approve_plan: true`, the designer
      agent on planning, execution and review, the recipient as sponsor. The
      finding's `task_id` is set, so the friction watch never re-asks that
      group (`FrictionWatch.duplicate?/2`).
    * "Not now" — appends the question and the human's note to the
      designer's private journal page for the day,
      `space/<dm space id>/private/<agent id>/journal/<date>.md`.

  Best effort: the answer is already committed; a failure here is logged.
  """

  import Ecto.Query

  require Logger

  alias Platform.Chat
  alias Platform.Chat.Canvas.Links
  alias Platform.Chat.CanvasDocument
  alias Platform.Org.Wiki
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Responsibility
  alias Platform.Tasks
  alias Platform.Ux.Decisions
  alias Platform.Ux.Digest
  alias Platform.Ux.Finding

  @config_key "ux.friction_watch"
  @timezone "America/Chicago"
  @max_findings 12

  @type config :: %{enabled?: boolean(), project_id: String.t() | nil}

  @doc "The morning-review switch and fix project from the friction-watch row. Never raises."
  @spec config() :: config()
  def config do
    case Responsibilities.get_by_key(@config_key) do
      %Responsibility{trigger_config: tc} -> config(tc)
      _ -> config(nil)
    end
  rescue
    _ -> config(nil)
  end

  @doc false
  @spec config(map() | nil) :: config()
  def config(%{} = tc) do
    project_id = tc["fix_project_id"]

    %{
      enabled?: tc["morning_review"] == true,
      project_id: if(Platform.UUID.valid?(project_id), do: project_id, else: nil)
    }
  end

  def config(_), do: %{enabled?: false, project_id: nil}

  @doc """
  Post the morning canvas for the findings `agent` filed to
  `recipient_user_id` since `since`. `{:ok, %{canvas_id, space_id, url}}`,
  `{:skipped, reason}` or `{:error, reason}`. Never raises.
  """
  @spec post(map() | nil, String.t() | nil, DateTime.t(), keyword()) ::
          {:ok, map()} | {:skipped, atom()} | {:error, term()}
  def post(agent, recipient_user_id, since, opts \\ [])

  def post(%{id: agent_id} = agent, recipient_user_id, %DateTime{} = since, opts)
      when is_binary(agent_id) and is_binary(recipient_user_id) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    case new_findings(recipient_user_id, since) do
      [] ->
        {:skipped, :nothing_new}

      findings ->
        with {:ok, space_id, participant_id} <- destination(agent, recipient_user_id) do
          title = title(agent, now)
          document = document(title, findings, recipient_user_id)

          with {:ok, doc} <- CanvasDocument.validate(document),
               {:ok, canvas, _message} <-
                 Chat.create_canvas_with_message(space_id, participant_id, %{
                   "title" => title,
                   "document" => doc,
                   "message_content" => intro(findings)
                 }) do
            {:ok, %{canvas_id: canvas.id, space_id: space_id, url: Links.view_url(canvas.id)}}
          end
        end
    end
  rescue
    error ->
      Logger.warning("[ux.morning_review] post raised: #{Exception.message(error)}")
      {:error, :crashed}
  end

  def post(_agent, _recipient, _since, _opts), do: {:skipped, :no_agent_or_recipient}

  @doc "The canvas title: \"<agent name> · <Mon 19 Nov>\" in America/Chicago."
  @spec title(map(), DateTime.t()) :: String.t()
  def title(agent, %DateTime{} = now) do
    local =
      case DateTime.shift_zone(now, @timezone) do
        {:ok, local} -> local
        _ -> now
      end

    "#{Map.get(agent, :name) || "Designer"} · #{Calendar.strftime(local, "%a %-d %b")}"
  end

  @doc """
  After `Decisions.answer/4` commits: file the task for an approval, or
  journal a decline. Returns the (possibly task-linked) finding.
  """
  @spec after_answer(Finding.t()) :: Finding.t()
  def after_answer(%Finding{} = finding) do
    cfg = config()

    cond do
      not cfg.enabled? -> finding
      finding.status == "answered" -> file_task(finding, cfg.project_id)
      finding.status == "dismissed" -> journal_decline(finding)
      true -> finding
    end
  rescue
    error ->
      Logger.warning("[ux.morning_review] after_answer raised: #{Exception.message(error)}")
      finding
  end

  # ── approval → task ────────────────────────────────────────────────────

  defp file_task(%Finding{task_id: id} = finding, _project) when is_binary(id), do: finding
  defp file_task(finding, nil), do: finding

  defp file_task(finding, project_id) do
    with agent_id when is_binary(agent_id) <- Platform.Roles.agent_id_for_role("designer"),
         slot = %{"assignee_type" => "agent", "assignee_id" => agent_id},
         {:ok, task} <-
           Tasks.create_from_request(%{
             "project_id" => project_id,
             "title" => task_title(finding),
             "description" => task_description(finding),
             "status" => "backlog",
             "priority" => "medium",
             "auto_approve_plan" => true,
             "sponsor_user_id" => finding.recipient_user_id,
             "phase_assignees" => %{
               "planning" => slot,
               "execution" => slot,
               "review" => slot
             }
           }),
         {:ok, task} <- Tasks.maybe_start_planning_on_create(task),
         {:ok, linked} <- finding |> Ecto.Changeset.change(task_id: task.id) |> Repo.update() do
      Tasks.broadcast_board({:task_created, task})
      linked
    else
      other ->
        Logger.warning(
          "[ux.morning_review] task not filed finding=#{finding.id} #{inspect(other)}"
        )

        finding
    end
  end

  @doc false
  def task_title(%Finding{} = finding) do
    label =
      case chosen_option(finding) do
        %{"label" => label} -> label
        _ -> finding.question
      end

    "UX: " <> String.slice(label, 0, 200)
  end

  defp task_description(finding) do
    option = chosen_option(finding) || %{}

    [
      "Approved from the designer's morning review (finding #{finding.id}).",
      "",
      "Problem: #{finding.question}",
      Decisions.evidence_line(finding.evidence) <> ".",
      meaning(finding) && "What it means: #{meaning(finding)}",
      "",
      "Fix: #{option["label"]}",
      option["detail"],
      "",
      "Answer: #{finding.answer}",
      "Evidence: #{Decisions.url(finding.id)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # The answer text starts "Build it: <label>" or "Try the other option: <label>".
  defp chosen_option(%Finding{answer: answer, options: options}) do
    options = options || []

    Enum.find(options, fn o ->
      is_binary(answer) and is_binary(o["label"]) and
        String.contains?(answer, ": " <> o["label"])
    end) || Enum.find(options, &(&1["recommended"] == true))
  end

  # ── decline → journal ──────────────────────────────────────────────────

  defp journal_decline(finding) do
    with agent_id when is_binary(agent_id) <- Platform.Roles.agent_id_for_role("designer"),
         {:ok, space} <- Chat.find_or_create_agent_dm(agent_id, finding.recipient_user_id) do
      date = Date.to_iso8601(Date.utc_today())
      path = "space/#{space.id}/private/#{agent_id}/journal/#{date}.md"

      existing =
        case Wiki.get_page(path) do
          %{content: content} when is_binary(content) -> String.trim_trailing(content) <> "\n\n"
          _ -> "# Journal #{date}\n\n"
        end

      entry =
        "## Declined: #{finding.question}\n\n" <>
          "Group `#{finding.group_key}`. #{finding.answer}\n\n" <>
          "Lower confidence in the pattern behind this proposal; do not re-propose it without new evidence."

      case Wiki.upsert_page(path, %{content: existing <> entry, updated_by: agent_id}) do
        {:ok, _} -> :ok
        other -> Logger.warning("[ux.morning_review] journal not written #{inspect(other)}")
      end
    end

    finding
  end

  # ── canvas ─────────────────────────────────────────────────────────────

  defp new_findings(recipient_user_id, since) do
    from(f in Finding,
      where: f.recipient_user_id == ^recipient_user_id and f.inserted_at >= ^since,
      order_by: [desc: f.kind == "decision", asc: f.inserted_at],
      limit: @max_findings
    )
    |> Repo.all()
  end

  defp destination(agent, recipient_user_id) do
    dm =
      case Chat.find_or_create_agent_dm(agent.id, recipient_user_id) do
        {:ok, %{id: space_id}} -> {:ok, space_id}
        _ -> :error
      end

    space =
      case dm do
        {:ok, _} = ok -> ok
        :error -> Digest.digest_space(agent)
      end

    with {:ok, space_id} <- space,
         %{id: participant_id} <- Chat.get_agent_participant(space_id, agent.id) do
      {:ok, space_id, participant_id}
    else
      {:skipped, reason} -> {:skipped, reason}
      _ -> {:skipped, :no_destination}
    end
  end

  defp intro(findings) do
    asks = Enum.count(findings, &(&1.kind == "decision"))

    "What I noticed overnight. #{asks} #{if asks == 1, do: "fix waits", else: "fixes wait"} for your OK in your inbox."
  end

  @doc false
  def document(title, findings, recipient_user_id) do
    cards =
      findings
      |> Enum.with_index(1)
      |> Enum.map(fn {f, i} -> card(f, i, recipient_user_id) end)

    %{
      "version" => 1,
      "revision" => 1,
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{},
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 16},
        "children" =>
          [
            %{"id" => "title", "type" => "heading", "props" => %{"level" => 1, "value" => title}},
            %{
              "id" => "how",
              "type" => "markdown",
              "props" => %{
                "content" =>
                  "Each fix waits for your OK in your inbox. Nothing ships until you say so. " <>
                    "\"Not now\" with a reason teaches me what to stop proposing."
              }
            }
          ] ++ cards
      }
    }
  end

  defp card(%Finding{} = f, i, recipient_user_id) do
    %{
      "id" => "f#{i}",
      "type" => "card",
      "props" => %{
        "title" => f.question,
        "tone" => if(f.kind == "decision", do: "info", else: "neutral")
      },
      "children" => [
        %{
          "id" => "f#{i}-body",
          "type" => "markdown",
          "props" => %{"content" => card_body(f, recipient_user_id)}
        }
      ]
    }
  end

  defp card_body(f, recipient_user_id) do
    quotes = Enum.map(Decisions.quotes(f.evidence), &("> " <> &1))

    links =
      f
      |> Decisions.source_messages(recipient_user_id)
      |> Enum.take(5)
      |> Enum.with_index(1)
      |> Enum.map(fn {m, n} -> "[#{n}](#{m.url})" end)

    noticed =
      ["**What I noticed.** #{Decisions.evidence_line(f.evidence)}."] ++
        quotes ++ if(links == [], do: [], else: ["Sources: " <> Enum.join(links, " · ")])

    means = if meaning(f), do: ["**What I think it means.** #{meaning(f)}"], else: []

    fixes =
      case f.options || [] do
        [] ->
          []

        options ->
          [
            "**What I'd do.**"
            | Enum.map(options, fn o ->
                star = if o["recommended"], do: " (my pick)", else: ""
                detail = if is_binary(o["detail"]), do: " " <> o["detail"], else: ""
                "- **#{o["label"]}**#{star}.#{detail}"
              end)
          ]
      end

    ask =
      if f.kind == "decision",
        do: ["[Approve or decline in your inbox](#{Decisions.url(f.id)})"],
        else: ["Nothing to decide."]

    Enum.join(noticed ++ [""] ++ means ++ [""] ++ fixes ++ [""] ++ ask, "\n")
  end

  defp meaning(%Finding{evidence: %{"meaning" => m}}) when is_binary(m) and m != "", do: m
  defp meaning(_), do: nil
end
