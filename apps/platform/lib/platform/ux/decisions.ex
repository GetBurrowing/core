defmodule Platform.Ux.Decisions do
  @moduledoc """
  The `ux_decision` Inbox kind: one question the UX friction watch puts to
  one human, answerable in the Inbox. Task `01a1af00-86ac-7000-94ba-a121d5cb8116`
  stage 3, built to design canvas `01a1b684-c1dd` ("one clear ask").

  ## Why its own core kind

  `review_request_pending` is an approval kind tied to `ReviewRequest` and
  equal to `Platform.Mobile`'s approvals, and its approve/reject semantics are
  exactly what the design canvas rejects. Extension kinds are for extensions.
  So `ux_decision` is a CORE kind with `source_type: "ux_finding"` and
  `source_id` = the `ux_findings` id. It is listed on open (opening it is
  reading the question, not answering it) and is never an approval.

  ## Emission

  `emit_inbox_item/1` writes ONE row for the finding's `recipient_user_id`
  and nobody else, through `Platform.Inbox.emit/1`. Only an OPEN `decision`
  finding produces a row; an `fyi` finding never does (FYIs and the weekly
  digest stay in chat). `Platform.Ux.FrictionWatch` calls it on insert, and
  the watch already dedupes decisions per recipient and group, so a finding
  has at most one row.

  ## Answering

  `answer/4` is the one write path. It is owner-scoped (the finding is read
  by id AND recipient), refuses a finding that is no longer open, and in one
  transaction records the answer on `ux_findings`. After the commit it
  dismisses the recipient's `ux_decision` row for the finding and posts the
  outcome into the linked task's execution log (the task, not chat). A
  finding with no task posts nothing.

  The answers (`answers/1`) are at most three: "Build it" (the recommended
  option, the ONE primary answer), "Try the other option" (the first
  non-recommended option, when there is one) and "Not now". "Not now"
  resolves the finding as `dismissed`; the other two as `answered`, which is
  what `ux_finding_keep_rate` reads.
  """

  import Ecto.Query

  require Logger

  alias Platform.Access
  alias Platform.Access.Scope
  alias Platform.Chat.{Message, Space}
  alias Platform.Inbox
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Ux.Finding

  @kind "ux_decision"
  @source_type "ux_finding"
  @max_note 1_000

  @type answer :: %{
          key: String.t(),
          label: String.t(),
          primary?: boolean(),
          option: map() | nil
        }

  @doc "The Inbox kind."
  @spec kind() :: String.t()
  def kind, do: @kind

  @doc "The Inbox source type."
  @spec source_type() :: String.t()
  def source_type, do: @source_type

  @doc "Where the row opens: the finding in the Inbox's detail pane."
  @spec url(String.t()) :: String.t()
  def url(finding_id) when is_binary(finding_id), do: "/inbox/ux/" <> finding_id

  @doc """
  Emit the ONE Inbox row for an open `decision` finding, addressed to its
  recipient. Returns `Inbox.emit/1`'s result, or `:skipped` for an `fyi`
  finding or a finding that is no longer open.
  """
  @spec emit_inbox_item(Finding.t()) ::
          {:ok, Platform.Inbox.Item.t()} | {:error, term()} | :skipped
  def emit_inbox_item(%Finding{kind: "decision", status: "open"} = finding) do
    Inbox.emit(%{
      user_id: finding.recipient_user_id,
      kind: @kind,
      source_type: @source_type,
      source_id: finding.id,
      title: finding.question,
      body: evidence_line(finding.evidence),
      url: url(finding.id)
    })
  end

  def emit_inbox_item(_finding), do: :skipped

  @doc """
  The evidence line: "Seen N× this week across M channels". The channel
  count is dropped when the evidence does not carry one.
  """
  @spec evidence_line(map() | nil) :: String.t()
  def evidence_line(evidence) when is_map(evidence) do
    count = evidence["count"] || evidence[:count] || 0
    spaces = evidence["spaces"] || evidence[:spaces]

    seen = "Seen #{count}× this week"

    case spaces do
      n when is_integer(n) and n > 0 -> seen <> " across #{n} #{plural(n, "channel")}"
      _ -> seen
    end
  end

  def evidence_line(_evidence), do: evidence_line(%{})

  @doc "The (at most two) short quotes on the evidence."
  @spec quotes(map() | nil) :: [String.t()]
  def quotes(evidence) when is_map(evidence) do
    evidence
    |> Map.get("quotes", [])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.take(2)
  end

  def quotes(_evidence), do: []

  @doc """
  The finding, when `user_id` is its recipient; else nil. A malformed id is
  nil, never a cast error.
  """
  @spec get_for_recipient(term(), term()) :: Finding.t() | nil
  def get_for_recipient(finding_id, user_id) do
    if Platform.UUID.valid?(finding_id) and Platform.UUID.valid?(user_id) do
      Repo.one(
        from(f in Finding,
          where: f.id == ^finding_id and f.recipient_user_id == ^user_id
        )
      )
    end
  end

  @doc "`user_id`'s findings among `finding_ids`, keyed by id."
  @spec list_for_recipient([String.t()], String.t()) :: %{String.t() => Finding.t()}
  def list_for_recipient(finding_ids, user_id) when is_list(finding_ids) and is_binary(user_id) do
    ids = Enum.filter(finding_ids, &Platform.UUID.valid?/1)

    if ids == [] do
      %{}
    else
      from(f in Finding, where: f.id in ^ids and f.recipient_user_id == ^user_id)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})
    end
  end

  def list_for_recipient(_ids, _user_id), do: %{}

  @doc """
  The answers the open item offers, in order, at most three, EXACTLY one
  `primary?`: "Build it" (the recommended option), "Try the other option"
  (the first other option, when there is one), "Not now".
  """
  @spec answers(Finding.t()) :: [answer()]
  def answers(%Finding{options: options}) do
    options = options || []
    recommended = Enum.find(options, &(&1["recommended"] == true)) || List.first(options)
    other = Enum.find(options, &(&1 != recommended))

    [
      %{key: "build", label: "Build it", primary?: true, option: recommended},
      other && %{key: "other", label: "Try the other option", primary?: false, option: other},
      %{key: "not_now", label: "Not now", primary?: false, option: nil}
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Answer `finding_id` as `user_id` with the answer `key` (`answers/1`) and
  an optional note. See the moduledoc.

  Returns `{:ok, finding}`, or `{:error, :not_found}` (unknown id, or not the
  recipient), `{:error, :already_answered}` or `{:error, :invalid_answer}`.
  """
  @spec answer(term(), term(), String.t(), String.t() | nil) ::
          {:ok, Finding.t()} | {:error, :not_found | :already_answered | :invalid_answer | term()}
  def answer(finding_id, user_id, key, note \\ nil) do
    result =
      Repo.transaction(fn ->
        with %Finding{} = finding <- lock_for_recipient(finding_id, user_id),
             :ok <- ensure_open(finding),
             {:ok, choice} <- choose(finding, key),
             {:ok, updated} <- resolve(finding, choice, clean_note(note)) do
          updated
        else
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, finding} ->
        {:ok, _count} = Inbox.dismiss_by_source(user_id, @source_type, finding.id, kind: @kind)
        post_to_task(finding)
        {:ok, finding}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Whether a `ux_decision` row's finding is positively resolved (it exists
  and is no longer open). The Inbox reconciler dismisses such a row. A
  missing finding is NOT stale: the reconciler never dismisses a row it
  cannot confirm dead.
  """
  @spec inbox_row_stale?(term()) :: boolean()
  def inbox_row_stale?(finding_id) do
    Platform.UUID.valid?(finding_id) and
      Repo.exists?(from(f in Finding, where: f.id == ^finding_id and f.status != "open"))
  end

  @doc """
  The source messages behind a finding's citations that `user_id` may read,
  in citation order: `%{id, space_id, content, author, inserted_at, url}`.
  A citation whose space the viewer cannot read, or whose message is gone,
  is dropped.
  """
  @spec source_messages(Finding.t(), String.t()) :: [map()]
  def source_messages(%Finding{evidence: evidence}, user_id) when is_binary(user_id) do
    pairs =
      (evidence || %{})
      |> Map.get("citations", [])
      |> List.wrap()
      |> Enum.flat_map(&parse_citation/1)

    message_ids = Enum.map(pairs, &elem(&1, 1))

    if message_ids == [] do
      []
    else
      messages =
        from(m in Message,
          join: s in Space,
          on: s.id == m.space_id,
          where: m.id in ^message_ids and is_nil(m.deleted_at),
          select: {m, s}
        )
        |> Repo.all()
        |> Map.new(fn {m, s} -> {m.id, {m, s}} end)

      scope = Scope.for_user(%{id: user_id})

      Enum.flat_map(pairs, fn {space_id, message_id} ->
        with {m, s} <- Map.get(messages, message_id),
             true <- m.space_id == space_id,
             :ok <- Access.check(scope, "chat.read", {:space, space_id}) do
          [
            %{
              id: m.id,
              space_id: space_id,
              content: m.content,
              author: m.author_display_name,
              inserted_at: m.inserted_at,
              url: "/chat/#{Platform.Chat.space_path_segment(s)}?message=#{m.id}"
            }
          ]
        else
          _ -> []
        end
      end)
    end
  end

  def source_messages(_finding, _user_id), do: []

  @doc """
  A mockup ref as an attachment path (`/chat/attachments/<uuid>`), or nil.
  A bare uuid is read as an attachment id. Anything else renders nothing:
  the image viewer opens only raw attachment paths.
  """
  @spec mockup_src(term()) :: String.t() | nil
  def mockup_src("/chat/attachments/" <> id = path) do
    if Platform.UUID.valid?(id), do: path
  end

  def mockup_src(ref) when is_binary(ref) do
    if Platform.UUID.valid?(ref), do: "/chat/attachments/" <> ref
  end

  def mockup_src(_ref), do: nil

  @doc "The text an answer records: the choice, its option, then the note."
  @spec answer_text(answer(), String.t() | nil) :: String.t()
  def answer_text(%{label: label, option: option}, note) do
    head =
      case option do
        %{"label" => opt} when is_binary(opt) -> label <> ": " <> opt
        _ -> label
      end

    if is_binary(note) and note != "", do: head <> "\nNote: " <> note, else: head
  end

  # ── internals ──────────────────────────────────────────────────────────

  defp lock_for_recipient(finding_id, user_id) do
    if Platform.UUID.valid?(finding_id) and Platform.UUID.valid?(user_id) do
      Repo.one(
        from(f in Finding,
          where: f.id == ^finding_id and f.recipient_user_id == ^user_id,
          lock: "FOR UPDATE"
        )
      )
    end
  end

  defp ensure_open(%Finding{status: "open"}), do: :ok
  defp ensure_open(_finding), do: {:error, :already_answered}

  defp choose(finding, key) do
    case Enum.find(answers(finding), &(&1.key == key)) do
      nil -> {:error, :invalid_answer}
      choice -> {:ok, choice}
    end
  end

  defp resolve(finding, %{key: key} = choice, note) do
    status = if key == "not_now", do: "dismissed", else: "answered"

    finding
    |> Finding.resolve_changeset(status, answer_text(choice, note))
    |> Repo.update()
  end

  defp clean_note(note) when is_binary(note) do
    note |> String.trim() |> String.slice(0, @max_note)
  end

  defp clean_note(_note), do: nil

  defp parse_citation("chat:" <> rest) do
    case String.split(rest, ":") do
      [space_id, message_id] ->
        if Platform.UUID.valid?(space_id) and Platform.UUID.valid?(message_id),
          do: [{space_id, message_id}],
          else: []

      _ ->
        []
    end
  end

  defp parse_citation(_), do: []

  # The outcome goes to the linked task's execution log, never to chat. An
  # engagement, so the agent working the task reads it. Best effort: the
  # answer is already recorded and the row cleared.
  defp post_to_task(%Finding{task_id: nil}), do: :no_task

  defp post_to_task(%Finding{task_id: task_id} = finding) do
    case ExecutionSpace.find_by_task_id(task_id) do
      nil ->
        :no_task

      space ->
        case ExecutionSpace.post_engagement(space.id, outcome_message(finding),
               metadata: %{"reason" => "ux_decision_answered", "finding_id" => finding.id}
             ) do
          {:ok, _msg} ->
            :ok

          {:error, reason} ->
            Logger.warning("[ux_decision] task post failed: #{inspect(reason)}")
            :error
        end
    end
  rescue
    e ->
      Logger.warning("[ux_decision] task post raised: #{inspect(e.__struct__)}")
      :error
  end

  @doc "The task-log message for an answered finding."
  @spec outcome_message(Finding.t()) :: String.t()
  def outcome_message(%Finding{} = finding) do
    verb = if finding.status == "dismissed", do: "deferred", else: "answered"
    "UX decision #{verb}: #{finding.question}\n\n#{finding.answer}"
  end

  defp plural(1, word), do: word
  defp plural(_n, word), do: word <> "s"
end
