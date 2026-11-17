defmodule Platform.Sharing.Friction do
  @moduledoc """
  Agent friction reports (task 01a1b678 stage 3): when an agent keeps hitting
  the same problem, file ONE report for the install through the same path
  `feedback_submit` uses.

  ## What counts as friction

  Two kinds of occurrence, each reduced to a fingerprint:

    * `tool_failure`: a federated tool call that returned an error, keyed on
      the tool name plus a BOUNDED error code (`error_code/1`). Recorded by
      `Platform.Federation.ToolArguments.dispatch/3`, the one entry point to
      `ToolSurface.execute/3`. Free-text error messages are never read.
    * `question`: the same normalized question addressed to an agent by a
      person (`normalize_question/1`). Recorded by
      `Platform.Chat.AgentResponder` for addressed messages. Only a hash of the
      normalized question is stored or sent; the question text never leaves
      the install, because the registry promises message text is never sent.

  ## Threshold, window, rate limit

  Each occurrence is one `sharing_friction_events` row. When the count for a
  fingerprint within the last `window_days` reaches `threshold`
  (`Platform.Sharing.friction_settings/0`), the occurrence is submitted
  through `Platform.Feedback.Submission.submit/2`, which scrubs it
  (`Platform.Feedback.Redaction`) and dedupes it on the `feedback_submissions`
  fingerprint. The report text depends only on the fingerprint and the
  settings, never on the running count, so the 4th and later occurrences map
  to the same submission fingerprint and come back `duplicate`: one issue,
  ever, per problem.

  An install files at most `max_reports_per_install_per_week` NEW reports in
  any 7 days. A fingerprint that already filed is not held back by the cap,
  because its submission can only dedupe. This cap is in addition to the
  `FEEDBACK_RATE_LIMIT_*` caps `Submission` applies.

  ## Off switch

  A no-op, writing nothing, unless both `Platform.Feedback.Policy.enabled?/0`
  and `Platform.Sharing.enabled?(:friction_reports)` are true. The policy is
  read first, so a disabled install never reads the `install_sharing` row.

  ## Metric

  Every occurrence at or past the threshold writes one
  `sharing_friction_reports` row with its outcome; `counts/0` totals them for
  the experiment metric.

  ## Never raises

  `record_tool_failure/3` and `record_question/2` run inside tool calls and
  agent dispatch. Any failure is logged and swallowed.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Chat.Message
  alias Platform.Chat.Participant
  alias Platform.Feedback.Policy
  alias Platform.Feedback.Submission
  alias Platform.Repo
  alias Platform.Sharing
  alias Platform.Sharing.{FrictionEvent, FrictionReport}

  @kinds ~w(tool_failure question)
  @week_seconds 7 * 86_400
  @code_pattern ~r/\A[a-z0-9_.\-]{1,48}\z/
  @tool_pattern ~r/\A[a-z0-9_.\-]{1,64}\z/
  # Tools whose own failure must not feed back into a report.
  @excluded_tools ~w(feedback_submit sharing_list sharing_set)
  @min_question_words 3
  @max_question_chars 500

  @type outcome ::
          :disabled
          | :ignored
          | :below_threshold
          | :filed
          | :deduped
          | :rate_limited
          | :refused

  @doc "The occurrence kinds."
  def kinds, do: @kinds

  @doc """
  Record a failed tool call. `error` is the tool's error term; only a bounded
  code is taken from it. `context` is the call context; the agent is read
  from `:agent`, `:agent_id` or the runtime. Returns `{:ok, outcome}`.
  """
  @spec record_tool_failure(String.t(), term(), map(), keyword()) :: {:ok, outcome()}
  def record_tool_failure(tool, error, context, opts \\ []) do
    guarded(fn ->
      with {:ok, tool} <- bounded_tool(tool),
           {:enabled, true} <- {:enabled, enabled?()},
           %Agent{} = agent <- context_agent(context) do
        observe("tool_failure", "#{tool}:#{error_code(error)}", agent, opts)
      else
        {:enabled, false} -> {:ok, :disabled}
        _ -> {:ok, :ignored}
      end
    end)
  end

  @doc """
  Record `message` addressed to `agent`. Only a person's message that reads as
  a question counts (`normalize_question/1`). Returns `{:ok, outcome}`.
  """
  @spec record_question(Agent.t(), Message.t(), keyword()) :: {:ok, outcome()}
  def record_question(agent, message, opts \\ [])

  def record_question(%Agent{} = agent, %Message{} = message, opts) do
    guarded(fn ->
      with normalized when is_binary(normalized) <- normalize_question(message.content),
           {:enabled, true} <- {:enabled, enabled?()},
           true <- person_author?(message) do
        observe("question", "q:" <> short_hash(normalized), agent, opts)
      else
        {:enabled, false} -> {:ok, :disabled}
        _ -> {:ok, :ignored}
      end
    end)
  end

  def record_question(_agent, _message, _opts), do: {:ok, :ignored}

  @doc """
  The bounded error code of a tool error: the `code` of an error map, or an
  atom reason, lowercased and limited to `[a-z0-9_.-]{1,48}`. Anything else,
  free text included, is `"error"`.
  """
  @spec error_code(term()) :: String.t()
  def error_code(%{code: code}), do: bounded_code(code)
  def error_code(%{"code" => code}), do: bounded_code(code)
  def error_code(code) when is_atom(code) and not is_nil(code), do: bounded_code(code)
  def error_code(_), do: "error"

  @doc """
  Normalize a question: strip mentions, lowercase, drop punctuation and
  collapse whitespace. Returns nil unless the text contains a `?` and has at
  least #{@min_question_words} words.
  """
  @spec normalize_question(term()) :: String.t() | nil
  def normalize_question(text) when is_binary(text) do
    if String.contains?(text, "?") do
      normalized =
        text
        |> String.slice(0, @max_question_chars)
        |> String.replace(~r/@\[[^\]]*\]/u, " ")
        |> String.downcase()
        |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
        |> String.replace(~r/\s+/u, " ")
        |> String.trim()

      if length(String.split(normalized, " ", trim: true)) >= @min_question_words,
        do: normalized,
        else: nil
    end
  end

  def normalize_question(_), do: nil

  @doc "Report outcomes recorded on this install, for the experiment metric."
  @spec counts() :: %{
          filed: non_neg_integer(),
          deduped: non_neg_integer(),
          rate_limited: non_neg_integer(),
          refused: non_neg_integer()
        }
  def counts do
    totals =
      Repo.all(from(r in FrictionReport, group_by: r.outcome, select: {r.outcome, count(r.id)}))
      |> Map.new()

    Map.new(FrictionReport.outcomes(), fn outcome ->
      {String.to_existing_atom(outcome), Map.get(totals, outcome, 0)}
    end)
  end

  @doc "True when friction reports may be filed: feedback policy on and the owner's switch on."
  @spec enabled?() :: boolean()
  def enabled?, do: Policy.enabled?() and Sharing.enabled?(:friction_reports)

  # ── core ───────────────────────────────────────────────────────────────

  # Callers have checked `enabled?/0`.
  defp observe(kind, subject, %Agent{} = agent, opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    settings = Sharing.friction_settings()
    fingerprint = fingerprint(kind, subject)
    since = DateTime.add(now, -settings.window_days * 86_400, :second)

    Repo.insert!(%FrictionEvent{
      fingerprint: fingerprint,
      kind: kind,
      subject: subject,
      agent_id: agent.id,
      occurred_at: now
    })

    Repo.delete_all(
      from(e in FrictionEvent, where: e.fingerprint == ^fingerprint and e.occurred_at <= ^since)
    )

    count =
      Repo.aggregate(
        from(e in FrictionEvent,
          where:
            e.fingerprint == ^fingerprint and e.occurred_at > ^since and e.occurred_at <= ^now
        ),
        :count
      )

    if count < settings.threshold,
      do: {:ok, :below_threshold},
      else: report(kind, subject, fingerprint, agent, settings, now)
  end

  defp report(kind, subject, fingerprint, agent, settings, now) do
    if not filed?(fingerprint) and
         filed_since(DateTime.add(now, -@week_seconds, :second)) >=
           settings.max_reports_per_install_per_week do
      record_outcome(fingerprint, kind, :rate_limited, nil, nil)
    else
      case Submission.submit(report_args(kind, subject, settings), %{
             agent_id: agent.id,
             slug: agent.slug
           }) do
        {:ok, %{status: "created", issue: issue}} ->
          record_outcome(fingerprint, kind, :filed, nil, issue_url(issue))

        {:ok, %{status: "duplicate", issue: issue}} ->
          record_outcome(fingerprint, kind, :deduped, nil, issue_url(issue))

        {:error, %{code: code}} ->
          record_outcome(fingerprint, kind, :refused, bounded_code(code), nil)
      end
    end
  end

  # The text depends only on the fingerprint's subject and the settings, so
  # every occurrence at or past the threshold is the same submission.
  defp report_args("tool_failure", subject, settings) do
    [tool, code] = String.split(subject, ":", parts: 2)

    %{
      "category" => "bug",
      "area" => "agents",
      "title" => "Agents keep hitting #{tool} failing with #{code}",
      "expected_behavior" =>
        "The #{tool} tool call succeeds, or fails with an error the agent can act on.",
      "observed_behavior" =>
        "On one install, #{tool} failed with #{code} at least #{settings.threshold} times within #{settings.window_days} days.",
      "version_environment" => "Filed automatically by agent friction reports."
    }
  end

  defp report_args("question", "q:" <> hash, settings) do
    %{
      "category" => "positive_change",
      "area" => "agents",
      "title" => "People keep asking agents the same question (ref #{hash})",
      "expected_behavior" =>
        "What people keep asking an agent is answered in Burrow itself, so they stop needing to ask.",
      "observed_behavior" =>
        "On one install, the same question (ref #{hash}) was asked of an agent at least #{settings.threshold} times within #{settings.window_days} days. The question text is not sent.",
      "version_environment" => "Filed automatically by agent friction reports."
    }
  end

  defp filed?(fingerprint) do
    Repo.exists?(
      from(r in FrictionReport, where: r.fingerprint == ^fingerprint and r.outcome == "filed")
    )
  end

  defp filed_since(since) do
    Repo.aggregate(
      from(r in FrictionReport, where: r.outcome == "filed" and r.inserted_at > ^since),
      :count
    )
  end

  defp record_outcome(fingerprint, kind, outcome, detail, url) do
    Repo.insert!(%FrictionReport{
      fingerprint: fingerprint,
      kind: kind,
      outcome: Atom.to_string(outcome),
      detail: detail,
      issue_url: url
    })

    {:ok, outcome}
  end

  defp issue_url(%{url: url}) when is_binary(url), do: String.slice(url, 0, 512)
  defp issue_url(_), do: nil

  # ── helpers ────────────────────────────────────────────────────────────

  defp guarded(fun) do
    fun.()
  rescue
    error ->
      Logger.warning("[Sharing.Friction] not recorded: #{Exception.message(error)}")
      {:ok, :ignored}
  end

  defp fingerprint(kind, subject),
    do: :crypto.hash(:sha256, kind <> <<0>> <> subject) |> Base.encode16(case: :lower)

  defp short_hash(text),
    do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, 12)

  defp bounded_tool(tool) when is_binary(tool) and tool not in @excluded_tools do
    if Regex.match?(@tool_pattern, tool), do: {:ok, tool}, else: :error
  end

  defp bounded_tool(_), do: :error

  defp bounded_code(code) when is_atom(code) and not is_nil(code),
    do: bounded_code(Atom.to_string(code))

  defp bounded_code(code) when is_binary(code) do
    code = String.downcase(code)
    if Regex.match?(@code_pattern, code), do: code, else: "error"
  end

  defp bounded_code(_), do: "error"

  defp context_agent(context) when is_map(context) do
    case Map.get(context, :agent) do
      %Agent{} = agent ->
        agent

      _ ->
        with id when is_binary(id) <- Map.get(context, :agent_id),
             {:ok, uuid} <- Platform.UUID.cast(id) do
          Repo.get(Agent, uuid)
        else
          _ -> runtime_agent(Map.get(context, :runtime_id))
        end
    end
  end

  defp context_agent(_), do: nil

  defp runtime_agent(runtime_id) when is_binary(runtime_id) do
    case Platform.Federation.get_runtime_by_runtime_id(runtime_id) do
      %{id: id} -> Repo.get_by(Agent, runtime_id: id)
      _ -> nil
    end
  end

  defp runtime_agent(_), do: nil

  defp person_author?(%Message{participant_id: pid}) when is_binary(pid) do
    Repo.exists?(from(p in Participant, where: p.id == ^pid and p.participant_type == "user"))
  end

  defp person_author?(_), do: false
end
