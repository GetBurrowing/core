defmodule Platform.Memory.Insights.BriefingCard do
  @moduledoc """
  The server-built daily briefing canvas document. Task
  `01a13867-3213-7001-a128-6b4c6b34283f`, stage 3. Mirrors
  `Platform.Access.ChangeCard`: platform code authors every node, and no
  room script and no write binding is involved.

  ## Sections

    * **Already done** — delivered `briefing` lines, each with Looks right
      (`insight_ok:<node_key>`) and Flag (`insight_flag:<node_key>`); and
      `page_edit` / `task` insights the Disseminator applied unattended
      (task `01a15587-afc8-7000-b76d-4e1c48eee5ed`, stages 3 and 4), each
      as a text line (`applied-<node_key>`) and a control row
      (`applied-actions-<node_key>`):
        * a page edit: Revert (`insight_revert:<node_key>`) and Flag;
        * a filed task: a link to the task (`applied-link-<node_key>`,
          see below), Delete task (`insight_delete_task:<node_key>`) and
          Flag.
      Revert and Delete task undo only that insight's own artefact; see
      `Platform.Memory.Insights.Actions` ("Undo from the briefing").
    * **Needs your call** — `needs_call` insights, for root admins only
      (`admin?: true`), with one link to `/memory/insights`. Never executed
      from here.
    * **Questions** — one form per `question`, id
      `insight_answer:<node_key>`, with an `answer` field.

  A section with no items is left out.

  ## Agent-authored prose is inert

  An insight body is written by the dreaming agent, so it renders ONLY as
  the `value` of a `text` node, which the canvas renders as literal text. It
  never enters a `markdown` node, an `action_row`, a form title or label, a
  node id or the document meta, so a hostile body cannot add a link, a
  button or an action value. The `markdown` nodes are platform-built: the
  Insights tab link is a constant, and a filed task's link is the constant
  shape `[Open task](/tasks/<uuid>)` whose uuid is read from the insight's
  `artefact_ref` (`"task:<uuid>"`, written by the platform when it filed
  the task) and checked with `Platform.UUID.valid?/1` (`filed_task_id/1`).
  Neither the body nor the agent-written `action` map ever reaches it; a
  ref that is not a valid uuid renders no link. The link is how the task
  is EDITED: under the clicker's ordinary task access, not the briefing's.

  ## How long an undo lasts

  Revert and Delete task live as long as the insight row: its TTL is 7
  days (`Platform.Memory.Insight`'s `@default_ttl_days`), after which
  `Platform.Memory.Insights.Purger` deletes the row whatever its state.
  Pages have no revision table, so the row's `pre_image` is the only copy
  of the content a Revert writes back; once the row is purged a re-render
  of the day's canvas drops the item (`Disseminator` skips purged
  insights) and its buttons go with it, and a click on an old canvas finds
  no insight and changes nothing. Delete task needs no pre-image, but its
  authority (which task, filed by whom) is also read from the row, so it
  ends with the row too. The TTL is not extended for this.

  ## Action values carry a node key, never an insight id

  `node_key/1` is a short digest of the insight id: stable, so the same
  insight keeps its key when the day's canvas is re-rendered, and opaque, so
  the document does not name the insight. `Platform.Memory.Briefing.items`
  maps the key back to the insight on the server.
  """

  alias Platform.Memory.Insight

  @insights_path "/memory/insights"

  @doc "The node key for an insight id (see the moduledoc)."
  @spec node_key(Insight.t() | binary()) :: String.t()
  def node_key(%Insight{id: id}), do: node_key(id)

  def node_key(id) when is_binary(id) do
    "i" <> (:crypto.hash(:sha256, id) |> Base.encode16(case: :lower) |> binary_part(0, 16))
  end

  @doc """
  Build the document for `date` from `entries`, a list of
  `{node_key, %Insight{}}` in display order.

  Options:
    * `:admin?` (default `false`) shows the "Needs your call" section.
    * `:settled` (default `%{}`) maps a node key to the stored nodes of an
      item already settled on the day's canvas (stage 4,
      `Platform.Memory.Insights.Briefings.settled_nodes/2`). Those nodes are
      rendered in the item's place instead of fresh controls, so a re-render
      never brings back a button that was already pressed.
  """
  @spec document(Date.t(), [{String.t(), Insight.t()}], keyword()) :: map()
  def document(%Date{} = date, entries, opts \\ []) when is_list(entries) do
    admin? = Keyword.get(opts, :admin?, false)
    settled = Keyword.get(opts, :settled, %{})
    {needs_call, executable} = Enum.split_with(entries, &needs_call?/1)

    done =
      Enum.filter(executable, fn {_k, i} -> i.action_type in ["briefing", "page_edit", "task"] end)

    questions = Enum.filter(executable, fn {_k, i} -> i.action_type == "question" end)

    sections =
      section("done", "Already done", Enum.map(done, &or_settled(&1, settled, :line))) ++
        if(admin?,
          do: section("call", "Needs your call", needs_call_items(needs_call, settled)),
          else: []
        ) ++
        section("questions", "Questions", Enum.map(questions, &or_settled(&1, settled, :q)))

    children =
      [
        node("heading", "title", %{
          "value" => "Your briefing · " <> Date.to_iso8601(date),
          "level" => 3
        })
      ] ++
        if sections == [],
          do: [text("empty", "Nothing new today.", "text-base-content/60")],
          else: sections

    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 12},
        "children" => children
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{"insight_briefing" => true, "digest_date" => Date.to_iso8601(date)}
    }
  end

  @doc """
  The id of the task a `task` insight filed, read from its `artefact_ref`
  (`"task:<uuid>"`) and checked with `Platform.UUID.valid?/1`; nil for
  anything else. The one reader of that ref, for the briefing link and for
  `Platform.Memory.Insights.Actions.delete_filed_task/3`.
  """
  @spec filed_task_id(Insight.t()) :: binary() | nil
  def filed_task_id(%Insight{action_type: "task", artefact_ref: "task:" <> task_id}) do
    if Platform.UUID.valid?(task_id), do: task_id, else: nil
  end

  def filed_task_id(_insight), do: nil

  defp task_link(task_id), do: "[Open task](/tasks/" <> task_id <> ")"

  defp needs_call?({_key, %Insight{tier: "needs_call"}}), do: true
  defp needs_call?(_entry), do: false

  defp section(_id, _title, []), do: []

  defp section(id, title, items) do
    [
      %{
        "id" => "section-" <> id,
        "type" => "card",
        "props" => %{"title" => title},
        "children" => List.flatten(items)
      }
    ]
  end

  # A settled item keeps the nodes it was settled with (stage 4).
  defp or_settled({key, _insight} = entry, settled, kind) do
    case Map.get(settled, key) do
      [_ | _] = nodes -> nodes
      _ when kind == :line -> done_line(entry)
      _ -> question(entry)
    end
  end

  defp done_line({key, %Insight{action_type: "page_edit"} = insight}) do
    [
      text("applied-" <> key, insight.body || ""),
      node("action_row", "applied-actions-" <> key, %{
        "actions" => [
          %{"label" => "Revert", "value" => "insight_revert:" <> key, "variant" => "outline"},
          %{"label" => "Flag", "value" => "insight_flag:" <> key, "variant" => "ghost"}
        ]
      })
    ]
  end

  defp done_line({key, %Insight{action_type: "task"} = insight}) do
    link =
      case filed_task_id(insight) do
        nil -> []
        task_id -> [node("markdown", "applied-link-" <> key, %{"content" => task_link(task_id)})]
      end

    [text("applied-" <> key, insight.body || "")] ++
      link ++
      [
        node("action_row", "applied-actions-" <> key, %{
          "actions" => [
            %{
              "label" => "Delete task",
              "value" => "insight_delete_task:" <> key,
              "variant" => "outline"
            },
            %{"label" => "Flag", "value" => "insight_flag:" <> key, "variant" => "ghost"}
          ]
        })
      ]
  end

  defp done_line(entry), do: briefing_line(entry)

  defp briefing_line({key, %Insight{} = insight}) do
    [
      text("done-" <> key, insight.body || ""),
      node("action_row", "done-actions-" <> key, %{
        "actions" => [
          %{"label" => "Looks right", "value" => "insight_ok:" <> key, "variant" => "outline"},
          %{"label" => "Flag", "value" => "insight_flag:" <> key, "variant" => "ghost"}
        ]
      })
    ]
  end

  defp needs_call_items([], _settled), do: []

  defp needs_call_items(entries, settled) do
    Enum.flat_map(entries, fn {key, %Insight{} = insight} ->
      case Map.get(settled, key) do
        [_ | _] = nodes -> nodes
        _ -> [text("call-" <> key, insight.body || "")]
      end
    end) ++
      [
        node("markdown", "call-link", %{
          "content" => "[Open Insights to decide](#{@insights_path})"
        })
      ]
  end

  defp question({key, %Insight{} = insight}) do
    [
      text("question-" <> key, insight.body || ""),
      node("form", "insight_answer:" <> key, %{
        "submit_label" => "Answer",
        "fields" => [
          %{"name" => "answer", "type" => "textarea", "label" => "Answer", "required" => true}
        ]
      })
    ]
  end

  defp text(id, value, class \\ ""),
    do: node("text", id, %{"value" => value, "class_overrides" => class})

  defp node(type, id, props), do: %{"type" => type, "id" => id, "props" => props}
end
