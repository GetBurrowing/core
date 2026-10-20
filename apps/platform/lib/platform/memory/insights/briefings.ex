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
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.CanvasDocument
  alias Platform.Memory.Briefing
  alias Platform.Memory.Insights.BriefingCard
  alias Platform.Repo

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

  @doc "Every briefing row that renders `insight_id`."
  @spec containing(binary()) :: [Briefing.t()]
  def containing(insight_id) when is_binary(insight_id) do
    key = BriefingCard.node_key(insight_id)

    from(b in Briefing, where: fragment("jsonb_exists(?, ?)", b.items, ^key))
    |> Repo.all()
    |> Enum.filter(&(insight_id(&1, key) == insight_id))
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

    patch(briefing.canvas_id, fn document ->
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
    note_node = text(note_id(key), note, "text-sm text-base-content/60")

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

  defp each_canvas(insight_id, ops_fun) do
    Enum.each(containing(insight_id), fn briefing -> patch(briefing.canvas_id, ops_fun) end)
  end

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
