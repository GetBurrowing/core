defmodule Platform.Memory.Insights.BriefingCard do
  @moduledoc """
  The server-built daily briefing canvas document. Task
  `01a13867-3213-7001-a128-6b4c6b34283f`, stage 3. Mirrors
  `Platform.Access.ChangeCard`: platform code authors every node, and no
  room script and no write binding is involved.

  ## Sections

    * **Already done** — delivered `briefing` lines, each with Looks right
      (`insight_ok:<node_key>`) and Flag (`insight_flag:<node_key>`).
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
  button or an action value. The one `markdown` node (the Insights tab link)
  is a constant.

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

    briefings = Enum.filter(executable, fn {_k, i} -> i.action_type == "briefing" end)
    questions = Enum.filter(executable, fn {_k, i} -> i.action_type == "question" end)

    sections =
      section("done", "Already done", Enum.map(briefings, &or_settled(&1, settled, :line))) ++
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
      _ when kind == :line -> briefing_line(entry)
      _ -> question(entry)
    end
  end

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
