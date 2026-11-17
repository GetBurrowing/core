defmodule Platform.Showrunner.Board do
  @moduledoc """
  The weekly episode canvas as the three `showrunner.*` handlers read and
  write it (task 01a1eaf6 stage 3).

  `Platform.Showrunner.Episode` is the state model; this module is the I/O
  around it:

    * `current/1` — the space's newest episode board (a canvas whose
      `metadata["showrunner"]["board"]` is `"episode"`);
    * `read/1` — the live document (through `Platform.Chat.Canvas.Server`, so
      an unpersisted patch is seen) and `Episode.from_document/1` over it;
    * `create/3` — a new board from the `episode_board` template;
    * `write/4` — `Episode.to_document/1`'s nodes merged into the board, as
      one `replace_document` patch, so the template's collapsed sections and
      anything a human added survive;
    * `escalate/3` — one human decision: a message in the show's space and ONE
      inbox row to the configured `escalate_user_id`;
    * `unreadable/3` — the hand-edited-board path: log, one Needs-you item
      (best effort, on the raw `needs_you` node), the escalation, never a raise.

  Every write is made as the assigned agent (`{:agent, id}`), which must be a
  participant of the space; the canvas and message rows then name who acted.
  """

  require Logger

  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.Canvas.Templates
  alias Platform.Inbox
  alias Platform.Showrunner.Episode

  @unreadable_id "board-unreadable"
  @unreadable_question "The episode board was edited and can't be read; restore or fix it"
  @unreadable_options ["Restored", "Fixed"]

  @typedoc "Who acts and where: the assigned agent, its participant row, the show's space."
  @type ctx :: %{
          required(:space_id) => String.t(),
          required(:agent_id) => String.t(),
          required(:participant_id) => String.t(),
          optional(:escalate_user_id) => String.t() | nil
        }

  @doc "The Needs-you question a hand-edited, unreadable board raises."
  @spec unreadable_question() :: String.t()
  def unreadable_question, do: @unreadable_question

  @doc """
  The acting context for `agent` in `space_id`: `{:ok, ctx}`, or
  `{:error, :agent_not_in_space}` when the agent has no participant row there.
  """
  @spec context(String.t() | nil, map() | nil, String.t() | nil) ::
          {:ok, ctx()} | {:error, term()}
  def context(space_id, agent, escalate_user_id \\ nil)

  def context(nil, _agent, _escalate), do: {:error, :no_space_configured}
  def context(_space_id, nil, _escalate), do: {:error, :no_assignee}

  def context(space_id, %{id: agent_id}, escalate_user_id) when is_binary(space_id) do
    case Chat.get_agent_participant(space_id, agent_id) do
      %{id: participant_id} ->
        {:ok,
         %{
           space_id: space_id,
           agent_id: agent_id,
           participant_id: participant_id,
           escalate_user_id: escalate_user_id
         }}

      nil ->
        {:error, :agent_not_in_space}
    end
  end

  @doc "The space's newest episode board, or nil."
  @spec current(String.t()) :: Canvas.t() | nil
  def current(space_id) when is_binary(space_id) do
    space_id
    |> Chat.list_canvases(order: :inserted_desc)
    |> Enum.find(&board?/1)
  end

  @doc "Every episode board in the space, newest first."
  @spec list(String.t()) :: [Canvas.t()]
  def list(space_id) when is_binary(space_id) do
    space_id
    |> Chat.list_canvases(order: :inserted_desc)
    |> Enum.filter(&board?/1)
  end

  @doc "True for a canvas the showrunner created as an episode board."
  @spec board?(term()) :: boolean()
  def board?(%Canvas{metadata: %{"showrunner" => %{"board" => "episode"}}}), do: true
  def board?(_), do: false

  @doc "The board's episode number from its metadata, or nil."
  @spec number(Canvas.t()) :: pos_integer() | nil
  def number(%Canvas{metadata: %{"showrunner" => %{"episode_number" => n}}}) when is_integer(n),
    do: n

  def number(_), do: nil

  @doc "The ISO week (`\"2026-W47\"`) a board was pitched for, or nil."
  @spec week(Canvas.t()) :: String.t() | nil
  def week(%Canvas{metadata: %{"showrunner" => %{"week" => week}}}) when is_binary(week), do: week
  def week(_), do: nil

  @doc "The ISO week label for `at`."
  @spec week_label(DateTime.t()) :: String.t()
  def week_label(%DateTime{} = at) do
    {year, week} = at |> DateTime.to_date() |> Date.to_erl() |> :calendar.iso_week_number()
    "#{year}-W#{String.pad_leading(Integer.to_string(week), 2, "0")}"
  end

  @doc """
  Reads the board: `{:ok, episode, document}`, or `{:error, reason}` when the
  document is not an episode `Episode.from_document/1` can read (a hand edit).
  Never raises.
  """
  @spec read(Canvas.t()) :: {:ok, Episode.t(), map()} | {:error, term()}
  def read(%Canvas{} = canvas) do
    document = live_document(canvas)

    case Episode.from_document(document) do
      {:ok, episode} -> {:ok, episode, document}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  end

  @doc """
  Creates this week's board from the `episode_board` template with `episode`'s
  nodes, posted into the space as the agent's message. `metadata` lands under
  `metadata["showrunner"]`.
  """
  @spec create(ctx(), Episode.t(), map()) :: {:ok, Canvas.t()} | {:error, term()}
  def create(ctx, %Episode{} = episode, metadata) when is_map(metadata) do
    document =
      "episode_board"
      |> Templates.get()
      |> Map.fetch!(:document)
      |> blank_collapsed()
      |> merge(episode)

    attrs = %{
      title: "Episode #{episode.number}: #{episode.title}",
      document: document,
      metadata: %{
        "showrunner" =>
          metadata
          |> Map.new(fn {k, v} -> {to_string(k), v} end)
          |> Map.merge(%{"board" => "episode", "episode_number" => episode.number})
      }
    }

    case Chat.create_canvas_with_message(ctx.space_id, ctx.participant_id, attrs) do
      {:ok, canvas, _message} -> {:ok, canvas}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Writes `episode` onto the board `document` was read from, as the agent."
  @spec write(ctx(), Canvas.t(), map(), Episode.t()) :: {:ok, Canvas.t()} | {:error, term()}
  def write(ctx, %Canvas{} = canvas, document, %Episode{} = episode) do
    case Chat.patch_canvas({:agent, ctx.agent_id}, canvas, [
           {:replace_document, merge(document, episode)}
         ]) do
      {:ok, canvas} -> {:ok, canvas}
      {:conflict, payload} -> {:error, {:conflict, payload}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Merges `episode`'s three typed nodes into `document` by TYPE (keeping each
  existing node's id and position), its fields under `meta["showrunner"]`,
  and its brief into the collapsed `episode-brief` section. Every other node is
  kept as it was.
  """
  @spec merge(map(), Episode.t()) :: map()
  def merge(document, %Episode{} = episode) do
    fresh = Episode.to_document(episode)
    by_type = Map.new(fresh["root"]["children"], &{&1["type"], &1})
    children = get_in(document, ["root", "children"]) || []

    {merged, seen} =
      Enum.map_reduce(children, MapSet.new(), fn child, seen ->
        case Map.fetch(by_type, child["type"]) do
          {:ok, node} -> {Map.put(node, "id", child["id"]), MapSet.put(seen, child["type"])}
          :error -> {child, seen}
        end
      end)

    missing =
      fresh["root"]["children"]
      |> Enum.reject(&MapSet.member?(seen, &1["type"]))

    meta =
      (document["meta"] || %{})
      |> Map.put("showrunner", fresh["meta"]["showrunner"])

    document
    |> put_in(["root", "children"], missing ++ merged)
    |> Map.put("meta", meta)
    |> put_brief(episode.brief)
  end

  @doc """
  Puts one human decision to a person: a message in the show's space naming
  the question and its options, and ONE inbox row to `ctx.escalate_user_id`
  pointing at that message. No `escalate_user_id` means the message only.
  Returns `{:ok, message}`; never raises.
  """
  @spec escalate(ctx(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def escalate(ctx, %{question: question, options: options} = _item, opts \\ []) do
    content =
      "Needs you: #{question}\n" <>
        Enum.map_join(options, "\n", &"- #{&1}") <>
        case Keyword.get(opts, :detail) do
          detail when is_binary(detail) and detail != "" -> "\n\n" <> detail
          _ -> ""
        end

    with {:ok, message} <-
           Chat.post_message(%{
             space_id: ctx.space_id,
             participant_id: ctx.participant_id,
             content_type: "text",
             content: content,
             metadata: %{"source" => "showrunner", "skip_mention_scan" => true}
           }) do
      inbox(ctx, message, question)
      {:ok, message}
    end
  rescue
    error ->
      Logger.warning("[showrunner] escalation raised: #{Exception.message(error)}")
      {:error, :escalation_failed}
  end

  @doc """
  The hand-edited-board path. Logs `reason`, appends one Needs-you item to the
  raw `needs_you` node when there is one and it does not already carry it,
  and escalates the same question. Always `:ok`; never raises.
  """
  @spec unreadable(ctx(), Canvas.t(), term()) :: :ok
  def unreadable(ctx, %Canvas{} = canvas, reason) do
    Logger.warning(
      "[showrunner] episode board #{canvas.id} cannot be read: #{inspect(reason)}; " <>
        "raising a Needs-you item instead"
    )

    item = %{
      "id" => @unreadable_id,
      "question" => @unreadable_question,
      "options" => @unreadable_options
    }

    document = live_document(canvas)

    case append_raw_needs_you(document, item) do
      {:ok, patched} ->
        case Chat.patch_canvas({:agent, ctx.agent_id}, canvas, [{:replace_document, patched}]) do
          {:ok, _} -> :ok
          other -> Logger.warning("[showrunner] could not mark the board: #{inspect(other)}")
        end

      :already_raised ->
        :ok

      :no_node ->
        :ok
    end

    unless already_raised?(document) do
      escalate(ctx, %{question: @unreadable_question, options: @unreadable_options},
        detail: "Board: #{canvas.title || canvas.id}"
      )
    end

    :ok
  rescue
    error ->
      Logger.warning("[showrunner] unreadable-board path raised: #{Exception.message(error)}")
      :ok
  end

  # ── internals ──

  defp live_document(%Canvas{id: id, document: stored}) do
    case CanvasServer.describe(id) do
      {:ok, %{document: document}} when is_map(document) -> document
      _ -> stored
    end
  catch
    _, _ -> stored
  end

  defp inbox(%{escalate_user_id: user_id} = ctx, message, question) when is_binary(user_id) do
    space = Chat.get_space(ctx.space_id)

    case Inbox.emit(%{
           user_id: user_id,
           kind: "chat_mention",
           source_type: "chat_message",
           source_id: message.id,
           title: "Showrunner needs you: #{question}",
           body: String.slice(message.content || "", 0, 200),
           url: space && "/chat/#{Chat.space_path_segment(space)}?message=#{message.id}"
         }) do
      {:ok, _item} -> :ok
      other -> Logger.warning("[showrunner] inbox row refused: #{inspect(other)}")
    end
  end

  defp inbox(_ctx, _message, _question), do: :ok

  defp already_raised?(document) do
    case raw_needs_you(document) do
      %{"props" => %{"items" => items}} when is_list(items) ->
        Enum.any?(items, &(is_map(&1) and &1["id"] == @unreadable_id))

      _ ->
        false
    end
  end

  defp append_raw_needs_you(document, item) do
    case raw_needs_you(document) do
      %{"id" => node_id, "props" => %{"items" => items}} when is_list(items) ->
        if Enum.any?(items, &(is_map(&1) and &1["id"] == @unreadable_id)) do
          :already_raised
        else
          {:ok, update_node(document, node_id, &put_in(&1, ["props", "items"], items ++ [item]))}
        end

      _ ->
        :no_node
    end
  end

  defp raw_needs_you(%{"root" => root}) when is_map(root), do: find_type(root, "needs_you")
  defp raw_needs_you(_), do: nil

  defp find_type(%{"type" => type} = node, type), do: node

  defp find_type(%{"children" => children}, type) when is_list(children),
    do: Enum.find_value(children, &(is_map(&1) && find_type(&1, type)))

  defp find_type(_node, _type), do: nil

  defp update_node(document, node_id, fun) do
    Map.update!(document, "root", &update_tree(&1, node_id, fun))
  end

  defp update_tree(%{"id" => id} = node, id, fun), do: fun.(node)

  defp update_tree(%{"children" => children} = node, id, fun) when is_list(children),
    do: Map.put(node, "children", Enum.map(children, &update_tree(&1, id, fun)))

  defp update_tree(node, _id, _fun), do: node

  # The template's collapsed sections carry sample copy; a real board starts empty.
  defp blank_collapsed(document) do
    document
    |> set_details("episode-brief", "Research brief", "Not written yet.")
    |> set_details("episode-guests", "Guests", "No guests yet.")
    |> set_details("episode-retro", "Last week's retro", "No retro yet.")
  end

  defp put_brief(document, brief) when is_binary(brief) and brief != "",
    do: set_details(document, "episode-brief", "Research brief", brief)

  defp put_brief(document, _brief), do: document

  defp set_details(document, node_id, summary, body) do
    update_node(document, node_id, fn node ->
      put_in(
        node,
        ["props", "content"],
        "<details>\n<summary>#{summary}</summary>\n\n#{body}\n\n</details>"
      )
    end)
  end
end
