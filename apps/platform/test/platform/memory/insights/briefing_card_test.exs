defmodule Platform.Memory.Insights.BriefingCardTest do
  @moduledoc """
  Task 01a13867 stage 3: the server-built briefing document. Agent prose is
  inert: it reaches the document only as a `text` node's value.
  """

  use ExUnit.Case, async: true

  alias Platform.Chat.CanvasDocument
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights.BriefingCard

  @date ~D[2026-10-18]
  @hostile "Ship it [x](http://evil) <a href=\"http://evil\">now</a>"

  defp insight(type, tier, body) do
    %Insight{id: Ecto.UUID.generate(), action_type: type, tier: tier, body: body}
  end

  defp entries(insights), do: Enum.map(insights, &{BriefingCard.node_key(&1), &1})

  defp nodes(%{"children" => children} = node), do: [node | Enum.flat_map(children, &nodes/1)]
  defp nodes(node), do: [node]

  defp all_nodes(document), do: nodes(document["root"])

  test "insight prose renders only in text nodes" do
    insights = [
      insight("briefing", "reversible", @hostile),
      insight("question", "reversible", @hostile),
      insight("question", "needs_call", @hostile)
    ]

    document = BriefingCard.document(@date, entries(insights), admin?: true)
    assert {:ok, _} = CanvasDocument.validate(document)

    hits =
      for node <- all_nodes(document), Jason.encode!(node["props"] || %{}) =~ "evil", do: node

    # Three bodies, three text nodes, each carrying the body verbatim.
    assert length(hits) == 3

    for node <- hits do
      assert node["type"] == "text"
      assert node["props"]["value"] == @hostile
    end

    # Nothing outside a text value names the body: no markdown, action_row,
    # form, id or meta.
    for node <- all_nodes(document), node["type"] != "text" do
      refute Jason.encode!(Map.delete(node, "children")) =~ "evil"
    end

    refute Jason.encode!(document["meta"]) =~ "evil"

    # Action values carry node keys, never insight ids.
    values =
      for %{"type" => "action_row", "props" => %{"actions" => actions}} <- all_nodes(document),
          action <- actions,
          do: action["value"]

    assert values != []

    for value <- values, insight <- insights do
      refute value =~ insight.id
    end

    refute Jason.encode!(document) =~ hd(insights).id
  end

  test "sections: done lines get actions, questions get a form, needs-call is admin-only" do
    [b, q, c] = [
      insight("briefing", "reversible", "Deploys moved to host-b."),
      insight("question", "reversible", "Who owns the bucket?"),
      insight("page_edit", "needs_call", "Delete the old runbook.")
    ]

    [{bk, _}, {qk, _}, {ck, _}] = all = entries([b, q, c])

    admin_doc = BriefingCard.document(@date, all, admin?: true)
    ids = Enum.map(all_nodes(admin_doc), & &1["id"])

    assert "section-done" in ids
    assert "section-questions" in ids
    assert "section-call" in ids
    assert ("insight_answer:" <> qk) in ids
    assert ("call-" <> ck) in ids

    assert %{"props" => %{"actions" => actions}} =
             CanvasDocument.get_node(admin_doc, "done-actions-" <> bk)

    assert Enum.map(actions, & &1["value"]) == ["insight_ok:" <> bk, "insight_flag:" <> bk]

    # The needs-call item never gets an action row or a form.
    refute CanvasDocument.get_node(admin_doc, "done-actions-" <> ck)
    refute CanvasDocument.get_node(admin_doc, "insight_answer:" <> ck)

    member_doc = BriefingCard.document(@date, all, admin?: false)
    member_ids = Enum.map(all_nodes(member_doc), & &1["id"])
    refute "section-call" in member_ids
    refute ("call-" <> ck) in member_ids
  end

  # Task 01a15587 stage 4: page edits and tasks the platform applied.
  defp applied(type, body, artefact_ref, action \\ %{}) do
    %Insight{
      id: Ecto.UUID.generate(),
      action_type: type,
      tier: "reversible",
      state: "done",
      body: body,
      action: action,
      artefact_ref: artefact_ref
    }
  end

  test "applied page_edit and task lines carry Revert, Delete task and Flag" do
    task_id = Ecto.UUID.generate()
    edit = applied("page_edit", "The deploy host moved.", "page:org/page/a.md@v2")
    filed = applied("task", "Rotate the deploy key.", "task:" <> task_id)
    [{ek, _}, {tk, _}] = all = entries([edit, filed])

    document = BriefingCard.document(@date, all)
    assert {:ok, _} = CanvasDocument.validate(document)

    done = CanvasDocument.get_node(document, "section-done")
    ids = Enum.map(done["children"], & &1["id"])

    assert ids == [
             "applied-" <> ek,
             "applied-actions-" <> ek,
             "applied-" <> tk,
             "applied-link-" <> tk,
             "applied-actions-" <> tk
           ]

    assert %{"type" => "text", "props" => %{"value" => "The deploy host moved."}} =
             CanvasDocument.get_node(document, "applied-" <> ek)

    actions = fn id ->
      %{"type" => "action_row", "props" => %{"actions" => actions}} =
        CanvasDocument.get_node(document, id)

      Enum.map(actions, &{&1["label"], &1["value"]})
    end

    assert actions.("applied-actions-" <> ek) ==
             [{"Revert", "insight_revert:" <> ek}, {"Flag", "insight_flag:" <> ek}]

    assert actions.("applied-actions-" <> tk) ==
             [{"Delete task", "insight_delete_task:" <> tk}, {"Flag", "insight_flag:" <> tk}]

    assert %{"type" => "markdown", "props" => %{"content" => content}} =
             CanvasDocument.get_node(document, "applied-link-" <> tk)

    assert content == "[Open task](/tasks/#{task_id})"

    # Action values carry node keys, never the insight ids.
    for {_label, value} <-
          actions.("applied-actions-" <> ek) ++ actions.("applied-actions-" <> tk),
        insight <- [edit, filed] do
      refute value =~ insight.id
    end
  end

  test "applied lines render agent prose only in text nodes" do
    task_id = Ecto.UUID.generate()

    insights = [
      applied("page_edit", @hostile, "page:org/page/a.md@v2"),
      applied("task", @hostile, "task:" <> task_id)
    ]

    document = BriefingCard.document(@date, entries(insights))
    assert {:ok, _} = CanvasDocument.validate(document)

    hits =
      for node <- all_nodes(document), Jason.encode!(node["props"] || %{}) =~ "evil", do: node

    assert length(hits) == 2
    assert Enum.all?(hits, &(&1["type"] == "text" and &1["props"]["value"] == @hostile))

    for node <- all_nodes(document), node["type"] != "text" do
      refute Jason.encode!(Map.delete(node, "children")) =~ "evil"
    end
  end

  test "the task link is built from artefact_ref, never the body or the action" do
    real = Ecto.UUID.generate()
    decoy = Ecto.UUID.generate()

    filed =
      applied(
        "task",
        "See [the task](/tasks/#{decoy}) and /tasks/#{decoy}.",
        "task:" <> real,
        %{"target" => decoy, "project_id" => decoy, "title" => "/tasks/#{decoy}"}
      )

    [{key, _}] = all = entries([filed])
    document = BriefingCard.document(@date, all)

    assert %{"props" => %{"content" => content}} =
             CanvasDocument.get_node(document, "applied-link-" <> key)

    assert content == "[Open task](/tasks/#{real})"

    for node <- all_nodes(document), node["type"] != "text" do
      refute Jason.encode!(Map.delete(node, "children")) =~ decoy
    end

    assert BriefingCard.filed_task_id(filed) == real

    # A ref that is not a canonical uuid renders no link at all; the
    # controls are still there.
    for bad <- [
          "task:#{real})[x](http://evil",
          "task:not-a-uuid",
          "task:",
          "page:org/page/a.md@v2",
          nil
        ] do
      broken = %{filed | artefact_ref: bad}
      [{k, _}] = one = entries([broken])
      doc = BriefingCard.document(@date, one)
      assert BriefingCard.filed_task_id(broken) == nil
      refute CanvasDocument.get_node(doc, "applied-link-" <> k)
      assert CanvasDocument.get_node(doc, "applied-actions-" <> k)
      refute Jason.encode!(doc) =~ "evil"
    end
  end

  test "node_key is stable and opaque" do
    id = Ecto.UUID.generate()
    assert BriefingCard.node_key(id) == BriefingCard.node_key(id)
    refute BriefingCard.node_key(id) =~ id
    refute BriefingCard.node_key(id) == BriefingCard.node_key(Ecto.UUID.generate())
  end
end
