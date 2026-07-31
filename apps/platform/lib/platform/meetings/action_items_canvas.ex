defmodule Platform.Meetings.ActionItemsCanvas do
  @moduledoc """
  The per-meeting action-items canvas: where it lives, how to find it,
  and what is currently on it.

  Task 019fb90f-36e3 moved `meetings.action_items` off "a meeting just
  ended, extract a list" and onto "an utterance just landed, reconcile
  the meeting's live action-items canvas". That canvas is a durable
  object with an identity, so locating it is a real concern with real
  failure modes — and it does not belong inside a responsibility
  handler, which should stay a handler. It lives here.

  Stage 2 of that task shipped the READ half — `locate/2` and
  `summarize/1`. Stage 4 adds the WRITE half — `create/3` and
  `apply_operations/2` — on the same module, against the same
  `@metadata_source_key` / `@metadata_meeting_id_key` attributes, so the
  writer and the reader cannot drift apart on which keys mark a canvas
  as ours.

  ## Why a `checklist`, not a markdown blob

  The document is one `checklist` node whose children are
  `checklist_item`s. That is a structural choice, not a cosmetic one:

    * `checklist_item` carries `state` (`pending | active | complete`)
      and `checked`, and renders a real toggle, so "Priya already did
      that" is a state change on a node rather than a rewrite of a
      paragraph.
    * The parent `checklist` renders a complete/total counter, so the
      meeting can see its own progress without anyone re-reading the
      list.
    * The post-meeting triage path already reads `checklist_item`
      children under an actions section, so this canvas is consumable
      by it unchanged.

  A markdown node would render the same words and support none of that.

  ## Item identity is label text, deliberately

  `apply_operations/2` matches the model's `match` string against the
  NORMALIZED LABEL of the items currently on the canvas. It does not use
  the classifier's `dedupe_key`, and it does not accept an item handle
  the model invented. The classifier is a cheap fast model whose only
  job was noticing an utterance is about action items; trusting it with
  add-vs-update-vs-delete would put item identity in the hands of the
  component least able to carry it, and a model that invents handles
  invents them differently on every turn.

  An unresolved `update` or `remove` is SKIPPED and logged rather than
  guessed at. Turning an unresolved update into an add is the tempting
  alternative and it is wrong in the one case that matters: the match
  failed because our identity rule and the model disagree about which
  item is which, and writing anything at that point writes the wrong
  thing. Skipping loses one edit; guessing corrupts the list.

  ## Writes go to head, so a conflict is a deleted node, not a stale one

  `Platform.Chat.patch_canvas/3` re-reads the canvas's current revision
  and submits at head, so the "stale base revision" branch of
  `Canvas.Server`'s rebase-or-reject can never fire through this path.
  What CAN fire is `:target_deleted`: the node ids these operations
  address are resolved from a snapshot taken before the model round
  trip, and a concurrent writer can remove one in between.

  That is why the single retry RE-RESOLVES rather than re-submitting.
  Replaying the same node ids against the same head would conflict
  identically forever; re-reading the document, re-matching the labels,
  and rebuilding the operations is the only retry that can succeed.

  ## Why the canvas is found by listing and filtering

  `locate/2` reads every canvas in the space via
  `Platform.Chat.list_canvases/1` and filters in Elixir on
  `metadata["source"]` and `metadata["meeting_id"]`. That is a table
  scan of one space's canvases, and it is deliberate:

    * `list_canvases/2` is the only public read on `chat_canvases` that
      is not keyed by canvas id. Reaching past it means either a new
      public function or a `Repo` call from outside the `Chat` context.
    * Per-space canvas counts are small — a space accumulates canvases
      at human pace, not at message pace — so the scan is bounded by
      something people do, not by something the system does.
    * A JSONB-indexed metadata query is the right answer at a scale this
      task does not have, and adding one would mean a migration, an
      index, and a query path that only this caller uses.

  This is a trade that was made, not a lookup that was overlooked. If a
  space ever holds enough canvases for the scan to matter, the fix is a
  `where: fragment("metadata->>'source' = ?", ...)` read here plus a GIN
  index — a change contained to this module.

  ## Most-recent wins

  Nothing stops a space from holding two canvases that both claim the
  same meeting: a crashed create that retried, an operator clone, a
  restored soft-delete. Rather than pick arbitrarily or fail,
  `locate/2` orders the matches and answers the newest. Ordering is on
  `{inserted_at, id}` rather than on `list_canvases/1`'s own `order_by`,
  so the tie-break is explicit here: ids are UUIDv7 and therefore
  monotonic, which resolves two rows inserted inside the same
  microsecond.
  """

  require Logger

  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.CanvasDocument
  alias Platform.Orchestration.ExecutionSpace

  # The two metadata keys that mark a canvas as this meeting's
  # action-items canvas. `locate/2` filters on them; stage 4's `create/3`
  # writes them. They are attributes rather than inline literals
  # precisely so the reader and the writer move together — a typo in one
  # half would otherwise produce a canvas that is created successfully
  # and then never found again, on every subsequent utterance, silently.
  @metadata_source_key "source"
  @metadata_meeting_id_key "meeting_id"
  @metadata_source "meeting_action_items"

  @typedoc """
  One row of the canvas as the prompt sees it.

  `node_id` is the canvas node id, which is what stage 4's patch
  operations address. `state` follows `checklist_item`'s enum
  (`pending | active | complete`).
  """
  @type item :: %{node_id: String.t() | nil, label: String.t(), state: String.t()}

  @doc "The `metadata[\"source\"]` value that marks a canvas as ours."
  @spec metadata_source() :: String.t()
  def metadata_source, do: @metadata_source

  @doc """
  Build the metadata map stamped on an action-items canvas.

  Exposed so stage 4's `create/3` and this module's `locate/2` are
  provably reading and writing the same keys.
  """
  @spec metadata_for(String.t()) :: map()
  def metadata_for(meeting_id) when is_binary(meeting_id) do
    %{@metadata_source_key => @metadata_source, @metadata_meeting_id_key => meeting_id}
  end

  @doc """
  Find the action-items canvas for `meeting_id` inside `space_id`.

  Returns `{:ok, %Canvas{}}` for the most recent match, or `:missing`
  when the meeting has no canvas yet. `:missing` is an ordinary outcome,
  not an error: every meeting's first action item arrives before its
  canvas exists.

  A blank or non-binary `space_id` / `meeting_id` is `:missing` as well.
  Mid-meeting the payload can carry a nil space (the transcript row may
  not exist yet), and "we could not work out where to look" and "we
  looked and found nothing" lead to the same next step — stage 4 creates
  one — so they are not distinguished here.
  """
  @spec locate(String.t() | nil, String.t() | nil) :: {:ok, Canvas.t()} | :missing
  def locate(space_id, meeting_id)
      when is_binary(space_id) and space_id != "" and
             is_binary(meeting_id) and meeting_id != "" do
    space_id
    |> list_canvases()
    |> Enum.filter(&ours?(&1, meeting_id))
    |> Enum.sort_by(&{&1.inserted_at, &1.id})
    |> List.last()
    |> case do
      %Canvas{} = canvas -> {:ok, canvas}
      nil -> :missing
    end
  end

  def locate(_space_id, _meeting_id), do: :missing

  @doc """
  The current contents of an action-items canvas, as the prompt reads it.

  Walks the document tree for `checklist` nodes and returns their
  `checklist_item` children in document order. Only `checklist` children
  are collected — `Kinds.Checklist.children/0` restricts them to
  `checklist_item`, so anything else under a checklist is a document
  that would not have validated, and a `checklist_item` outside a
  checklist is not a rendered action item.

  An item with no `state` prop is reported as `"pending"`. That is the
  same reading `Kinds.Checklist`'s complete/total counter takes (it
  counts `state == "complete"` and nothing else), so the prompt and the
  rendered canvas agree on what is done.

  Accepts a `%Canvas{}` or a bare document map. Returns `[]` for
  anything it cannot walk, including `nil` — a canvas with no checklist
  has no items, which is the same thing the prompt needs to know.
  """
  @spec summarize(Canvas.t() | map() | nil) :: [item()]
  def summarize(%Canvas{document: document}), do: summarize(document)

  def summarize(document) when is_map(document) do
    document
    |> get_field("root")
    |> collect_items()
  end

  def summarize(_), do: []

  @doc """
  The document revision of a canvas, or `0` when it has none.

  Thin wrapper over `CanvasDocument.revision/1` so callers do not have
  to know that the revision lives inside the document JSON rather than
  in a column on `chat_canvases`.
  """
  @spec revision(Canvas.t() | map() | nil) :: non_neg_integer()
  def revision(%Canvas{document: document}), do: revision(document)
  def revision(document) when is_map(document), do: CanvasDocument.revision(document)
  def revision(_), do: 0

  # ── the write half (task 019fb90f-36e3 stage 4) ────────────────────────────

  @typedoc """
  One reconciliation operation, as `MeetingActionItems.extract_operations/1`
  normalises it out of the model's answer.

  `:match` identifies an existing item by quoting enough of its label
  back; it is meaningless for `:add`. `:label` is the new text (`:add`
  and `:update`); `:state` is the new `checklist_item` state.
  """
  @type operation :: %{
          op: :add | :update | :remove,
          match: String.t() | nil,
          label: String.t() | nil,
          state: String.t() | nil
        }

  @typedoc "An item as `create/3` writes it."
  @type new_item :: %{label: String.t(), state: String.t() | nil}

  # `checklist_item`'s schema enum. Read off the kind rather than
  # restated, so a state added to the kind does not silently become
  # unwritable here.
  @item_states Platform.Chat.Canvas.Kinds.ChecklistItem.schema()
               |> get_in(["properties", "state", "enum"])

  @default_item_state "pending"

  @doc """
  Create the meeting's action-items canvas with `items` on it.

  Returns `{:ok, %Canvas{}}`, or `{:error, reason}`.

  Goes through `Platform.Chat.create_canvas_with_message/3` rather than
  `create_canvas/1` so the companion chat message lands in the same
  transaction. That message is the in-chat surface for "action items
  appeared" — without it the canvas exists and nobody in the meeting is
  told. It is deliberately NOT
  `Platform.Meetings.post_action_items_to_space/3`: that renders a
  markdown checklist of the whole list, which mid-meeting would repost
  the entire canvas once per utterance. It stays the POST-meeting
  surface.

  The author is the space's system participant, resolved exactly the way
  `Meetings.post_action_items_to_space/3` resolves it.
  """
  @spec create(String.t(), String.t(), [new_item()]) :: {:ok, Canvas.t()} | {:error, term()}
  def create(space_id, meeting_id, items)
      when is_binary(space_id) and space_id != "" and
             is_binary(meeting_id) and meeting_id != "" and is_list(items) do
    with {:ok, participant} <- ExecutionSpace.ensure_system_participant(space_id) do
      attrs = %{
        "title" => title_for(meeting_id),
        "metadata" => metadata_for(meeting_id),
        "document" => document_with(items)
      }

      case Chat.create_canvas_with_message(space_id, participant.id, attrs) do
        {:ok, canvas, _message} -> {:ok, canvas}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def create(_space_id, _meeting_id, _items), do: {:error, :invalid_create_target}

  @doc """
  Reconcile `operations` onto an existing canvas.

  Returns `{:ok, canvas}` — the refreshed struct on a write, the given
  one when nothing resolved — or `{:error, :canvas_conflict}` when the
  document moved under us twice, or `{:error, reason}` for anything
  else.

  Zero resolvable operations is a SUCCESS with no write. Most utterances
  in a meeting change nothing about the action-items list, and a canvas
  whose revision ticked once per utterance would be unreadable history.
  """
  @spec apply_operations(Canvas.t(), [operation()]) ::
          {:ok, Canvas.t()} | {:error, :canvas_conflict} | {:error, term()}
  def apply_operations(%Canvas{} = canvas, operations) when is_list(operations) do
    do_apply_operations(canvas, own_document(canvas), operations, 1)
  end

  @doc """
  The items an absent canvas should be CREATED with, given the model's
  operations.

  Only `:add` survives. An `:update` or `:remove` against a canvas that
  does not exist has nothing to act on — the model was reconciling
  against a list it was told was empty — so it is dropped here rather
  than being reinterpreted as an add. Same rule as the unresolved-match
  case in `apply_operations/2`, for the same reason.
  """
  @spec items_for_create([operation()]) :: [new_item()]
  def items_for_create(operations) when is_list(operations) do
    operations
    |> Enum.filter(&(op_kind(&1) == :add))
    |> Enum.map(&%{label: op_label(&1), state: op_state(&1)})
    |> Enum.reject(&(normalize_label(&1.label) == ""))
  end

  def items_for_create(_), do: []

  @doc """
  The canonical document for a fresh action-items canvas.

  Exposed so a test can assert the shape `create/3` writes without
  reaching into the database for it.
  """
  @spec document_with([new_item()]) :: map()
  def document_with(items) when is_list(items) do
    document = CanvasDocument.new()

    put_in(document, ["root", "children"], [checklist_node(items)])
  end

  # ── write internals ────────────────────────────────────────────────────────

  defp do_apply_operations(%Canvas{} = canvas, document, operations, retries_left) do
    case resolve_operations(document, operations) do
      [] ->
        Logger.info(
          "[ActionItemsCanvas] no resolvable operations canvas=#{canvas.id} — " <>
            "document left unchanged"
        )

        {:ok, canvas}

      patch_ops ->
        submit(canvas, operations, patch_ops, retries_left)
    end
  end

  defp submit(%Canvas{} = canvas, operations, patch_ops, retries_left) do
    case Chat.patch_canvas(:system, canvas, patch_ops) do
      {:ok, updated} ->
        {:ok, updated}

      {:conflict, payload} when retries_left > 0 ->
        # Re-RESOLVE, do not re-submit. The node ids in `patch_ops` were
        # matched against a document that has since moved; replaying them
        # would hit the same rejection every time.
        #
        # Logged at WARNING, not info: a conflict here means two writers
        # raced on one meeting's canvas, which the serial intent cursor is
        # supposed to make impossible. One is unremarkable; a stream of
        # them says the cursor is not doing its job, and that is not
        # something to find out by turning the log level up.
        Logger.warning(
          "[ActionItemsCanvas] patch conflict canvas=#{canvas.id} " <>
            "reason=#{inspect(Map.get(payload, :reason))} — re-resolving once"
        )

        refreshed = refresh(canvas)

        do_apply_operations(refreshed, head_document(refreshed), operations, retries_left - 1)

      {:conflict, payload} ->
        Logger.warning(
          "[ActionItemsCanvas] patch conflict persisted after retry canvas=#{canvas.id} " <>
            "reason=#{inspect(Map.get(payload, :reason))}"
        )

        {:error, :canvas_conflict}

      {:error, reason} ->
        Logger.warning(
          "[ActionItemsCanvas] patch failed canvas=#{canvas.id} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # The FIRST attempt resolves against the document of the canvas the
  # caller handed over — the row as they read it. The RETRY resolves
  # against `head_document/1`, the live server state.
  #
  # That asymmetry is the point. `Canvas.Server` is the authoritative
  # writer and Postgres is an async write-through sink, so a row read a
  # moment ago can be behind head; when it is, the node ids resolved from
  # it may name something head no longer has, and the patch comes back
  # `:target_deleted`. Re-submitting the same operations would fail
  # identically forever. Re-reading head and re-matching the labels is
  # the only retry that can succeed — and it is why "retry once" is
  # enough rather than a loop: the second attempt is already working from
  # the same state the writer is.
  defp own_document(%Canvas{document: %{"root" => _} = document}), do: document
  defp own_document(%Canvas{} = canvas), do: head_document(canvas)

  defp head_document(%Canvas{id: id, document: document}) do
    case CanvasServer.describe(id) do
      {:ok, %{document: %{} = live}} -> live
      _ -> document
    end
  rescue
    _ -> document
  end

  defp refresh(%Canvas{id: id} = canvas), do: Chat.get_canvas(id) || canvas

  # Operations are folded in ORDER against a running view of the items,
  # so a `remove` followed by an `update` of the same label does not
  # address a node the earlier operation deleted, and an `add` is
  # matchable by a later `update` in the same batch.
  defp resolve_operations(document, operations) do
    checklist_id = checklist_node_id(document)
    items = summarize(document)

    {patch_ops, _items} =
      Enum.reduce(operations, {[], items}, fn operation, {acc, current} ->
        {ops, next} = resolve_one(operation, current, checklist_id, document)
        {acc ++ ops, next}
      end)

    patch_ops
  end

  defp resolve_one(operation, items, checklist_id, document) do
    case op_kind(operation) do
      :add ->
        resolve_add(operation, items, checklist_id, document)

      :update ->
        resolve_update(operation, items)

      :remove ->
        resolve_remove(operation, items)

      nil ->
        Logger.info(
          "[ActionItemsCanvas] unrecognised operation verb — skipped " <>
            "operation=#{inspect(operation)}"
        )

        {[], items}
    end
  end

  # An `add` whose label EXACTLY matches an item already on the canvas is
  # collapsed into an update of that item — reconciling, not appending, is
  # the whole point of the canvas. The collapse is exact-match only: a
  # substring collapse would swallow "Email Rowan the audit" into "Email
  # Rowan", which are two commitments and two items.
  defp resolve_add(operation, items, checklist_id, document) do
    label = op_label(operation)

    cond do
      normalize_label(label) == "" ->
        {[], items}

      existing = exact_match(items, label) ->
        {[{:set_props, existing.node_id, item_props(label, op_state(operation))}],
         replace_item(items, existing.node_id, label, op_state(operation))}

      true ->
        node = item_node(label, op_state(operation))
        item = %{node_id: node["id"], label: label, state: node["props"]["state"]}

        {[append_op(checklist_id, node, document)], items ++ [item]}
    end
  end

  # No `checklist` on the document yet — a canvas someone created blank,
  # or one whose checklist was deleted. Append a fresh checklist holding
  # the item rather than failing: the alternative is an action item that
  # is silently dropped because of the shape of a document nobody looked
  # at.
  defp append_op(nil, node, document),
    do: {:append_child, root_id(document), checklist_node([]) |> Map.put("children", [node])}

  defp append_op(checklist_id, node, _document), do: {:append_child, checklist_id, node}

  defp resolve_update(operation, items) do
    case find_item(items, op_match(operation) || op_label(operation)) do
      nil ->
        log_unresolved(:update, operation)
        {[], items}

      item ->
        label = op_label(operation) || item.label
        state = op_state(operation) || item.state

        {[{:set_props, item.node_id, item_props(label, state)}],
         replace_item(items, item.node_id, label, state)}
    end
  end

  defp resolve_remove(operation, items) do
    case find_item(items, op_match(operation) || op_label(operation)) do
      nil ->
        log_unresolved(:remove, operation)
        {[], items}

      item ->
        {[{:delete_node, item.node_id}], Enum.reject(items, &(&1.node_id == item.node_id))}
    end
  end

  defp log_unresolved(kind, operation) do
    Logger.info(
      "[ActionItemsCanvas] #{kind} matched no item — skipped " <>
        "match=#{inspect(op_match(operation))} label=#{inspect(op_label(operation))}"
    )
  end

  # ── matching ───────────────────────────────────────────────────────────────

  defp find_item(_items, nil), do: nil

  defp find_item(items, needle) do
    normalized = normalize_label(needle)

    cond do
      normalized == "" ->
        nil

      item = exact_match(items, needle) ->
        item

      true ->
        # Ambiguity is UNRESOLVED, not first-wins. Two items that both
        # loosely match means we cannot tell which one the model meant,
        # and editing the wrong item is worse than editing none.
        case Enum.filter(items, &overlaps?(normalize_label(&1.label), normalized)) do
          [item] -> item
          _ -> nil
        end
    end
  end

  defp exact_match(items, needle) do
    normalized = normalize_label(needle)

    if normalized == "" do
      nil
    else
      Enum.find(items, &(normalize_label(&1.label) == normalized))
    end
  end

  defp overlaps?(label, needle) do
    label != "" and needle != "" and
      (String.contains?(label, needle) or String.contains?(needle, label))
  end

  # Case, surrounding whitespace, internal whitespace runs, and a
  # trailing full stop are all things a model varies between turns while
  # meaning the same item. Nothing else is stripped — dropping
  # punctuation wholesale would fuse "Ship v2" and "Ship v2.1".
  defp normalize_label(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim_trailing(".")
    |> String.downcase()
    |> String.trim()
  end

  defp normalize_label(_), do: ""

  # ── nodes ──────────────────────────────────────────────────────────────────

  defp checklist_node(items) do
    %{
      "id" => Ecto.UUID.generate(),
      "type" => "checklist",
      "props" => %{"title" => "Action Items"},
      "children" => Enum.map(items, &item_node(Map.get(&1, :label), Map.get(&1, :state)))
    }
  end

  defp item_node(label, state) do
    %{
      "id" => Ecto.UUID.generate(),
      "type" => "checklist_item",
      "props" => item_props(label, state)
    }
  end

  # `checked` is written alongside `state` because the two are read by
  # different consumers — the renderer falls back to `checked` when
  # `state` is absent, and the triage path reads `state`. Writing one and
  # not the other is how a toggled item renders unticked.
  defp item_props(label, state) do
    state = valid_state(state)

    %{"label" => to_string(label), "state" => state, "checked" => state == "complete"}
  end

  defp valid_state(state) when is_binary(state) do
    normalized = state |> String.trim() |> String.downcase()

    if normalized in @item_states, do: normalized, else: @default_item_state
  end

  defp valid_state(_), do: @default_item_state

  defp replace_item(items, node_id, label, state) do
    Enum.map(items, fn
      %{node_id: ^node_id} = item -> %{item | label: to_string(label), state: valid_state(state)}
      item -> item
    end)
  end

  defp checklist_node_id(document) do
    document
    |> get_field("root")
    |> find_checklist_id()
  end

  defp find_checklist_id(node) when is_map(node) do
    if get_field(node, "type") == "checklist" do
      get_field(node, "id")
    else
      node |> children() |> Enum.find_value(&find_checklist_id/1)
    end
  end

  defp find_checklist_id(_), do: nil

  defp root_id(document) do
    case document |> get_field("root") |> get_field("id") do
      id when is_binary(id) -> id
      _ -> "root"
    end
  end

  defp title_for(meeting_id) do
    case meeting_name(meeting_id) do
      nil -> "Action Items"
      name -> "Action Items — #{name}"
    end
  end

  defp meeting_name(meeting_id) do
    case Platform.Meetings.get_meeting(meeting_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ── operation field access ─────────────────────────────────────────────────
  #
  # Operations arrive normalised from the handler, but a caller that
  # hands over the raw string-keyed model map should not silently resolve
  # to zero operations — that is indistinguishable from "the meeting said
  # nothing actionable".

  @doc """
  The verb roster: every `op` string this module understands, mapped to
  the three things a reconciliation can do.

  Public because `MeetingActionItems.extract_operations/1` passes the
  model's verb through verbatim rather than classifying it. One roster,
  in one module — two would drift, and an operation the handler called a
  remove and this module called nothing at all fails silently.
  """
  @spec operation_kinds() :: %{String.t() => :add | :update | :remove}
  def operation_kinds do
    %{
      "add" => :add,
      "create" => :add,
      "new" => :add,
      "insert" => :add,
      "update" => :update,
      "modify" => :update,
      "amend" => :update,
      "edit" => :update,
      "complete" => :update,
      "remove" => :remove,
      "delete" => :remove,
      "drop" => :remove,
      "retract" => :remove
    }
  end

  defp op_kind(operation) when is_map(operation) do
    Map.get(operation_kinds(), operation |> op_field(:op) |> normalize_label())
  end

  defp op_kind(_), do: nil

  defp op_label(operation), do: op_field(operation, :label)
  defp op_match(operation), do: op_field(operation, :match)
  defp op_state(operation), do: op_field(operation, :state)

  defp op_field(operation, key) when is_map(operation) do
    case Map.get(operation, key) || Map.get(operation, Atom.to_string(key)) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp op_field(_operation, _key), do: nil

  # ── internals ──────────────────────────────────────────────────────────────

  # `list_canvases/1` reaches the database, and `locate/2` is called from
  # a context gatherer whose contract is "degrade, never raise" — a
  # canvas lookup failing must not take out the whole dispatch when the
  # utterance itself is still perfectly usable.
  defp list_canvases(space_id) do
    Chat.list_canvases(space_id)
  rescue
    error ->
      Logger.warning(
        "[ActionItemsCanvas] canvas lookup failed space=#{space_id} " <>
          "reason=#{inspect(error)}"
      )

      []
  end

  defp ours?(%Canvas{metadata: metadata}, meeting_id) when is_map(metadata) do
    Map.get(metadata, @metadata_source_key) == @metadata_source and
      Map.get(metadata, @metadata_meeting_id_key) == meeting_id
  end

  defp ours?(_canvas, _meeting_id), do: false

  # Depth-first walk. A `checklist` contributes its children and is not
  # descended into further; anything else is descended into, because a
  # checklist is normally nested inside a `stack` or a `card`.
  defp collect_items(node) when is_map(node) do
    case get_field(node, "type") do
      "checklist" ->
        node
        |> children()
        |> Enum.filter(&(get_field(&1, "type") == "checklist_item"))
        |> Enum.map(&to_item/1)

      _ ->
        node
        |> children()
        |> Enum.flat_map(&collect_items/1)
    end
  end

  defp collect_items(_), do: []

  defp children(node) when is_map(node) do
    case get_field(node, "children") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp children(_), do: []

  defp to_item(node) do
    props = get_field(node, "props") || %{}

    %{
      node_id: get_field(node, "id"),
      label: get_field(props, "label") || "",
      state: get_field(props, "state") || "pending"
    }
  end

  # Canvas documents come back string-keyed from Postgres and are
  # frequently written atom-keyed in a fixture or by a caller building a
  # document inline. Both spellings are read rather than depending on
  # either, the same way `IntentDispatcher.segment_field/3` does for
  # transcript segments.
  defp get_field(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, safe_atom(key))
    end
  end

  defp get_field(_map, _key), do: nil

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
