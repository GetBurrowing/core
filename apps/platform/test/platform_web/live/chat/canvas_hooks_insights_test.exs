defmodule PlatformWeb.Chat.CanvasHooksInsightsTest do
  @moduledoc """
  Task 01a13867 stage 4: Looks right, Flag and Answer on the daily insight
  briefing canvas, driven through ChatLive's canvas events.

  Mutation probes named in the stage:
    (a) drop the recipient check in `insight_card_action/5`: "only the
        recipient can act on a briefing" goes red;
    (b) read the insight id from the action value instead of the briefing
        row: "a forged insight id in the action value is ignored" goes red.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Platform.InsightFixtures
  import Platform.TenancyFixtures

  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.CanvasDocument
  alias Platform.Memory.Briefing
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights
  alias Platform.Memory.Insights.BriefingCard
  alias Platform.Memory.Insights.Disseminator
  alias Platform.Memory.Insights.Purger
  alias Platform.Memory.InsightVerdict
  alias Platform.Org.WikiJournalEntry
  alias Platform.Repo

  defmodule PushRecorder do
    @moduledoc false
    def fan_out_to_humans(_participant_ids, _payload, _opts), do: :ok
  end

  setup do
    _root = acme_org_id()
    enable_dissemination!()
    dreaming_agent!()
    person = person!()

    line = insight!(addressee: person, body: "Deploys moved to host-b.")

    question =
      insight!(
        addressee: person,
        action_type: "question",
        body: "Who owns the staging host now?",
        evidence: "journal:org/journal/2026-10-17.md#L4"
      )

    assert {:ok, %{users: 1, items: 2}} = Disseminator.run(notifications_module: PushRecorder)
    briefing = Repo.one!(Briefing)
    canvas = Chat.get_canvas(briefing.canvas_id)

    %{person: person, bline: line, question: question, briefing: briefing, canvas: canvas}
  end

  defp mount!(user, space_id) do
    conn = build_conn() |> init_test_session(current_user_id: user.id)
    {:ok, view, _} = live(conn, "/chat/#{space_id}")
    view
  end

  defp click(view, canvas, value) do
    render_click(view, "canvas_action_click", %{
      "node-id" => "done-actions",
      "canvas-id" => canvas.id,
      "action" => value
    })
  end

  defp submit(view, canvas, node_id, values) do
    render_hook(view, "canvas_form_submit", %{
      "node-id" => node_id,
      "canvas-id" => canvas.id,
      "form" => values
    })
  end

  defp flash(view), do: :sys.get_state(view.pid).socket.assigns.flash

  defp live_doc(canvas) do
    {:ok, %{document: document}} = CanvasServer.describe(canvas.id)
    document
  end

  defp key(insight), do: BriefingCard.node_key(insight)

  defp add_to_space!(space_id, user) do
    {:ok, _} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })
  end

  test "only the recipient can act on a briefing", ctx do
    # Someone else in the same space can see the canvas (so `find/2` lets the
    # click through) but it is not their briefing.
    other = person!()
    add_to_space!(ctx.briefing.space_id, other)
    view = mount!(other, ctx.briefing.space_id)

    click(view, ctx.canvas, "insight_ok:" <> key(ctx.bline))
    assert flash(view)["error"] == "This briefing is not yours."
    assert %Insight{state: "open", acted_by: nil} = Repo.get!(Insight, ctx.bline.id)

    submit(view, ctx.canvas, "insight_answer:" <> key(ctx.question), %{"answer" => "Me."})
    assert flash(view)["error"] == "This briefing is not yours."
    assert Repo.aggregate(WikiJournalEntry, :count) == 0

    # Positive control: the recipient's own click on the same item works.
    mine = mount!(ctx.person, ctx.briefing.space_id)
    click(mine, ctx.canvas, "insight_ok:" <> key(ctx.bline))
    assert flash(mine)["info"] =~ "Marked as right"
    assert %Insight{state: "done"} = acted = Repo.get!(Insight, ctx.bline.id)
    assert acted.acted_by == ctx.person.id

    # The controls are gone, so a second click finds nothing to press.
    document = live_doc(ctx.canvas)
    refute CanvasDocument.get_node(document, "done-actions-" <> key(ctx.bline))
    assert CanvasDocument.get_node(document, "note-" <> key(ctx.bline))
  end

  test "a forged insight id in the action value is ignored", ctx do
    # A real, open insight on SOMEONE ELSE's briefing.
    stranger = person!()
    foreign = insight!(addressee: stranger, body: "Not for this canvas.")

    view = mount!(ctx.person, ctx.briefing.space_id)

    for forged <- [foreign.id, key(foreign)] do
      click(view, ctx.canvas, "insight_ok:" <> forged)
      assert flash(view)["error"] == "This item is not on this briefing."
    end

    assert %Insight{state: "open", acted_by: nil} = Repo.get!(Insight, foreign.id)
    assert %Insight{state: "open"} = Repo.get!(Insight, ctx.bline.id)

    # Positive control: the key the row holds resolves.
    click(view, ctx.canvas, "insight_ok:" <> key(ctx.bline))
    assert %Insight{state: "done"} = Repo.get!(Insight, ctx.bline.id)
  end

  test "flag without a reason is refused", ctx do
    view = mount!(ctx.person, ctx.briefing.space_id)
    k = key(ctx.bline)

    click(view, ctx.canvas, "insight_flag:" <> k)
    document = live_doc(ctx.canvas)
    assert %{"type" => "form"} = CanvasDocument.get_node(document, "insight_flag_reason:" <> k)
    refute CanvasDocument.get_node(document, "done-actions-" <> k)

    for blank <- ["", "   \n"] do
      submit(view, ctx.canvas, "insight_flag_reason:" <> k, %{"reason" => blank})
      assert flash(view)["error"] == "Give a reason to flag this."
    end

    submit(view, ctx.canvas, "insight_flag_reason:" <> k, %{})
    assert flash(view)["error"] == "Give a reason to flag this."

    assert Repo.aggregate(InsightVerdict, :count) == 0

    assert %{"props" => %{"value" => "Deploys moved to host-b."}} =
             CanvasDocument.get_node(live_doc(ctx.canvas), "done-" <> k)

    # Positive control: with a reason, the flag lands and the line is retracted.
    submit(view, ctx.canvas, "insight_flag_reason:" <> k, %{"reason" => "Still on host-a."})
    assert flash(view)["info"] =~ "Flagged"

    assert [%InsightVerdict{kind: "flagged", reason: "Still on host-a."}] =
             Repo.all(InsightVerdict)

    document = live_doc(ctx.canvas)

    assert %{"props" => %{"value" => "Retracted: Still on host-a."}} =
             CanvasDocument.get_node(document, "done-" <> k)

    refute CanvasDocument.get_node(document, "insight_flag_reason:" <> k)
  end

  test "flag stores a verdict that survives the TTL purge and appears in exemplars", ctx do
    view = mount!(ctx.person, ctx.briefing.space_id)
    k = key(ctx.bline)

    click(view, ctx.canvas, "insight_flag:" <> k)
    submit(view, ctx.canvas, "insight_flag_reason:" <> k, %{"reason" => "Wrong host."})

    [verdict] = Repo.all(InsightVerdict)
    assert verdict.actor_id == ctx.person.id
    assert verdict.block_hash == ctx.bline.block_hash

    # Past every row's TTL: the insights are purged, the verdict is not.
    assert {:ok, deleted} = Purger.sweep(now: DateTime.add(DateTime.utc_now(), 30, :day))
    assert deleted >= 2
    assert Repo.get(Insight, ctx.bline.id) == nil
    assert Repo.get(InsightVerdict, verdict.id)

    assert Enum.any?(
             Insights.exemplars(),
             &match?(
               %{kind: "flagged", reason: "Wrong host.", body: "Deploys moved to host-b."},
               &1
             )
           )

    assert Insights.render_exemplars() =~ "Wrong host."
  end

  test "acting on an expired insight from an old canvas says expired and executes nothing",
       ctx do
    view = mount!(ctx.person, ctx.briefing.space_id)

    # The line's row expired (not purged yet); the question's row is gone.
    Repo.update_all(from(i in Insight, where: i.id == ^ctx.bline.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
    )

    Repo.delete_all(from(i in Insight, where: i.id == ^ctx.question.id))

    click(view, ctx.canvas, "insight_ok:" <> key(ctx.bline))
    assert flash(view)["error"] == "This item expired. Nothing was changed."
    assert %Insight{state: "open", acted_by: nil} = Repo.get!(Insight, ctx.bline.id)

    click(view, ctx.canvas, "insight_flag:" <> key(ctx.bline))
    assert flash(view)["error"] == "This item expired. Nothing was changed."
    refute CanvasDocument.get_node(live_doc(ctx.canvas), "insight_flag_reason:" <> key(ctx.bline))

    submit(view, ctx.canvas, "insight_answer:" <> key(ctx.question), %{"answer" => "Alex."})
    assert flash(view)["error"] == "This item expired. Nothing was changed."

    assert Repo.aggregate(WikiJournalEntry, :count) == 0
    assert Repo.aggregate(InsightVerdict, :count) == 0
  end

  test "an answer from the canvas is journaled by the answerer and settles the question", ctx do
    view = mount!(ctx.person, ctx.briefing.space_id)
    k = key(ctx.question)

    submit(view, ctx.canvas, "insight_answer:" <> k, %{"answer" => "Alex does."})
    assert flash(view)["info"] =~ "Answer saved"

    [entry] = Repo.all(WikiJournalEntry)
    assert entry.authored_by == ctx.person.id
    assert entry.content =~ "source: briefing canvas #{ctx.canvas.id}"

    document = live_doc(ctx.canvas)
    refute CanvasDocument.get_node(document, "insight_answer:" <> k)

    assert %{"props" => %{"value" => "Answered: Alex does."}} =
             CanvasDocument.get_node(document, "note-" <> k)
  end

  test "a settled item stays settled when the day's canvas is re-rendered", ctx do
    view = mount!(ctx.person, ctx.briefing.space_id)
    click(view, ctx.canvas, "insight_ok:" <> key(ctx.bline))

    # A new item the same day re-renders the whole canvas.
    insight!(addressee: ctx.person, body: "A second line.")
    assert {:ok, %{items: 1}} = Disseminator.run(notifications_module: PushRecorder)

    document = live_doc(ctx.canvas)
    refute CanvasDocument.get_node(document, "done-actions-" <> key(ctx.bline))
    assert CanvasDocument.get_node(document, "note-" <> key(ctx.bline))
    assert CanvasDocument.get_node(document, "insight_answer:" <> key(ctx.question))

    # Stage 6: the Flag-only row a Looks-right line keeps survives the
    # re-render, and still opens the flag form.
    assert %{"type" => "action_row"} =
             CanvasDocument.get_node(document, "flag-actions-" <> key(ctx.bline))

    click(view, ctx.canvas, "insight_flag:" <> key(ctx.bline))

    assert %{"type" => "form"} =
             CanvasDocument.get_node(
               live_doc(ctx.canvas),
               "insight_flag_reason:" <> key(ctx.bline)
             )
  end

  # Stage 6, the behavioural gate's order: Looks right means "confirmed for
  # now", not final, so the line can still be flagged afterwards.
  test "Looks right, then Flag: a confirmed line can still be flagged with a reason", ctx do
    view = mount!(ctx.person, ctx.briefing.space_id)
    k = key(ctx.bline)

    click(view, ctx.canvas, "insight_ok:" <> k)
    assert flash(view)["info"] =~ "Marked as right"
    assert %Insight{state: "done"} = Repo.get!(Insight, ctx.bline.id)

    document = live_doc(ctx.canvas)
    refute CanvasDocument.get_node(document, "done-actions-" <> k)

    assert %{"props" => %{"value" => "Marked as right."}} =
             CanvasDocument.get_node(document, "note-" <> k)

    assert %{"props" => %{"actions" => [%{"label" => "Flag", "value" => "insight_flag:" <> ^k}]}} =
             CanvasDocument.get_node(document, "flag-actions-" <> k)

    # Flag opens the inline form in place of the Flag row.
    click(view, ctx.canvas, "insight_flag:" <> k)
    refute flash(view)["error"]
    document = live_doc(ctx.canvas)
    assert %{"type" => "form"} = CanvasDocument.get_node(document, "insight_flag_reason:" <> k)
    refute CanvasDocument.get_node(document, "flag-actions-" <> k)

    # An empty reason is refused and nothing is written.
    submit(view, ctx.canvas, "insight_flag_reason:" <> k, %{"reason" => ""})
    assert flash(view)["error"] == "Give a reason to flag this."
    assert Repo.aggregate(InsightVerdict, :count) == 0

    assert %{"props" => %{"value" => "Deploys moved to host-b."}} =
             CanvasDocument.get_node(live_doc(ctx.canvas), "done-" <> k)

    # With "wrong person" the line is retracted and a flagged verdict exists.
    submit(view, ctx.canvas, "insight_flag_reason:" <> k, %{"reason" => "wrong person"})
    assert flash(view)["info"] =~ "Flagged"

    assert [%InsightVerdict{kind: "flagged", reason: "wrong person", actor_id: actor_id}] =
             Repo.all(InsightVerdict)

    assert actor_id == ctx.person.id

    document = live_doc(ctx.canvas)

    assert %{"props" => %{"value" => "Retracted: wrong person"}} =
             CanvasDocument.get_node(document, "done-" <> k)

    for gone <- ["insight_flag_reason:", "flag-actions-", "note-", "done-actions-"] do
      refute CanvasDocument.get_node(document, gone <> k)
    end
  end
end
