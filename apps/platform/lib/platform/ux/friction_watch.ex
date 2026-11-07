defmodule Platform.Ux.FrictionWatch do
  @moduledoc """
  The server half of the `ux.friction_watch` responsibility (designer bundle,
  task 01a1af00 stage 2): read chat for UI friction, group it, and write
  `ux_findings` rows. The Router entry point is
  `Platform.Responsibilities.Handlers.UxFrictionWatch`; this module is what
  it runs.

  ## Privacy scope

  The watch reads ONLY messages that pass BOTH of these:

    1. a space the assigned agent participates in,
       `Platform.Chat.list_spaces_for_agent/2` (the `chat_participants`
       roster; archived spaces excluded);
    2. the Historian digest partition,
       `Platform.Chat.digest_eligible_messages_query/1` with the default
       `:internal` scope, which omits every external and MIXED space
       (`Platform.Chat.external_space_ids/0`; see
       `test/platform/chat/digest_scope_test.exs`).

  `Platform.Chat.list_human_digest_messages_in_spaces/4` is the one reader
  and composes the two, so the scope is the same partition
  `Platform.People.Appearances.collect/3` reads, narrowed to the agent's own
  roster. Agent-authored messages are excluded. Nothing here queries chat
  tables directly.

  ## Detection

    1. A deterministic pre-filter (`friction?/1`) keeps only messages with a
       friction phrase: "how do I", "can't find", "where is", and complaint
       words. With no signal there is no model call.
    2. One TOOL-LESS model call (`Platform.Agents.ToollessChat`, the
       `Platform.Feedback.Classifier` pattern: provider opts from an allowlist,
       any `:tools` key dropped). The system turn is the `ux.friction_watch.v1`
       template with the `ux.friction_detection` surface's directive; the user
       turn is the numbered signals as JSON. The model groups and classifies;
       it never sees a space id, a message id or an author id.
    3. The server keeps a group only when its `similarity` is at or above the
       surface's `grouping_threshold` AND it cites at least `min_occurrences`
       distinct known signals. Both numbers come from the resolved surface
       payload, never from a constant here.

  Evidence (count, at most two quotes, `chat:<space_id>:<message_id>`
  citations) is built by the server from the signals it holds. A signal id
  the model invents is dropped.

  ## Output and dedupe

  One `Platform.Ux.Finding` per kept group, addressed to the recipient
  (`:recipient_user_id`, else `Platform.Accounts.install_owner/0`):

    * `decision` — at most ONE row per recipient per `group_key`, EVER: an
      answered or dismissed decision still blocks a second one, so a re-run
      never re-asks.
    * `fyi` — one OPEN row per recipient per `group_key`, held for the weekly
      digest (stage 4 posts it to chat; it is never an inbox item).
    * Any `group_key` already carried by a finding linked to a task
      (`task_id` set: the child tasks this role owns) is skipped for every
      recipient: the task already owns that friction.

  The partial unique index `ux_findings_open_group_index` is a backstop for
  the open case only; the dedupe above is what makes a re-run idempotent.

  ## What it never does

  No runtime tools, no file writes, no git, no task creation, no code edits.
  Its only writes are `ux_findings` rows.

  ## Relation to `Platform.Sharing.Friction` (task 01a1b678, unmerged)

  That module fingerprints agent tool failures and EXACT normalized questions
  addressed to an agent, hashes them, and files one cross-install report. This
  watch reads human chat in the agent's own spaces and groups by meaning
  (a model similarity), keeps the text on the install, and asks a local human.
  Different input, different grouping, different destination, so no
  fingerprint function is shared; if both land, a shared normalizer is a
  follow-up for whichever merges second.

  ## Test seam

  `:ux_friction_watch_provider`: the provider module (default
  `Platform.Agents.Providers.Ollama`).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Platform.Accounts
  alias Platform.Agents.ToollessChat
  alias Platform.Chat
  alias Platform.Experiments.Subject
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.UxFrictionDetection
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Security.ExternalContent
  alias Platform.Ux.Finding

  @template_slug "ux.friction_watch.v1"
  @nil_uuid "00000000-0000-0000-0000-000000000000"
  @window_seconds 7 * 86_400
  @max_signals 200
  @max_signal_chars 500
  @max_quote_chars 200
  @max_tokens 2048

  @friction_re ~r/\b(how\s+(do|can|would|should)\s+(i|we|you)|can'?t\s+find|cannot\s+find|can\s+not\s+find|couldn'?t\s+find|where\s+(is|are|do|did|can)|where'?s|hard\s+to\s+(find|see|tell|read|use)|no\s+way\s+to|is\s+there\s+a\s+way|why\s+(does|is|can'?t|won'?t)|doesn'?t\s+work|not\s+working|confus\w*|frustrat\w*|annoying|keeps?\s+(moving|jumping|disappearing|resetting)|lost\s+(my|the)|too\s+(small|tight|cramped|big|many))/iu

  @type summary :: %{
          status:
            :ran | :unassigned | :no_signals | :provider_failed | :rejected_output | :crashed,
          signals: non_neg_integer(),
          groups: non_neg_integer(),
          created: [String.t()],
          deduped: [String.t()],
          below_threshold: [String.t()],
          failed: [String.t()],
          scope_space_ids: [String.t()],
          variant: String.t() | nil
        }

  @doc "The prompt template slug of the system turn."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @doc "True when a message reads as UI friction (the deterministic pre-filter)."
  @spec friction?(term()) :: boolean()
  def friction?(text) when is_binary(text), do: Regex.match?(@friction_re, text)
  def friction?(_), do: false

  @doc """
  The space ids the watch may read for `agent_id`: the agent's own roster
  (`Chat.list_spaces_for_agent/2`). The `:internal` digest partition is
  applied by the message reader on top of this set.
  """
  @spec scope_space_ids(String.t()) :: [String.t()]
  def scope_space_ids(agent_id) when is_binary(agent_id) do
    agent_id |> Chat.list_spaces_for_agent() |> Enum.map(& &1.id)
  end

  @doc """
  The resolved `ux.friction_detection` payload for a workspace (or the nil
  UUID for an org-wide fire), merged over the control, with the variant slug
  (nil for the control or a promoted default).
  """
  @spec experiment(String.t() | nil) :: {map(), String.t() | nil}
  def experiment(workspace_id) do
    subject = Subject.new(UxFrictionDetection.subject_type(), workspace_id || @nil_uuid)

    {payload, variant} =
      case Surfaces.resolve(UxFrictionDetection.key(), UxFrictionDetection.target(), subject) do
        {:variant, _experiment, slug, %{} = payload} -> {payload, slug}
        {:default, %{} = payload} -> {payload, nil}
        _ -> {%{}, nil}
      end

    {Map.merge(UxFrictionDetection.control(), payload), variant}
  rescue
    _ -> {UxFrictionDetection.control(), nil}
  end

  @doc """
  Run one pass for `agent` (the resolved assignee; nil is a no-op that reads
  and writes nothing).

  Options: `:now` (window end, default now), `:workspace_id`, `:org_id`,
  `:recipient_user_id`. Never raises.
  """
  @spec run(map() | nil, keyword()) :: {:ok, summary()}
  def run(agent, opts \\ [])

  def run(nil, _opts), do: {:ok, empty(:unassigned, [], nil)}

  def run(%{id: agent_id} = agent, opts) when is_binary(agent_id) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    window_start = DateTime.add(now, -@window_seconds, :second)
    {payload, variant} = experiment(Keyword.get(opts, :workspace_id))
    space_ids = scope_space_ids(agent_id)

    signals =
      space_ids
      |> Chat.list_human_digest_messages_in_spaces(window_start, now)
      |> Enum.filter(&friction?(&1.content))
      |> Enum.take(@max_signals)
      |> Enum.with_index(1)
      |> Enum.map(fn {m, i} -> Map.put(m, :signal_id, i) end)

    if signals == [] do
      {:ok, empty(:no_signals, space_ids, variant)}
    else
      classify_and_write(agent, signals, payload, variant, space_ids, opts)
    end
  rescue
    error ->
      Logger.warning("[ux.friction_watch] run raised: #{Exception.message(error)}")
      {:ok, empty(:crashed, [], nil)}
  end

  defp classify_and_write(agent, signals, payload, variant, space_ids, opts) do
    messages = build_messages(signals, payload)

    case ToollessChat.call(provider_module(), agent, messages,
           temperature: 0.0,
           max_tokens: @max_tokens,
           log_tag: "[ux.friction_watch]",
           log_context: "signals=#{length(signals)}"
         ) do
      {:ok, content} ->
        case parse(content) do
          {:ok, groups} ->
            summary = write_groups(groups, signals, payload, variant, opts)

            {:ok,
             Map.merge(empty(:ran, space_ids, variant), summary)
             |> Map.put(:signals, length(signals))
             |> Map.put(:groups, length(groups))}

          :rejected ->
            {:ok, %{empty(:rejected_output, space_ids, variant) | signals: length(signals)}}
        end

      :error ->
        {:ok, %{empty(:provider_failed, space_ids, variant) | signals: length(signals)}}
    end
  end

  @doc """
  The system + user messages for the model call. The user turn carries ONLY
  each signal's number and text: no space, message or author id.
  """
  @spec build_messages([map()], map()) :: [map()]
  def build_messages(signals, payload) do
    user =
      signals
      |> Enum.map(fn s ->
        %{"id" => s.signal_id, "text" => clip(s.content, @max_signal_chars)}
      end)
      |> Jason.encode!()
      |> ExternalContent.escape_mentions()

    [%{role: "system", content: system_prompt(payload)}, %{role: "user", content: user}]
  end

  @doc false
  def system_prompt(payload) do
    assigns = %{
      grouping_threshold: to_string(payload["grouping_threshold"]),
      min_occurrences: to_string(payload["min_occurrences"]),
      max_options: to_string(Finding.max_options()),
      experiment_directive: UxFrictionDetection.render_directive(payload) || ""
    }

    case PromptTemplates.render_template(@template_slug, assigns) do
      {:ok, prompt} ->
        prompt

      {:error, _} ->
        case PromptTemplates.render_default(@template_slug, assigns) do
          {:ok, prompt} -> prompt
          {:error, _} -> ""
        end
    end
  end

  @doc """
  Parse the model's output: `{"groups": [...]}`, one surrounding code fence
  tolerated. Anything else is `:rejected`. Groups with a malformed shape are
  dropped individually.
  """
  @spec parse(String.t()) :: {:ok, [map()]} | :rejected
  def parse(content) when is_binary(content) do
    case Jason.decode(strip_fence(content)) do
      {:ok, %{"groups" => groups}} when is_list(groups) ->
        {:ok, groups |> Enum.map(&normalise_group/1) |> Enum.reject(&is_nil/1)}

      _ ->
        :rejected
    end
  end

  def parse(_), do: :rejected

  defp normalise_group(%{} = g) do
    key = group_key(g["group_key"])
    kind = g["kind"]
    question = if is_binary(g["question"]), do: String.trim(g["question"]), else: ""
    similarity = g["similarity"]
    ids = if is_list(g["signal_ids"]), do: Enum.filter(g["signal_ids"], &is_integer/1), else: []

    if key && kind in Finding.kinds() && String.ends_with?(question, "?") && is_number(similarity) do
      %{
        group_key: key,
        kind: kind,
        question: clip(ExternalContent.escape_mentions(question), 300),
        similarity: similarity / 1,
        signal_ids: Enum.uniq(ids),
        options: options(g["options"])
      }
    end
  end

  defp normalise_group(_), do: nil

  @doc "A model-supplied group key reduced to `[a-z0-9-]`, at most 64 chars; nil if empty."
  @spec group_key(term()) :: String.t() | nil
  def group_key(raw) when is_binary(raw) do
    key =
      raw
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 64)
      |> String.trim("-")

    if key == "", do: nil, else: key
  end

  def group_key(_), do: nil

  defp options(list) when is_list(list) do
    list
    |> Enum.filter(&(is_map(&1) and is_binary(&1["label"]) and String.trim(&1["label"]) != ""))
    |> Enum.take(Finding.max_options())
    |> Enum.map(fn o ->
      %{
        "label" => clip(String.trim(o["label"]), 120),
        "recommended" => o["recommended"] == true,
        "detail" => if(is_binary(o["detail"]), do: clip(o["detail"], 400), else: nil)
      }
    end)
  end

  defp options(_), do: []

  # ── writing ─────────────────────────────────────────────────────────────

  defp write_groups(groups, signals, payload, variant, opts) do
    by_id = Map.new(signals, &{&1.signal_id, &1})
    threshold = payload["grouping_threshold"]
    min_occurrences = payload["min_occurrences"]
    recipient = recipient_user_id(opts)
    org_id = org_id(opts)

    groups
    |> Enum.uniq_by(& &1.group_key)
    |> Enum.reduce(%{created: [], deduped: [], below_threshold: [], failed: []}, fn group, acc ->
      cited = group.signal_ids |> Enum.map(&Map.get(by_id, &1)) |> Enum.reject(&is_nil/1)

      cond do
        group.similarity < threshold or length(cited) < min_occurrences ->
          push(acc, :below_threshold, group.group_key)

        is_nil(recipient) ->
          push(acc, :failed, group.group_key)

        duplicate?(group, recipient) ->
          push(acc, :deduped, group.group_key)

        true ->
          attrs = finding_attrs(group, cited, recipient, org_id, opts, variant)

          case %Finding{} |> Finding.changeset(attrs) |> Repo.insert() do
            {:ok, finding} ->
              # One Inbox row per decision, to its recipient only (stage 3).
              # FYI findings are never Inbox rows.
              emit_decision(finding)
              push(acc, :created, group.group_key)

            {:error, changeset} ->
              Logger.warning(
                "[ux.friction_watch] finding rejected group=#{group.group_key} " <>
                  "errors=#{inspect(changeset.errors)}"
              )

              push(acc, :failed, group.group_key)
          end
      end
    end)
    |> Map.new(fn {k, v} -> {k, Enum.reverse(v)} end)
  end

  defp push(acc, key, value), do: Map.update!(acc, key, &[value | &1])

  # The finding is the durable record; a refused Inbox row is logged, never
  # fatal to the run.
  defp emit_decision(finding) do
    case Platform.Ux.Decisions.emit_inbox_item(finding) do
      {:error, reason} ->
        Logger.warning(
          "[ux.friction_watch] inbox row refused finding=#{finding.id} #{inspect(reason)}"
        )

      _ ->
        :ok
    end
  end

  @doc """
  True when `group` must not produce a new row for `recipient_user_id`: a
  task-linked finding already owns the key, a decision on the key ever went
  to this recipient, or an open finding on the key is waiting for them.
  """
  @spec duplicate?(%{group_key: String.t(), kind: String.t()}, String.t()) :: boolean()
  def duplicate?(%{group_key: key, kind: kind}, recipient_user_id) do
    decision? = kind == "decision"

    Repo.exists?(
      from(f in Finding,
        where:
          f.group_key == ^key and
            (not is_nil(f.task_id) or
               (f.recipient_user_id == ^recipient_user_id and
                  (f.status == "open" or (^decision? and f.kind == "decision"))))
      )
    )
  end

  defp finding_attrs(group, cited, recipient, org_id, opts, variant) do
    %{
      org_id: org_id,
      workspace_id: Keyword.get(opts, :workspace_id),
      recipient_user_id: recipient,
      question: group.question,
      kind: group.kind,
      group_key: group.group_key,
      variant: variant,
      evidence: %{
        "count" => length(cited),
        "spaces" => cited |> Enum.map(& &1.space_id) |> Enum.uniq() |> length(),
        "quotes" =>
          cited
          |> Enum.take(2)
          |> Enum.map(
            &(&1.content
              |> ExternalContent.escape_mentions()
              |> clip(@max_quote_chars))
          ),
        "citations" => Enum.map(cited, &Finding.citation(&1.space_id, &1.id))
      },
      options: fix_recommended(group.options, group.kind)
    }
  end

  # The changeset wants EXACTLY one recommended option whenever options are
  # present. A model that marked none (or several) gets its first marked, or
  # first overall, kept as the one recommendation.
  defp fix_recommended([], _kind), do: []

  defp fix_recommended(options, _kind) do
    index = Enum.find_index(options, & &1["recommended"]) || 0

    options
    |> Enum.with_index()
    |> Enum.map(fn {o, i} -> Map.put(o, "recommended", i == index) end)
  end

  defp recipient_user_id(opts) do
    case Keyword.get(opts, :recipient_user_id) do
      id when is_binary(id) and id != "" ->
        id

      _ ->
        case Accounts.install_owner() do
          %{id: id} -> id
          _ -> nil
        end
    end
  end

  defp org_id(opts) do
    case Keyword.get(opts, :org_id) do
      id when is_binary(id) and id != "" ->
        id

      _ ->
        case Platform.Tenancy.get_root_org() do
          %{id: id} -> id
          _ -> nil
        end
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp empty(status, space_ids, variant) do
    %{
      status: status,
      signals: 0,
      groups: 0,
      created: [],
      deduped: [],
      below_threshold: [],
      failed: [],
      scope_space_ids: space_ids,
      variant: variant
    }
  end

  defp strip_fence(content) do
    trimmed = String.trim(content)

    case Regex.run(~r/\A```(?:json)?\s*\n(.*)\n```\z/s, trimmed) do
      [_, inner] -> inner
      _ -> trimmed
    end
  end

  defp clip(text, max) when is_binary(text) do
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max - 1) <> "…"
  end

  defp clip(_text, _max), do: ""

  defp provider_module do
    Application.get_env(:platform, :ux_friction_watch_provider, Platform.Agents.Providers.Ollama)
  end
end
