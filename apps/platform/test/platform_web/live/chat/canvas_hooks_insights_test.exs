defmodule PlatformWeb.Chat.CanvasHooksInsightsTest do
  @moduledoc """
  Task 01a13867 stage 4: Looks right, Flag and Answer on the daily insight
  briefing canvas, driven through ChatLive's canvas events.

  Mutation probes named in the stage:
    (a) drop the recipient check in `insight_card_action/5`: "only the
        recipient can act on a briefing" goes red;
    (b) read the insight id from the action value instead of the briefing
        row: "a forged insight id in the action value is ignored" goes red.

  Task 01a15587 stage 4 (Revert, Delete task and Flag on page edits and
  tasks the platform applied unattended), probes:
    (a) drop the recipient check for the `insight_revert:` /
        `insight_delete_task:` clauses: "a non-recipient cannot revert or
        delete" goes red;
    (b) drop the `written_version` check in `Actions.revert/3`: "Revert
        refuses after a later edit" goes red;
    (c) drop the backlog-status check in `Actions.delete_filed_task/3`:
        "Delete task refuses once the task has left backlog" goes red.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Platform.InsightFixtures
  import Platform.RuntimeProfileFixtures
  import Platform.TenancyFixtures

  alias Platform.Access.Grants
  alias Platform.Access.Scope
  alias Platform.Accounts
  alias Platform.Agents.Agent
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
  alias Platform.Org.Wiki
  alias Platform.Org.WikiJournalEntry
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task

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

  describe "undo from the briefing (task 01a15587 stage 4)" do
    defp n, do: System.unique_integer([:positive])

    # `agent`'s brain runtime, owned by a root admin, carrying `modules`.
    defp brain_runtime!(agent, modules) do
      runtime = runtime!(root_admin!().id, modules, %{agent_id: agent.id})
      Repo.update_all(from(a in Agent, where: a.id == ^agent.id), set: [runtime_id: runtime.id])
      runtime
    end

    defp ingest!(content, author) do
      before = Repo.all(from(i in Insight, select: i.id))

      {:ok, 1} =
        Insights.ingest_from_journal(nil, "org/journal/2026-10-19.md", content, author.id)

      Repo.one!(from(i in Insight, where: i.id not in ^before))
    end

    # The platform applies one page edit (as the Historian) and files one
    # backlog task (as the dreaming agent), both for `ctx.person`, and lists
    # them on the person's briefing canvas under "Already done".
    defp applied!(ctx) do
      enable_dissemination!(%{
        dissemination_enabled: true,
        apply_page_edits: true,
        file_tasks: true
      })

      # The dreaming agent the setup's run delivered from, now with a brain
      # runtime that may file tasks.
      dreamer = Platform.Roles.assignee_for(Platform.Responsibilities.Handlers.Dreaming.key())
      brain_runtime!(dreamer, ["task"])

      historian =
        Repo.insert!(%Agent{slug: "historian-#{n()}", name: "Historian #{n()}", status: "active"})

      {:ok, _} = Platform.Roles.assign_role("historian", historian.id)
      brain_runtime!(historian, ["memory"])

      key = "org/page/undo-#{n()}.md"

      {:ok, _} =
        Wiki.upsert_page(key, %{content: "Deploys go to host-a.", updated_by: ctx.person.id})

      edit =
        ingest!(
          ~s(<synthesis-insight action="page_edit" confidence="high" target="#{key}" source="page:#{key}">
          The deploy host moved, ref #{n()}.
          <old>go to host-a</old><new>go to host-b</new>
          </synthesis-insight>),
          dreamer
        )

      {:ok, project} = Tasks.create_project(%{name: "undo-#{n()}", org_id: acme_org_id()})

      filed =
        ingest!(
          ~s(<synthesis-insight action="task" confidence="high" target="#{project.id}" addressee="#{ctx.person.id}">
          Rotate the deploy key on the build box, ref #{n()}.
          </synthesis-insight>),
          dreamer
        )

      assert edit.addressee_user_id == ctx.person.id
      assert {:ok, %{items: 2}} = Disseminator.run(notifications_module: PushRecorder)

      edit = Repo.get!(Insight, edit.id)
      filed = Repo.get!(Insight, filed.id)
      assert %Insight{state: "done", pre_image: %{"unattended" => true}} = edit
      assert %Insight{state: "done", artefact_ref: "task:" <> task_id} = filed
      assert Wiki.get_page(key).content == "Deploys go to host-b."

      %{
        key: key,
        edit: edit,
        filed: filed,
        task: Repo.get!(Task, task_id),
        project: project,
        historian: historian,
        dreamer: dreamer
      }
    end

    defp verdicts, do: Repo.all(InsightVerdict)

    test "the briefing lists the applied edit and the filed task with their controls", ctx do
      a = applied!(ctx)
      document = live_doc(ctx.canvas)
      ek = key(a.edit)
      tk = key(a.filed)

      assert %{"props" => %{"actions" => edit_actions}} =
               CanvasDocument.get_node(document, "applied-actions-" <> ek)

      assert Enum.map(edit_actions, &{&1["label"], &1["value"]}) ==
               [{"Revert", "insight_revert:" <> ek}, {"Flag", "insight_flag:" <> ek}]

      assert %{"props" => %{"actions" => task_actions}} =
               CanvasDocument.get_node(document, "applied-actions-" <> tk)

      assert Enum.map(task_actions, &{&1["label"], &1["value"]}) ==
               [{"Delete task", "insight_delete_task:" <> tk}, {"Flag", "insight_flag:" <> tk}]

      assert %{"type" => "markdown", "props" => %{"content" => link}} =
               CanvasDocument.get_node(document, "applied-link-" <> tk)

      assert link == "[Open task](/tasks/#{a.task.id})"
    end

    test "Revert from the briefing restores the prior page content", ctx do
      a = applied!(ctx)
      written = Wiki.get_page(a.key)
      view = mount!(ctx.person, ctx.briefing.space_id)

      click(view, ctx.canvas, "insight_revert:" <> key(a.edit))
      assert flash(view)["info"] =~ "Reverted"

      page = Wiki.get_page(a.key)
      assert page.content == "Deploys go to host-a."
      assert page.content == a.edit.pre_image["content"]
      assert page.version == written.version + 1
      # The write is the acting identity's; the clicker is the verdict's actor.
      assert page.updated_by == a.historian.id

      undone = Repo.get!(Insight, a.edit.id)
      refute undone.state == "done"
      assert undone.state == "dismissed"
      assert undone.pre_image == nil

      assert [
               %InsightVerdict{
                 kind: "rejected",
                 reason: "reverted from briefing",
                 actor_id: actor_id,
                 block_hash: block_hash
               }
             ] = verdicts()

      assert actor_id == ctx.person.id
      assert block_hash == a.edit.block_hash

      document = live_doc(ctx.canvas)
      k = key(a.edit)
      refute CanvasDocument.get_node(document, "applied-actions-" <> k)

      assert %{"props" => %{"value" => "Reverted."}} =
               CanvasDocument.get_node(document, "note-" <> k)

      # A second click finds nothing to revert and writes nothing.
      click(view, ctx.canvas, "insight_revert:" <> k)
      assert Wiki.get_page(a.key).version == written.version + 1
      assert length(verdicts()) == 1
    end

    test "Delete task from the briefing soft-deletes the filed task", ctx do
      a = applied!(ctx)
      view = mount!(ctx.person, ctx.briefing.space_id)
      assert Enum.map(Tasks.list_tasks_by_project(a.project.id), & &1.id) == [a.task.id]

      click(view, ctx.canvas, "insight_delete_task:" <> key(a.filed))
      assert flash(view)["info"] == "Task deleted."

      assert %Task{deleted_at: %DateTime{}} = Repo.get!(Task, a.task.id)
      assert Tasks.list_tasks_by_project(a.project.id) == []
      assert %Insight{state: "dismissed"} = Repo.get!(Insight, a.filed.id)

      assert [%InsightVerdict{kind: "rejected", reason: "task deleted from briefing"} = v] =
               verdicts()

      assert v.actor_id == ctx.person.id

      document = live_doc(ctx.canvas)
      k = key(a.filed)

      for gone <- ["applied-actions-", "applied-link-"] do
        refute CanvasDocument.get_node(document, gone <> k)
      end

      assert %{"props" => %{"value" => "Task deleted."}} =
               CanvasDocument.get_node(document, "note-" <> k)

      # The edit on the same canvas is untouched.
      assert Wiki.get_page(a.key).content == "Deploys go to host-b."
      assert CanvasDocument.get_node(document, "applied-actions-" <> key(a.edit))
    end

    test "a non-recipient cannot revert or delete", ctx do
      a = applied!(ctx)
      page_before = Wiki.get_page(a.key)
      other = person!()
      add_to_space!(ctx.briefing.space_id, other)
      view = mount!(other, ctx.briefing.space_id)

      click(view, ctx.canvas, "insight_revert:" <> key(a.edit))
      assert flash(view)["error"] == "This briefing is not yours."

      click(view, ctx.canvas, "insight_delete_task:" <> key(a.filed))
      assert flash(view)["error"] == "This briefing is not yours."

      page = Wiki.get_page(a.key)
      assert {page.content, page.version} == {page_before.content, page_before.version}
      assert %Task{deleted_at: nil} = Repo.get!(Task, a.task.id)
      assert %Insight{state: "done"} = Repo.get!(Insight, a.edit.id)
      assert %Insight{state: "done"} = Repo.get!(Insight, a.filed.id)
      assert verdicts() == []

      # Below the canvas too: the acting identity undoes only for a
      # recipient. A non-recipient without memory.write is refused by the
      # context, and the task delete is recipient-only.
      {:ok, _} =
        Grants.deny(%{principal: other, permission: "memory.write", resource: {:memory, a.key}})

      other_scope = Scope.for_user(Accounts.get_user(other.id))
      assert {:error, :unauthorized} = Insights.revert_from_briefing(a.edit.id, other_scope)
      assert {:error, :unauthorized} = Insights.delete_task_from_briefing(a.filed.id, other_scope)
      assert Wiki.get_page(a.key).version == page_before.version
      assert %Task{deleted_at: nil} = Repo.get!(Task, a.task.id)
      assert verdicts() == []

      # Positive control: the recipient's own clicks on the same items work.
      mine = mount!(ctx.person, ctx.briefing.space_id)
      click(mine, ctx.canvas, "insight_revert:" <> key(a.edit))
      assert flash(mine)["info"] =~ "Reverted"
      click(mine, ctx.canvas, "insight_delete_task:" <> key(a.filed))
      assert flash(mine)["info"] == "Task deleted."
      assert Wiki.get_page(a.key).content == "Deploys go to host-a."
      assert %Task{deleted_at: %DateTime{}} = Repo.get!(Task, a.task.id)
    end

    test "Delete task refuses once the task has left backlog", ctx do
      a = applied!(ctx)
      view = mount!(ctx.person, ctx.briefing.space_id)

      # Somebody picked the task up. `planning` is a deletable status, so
      # only the backlog check stands between this click and a delete.
      Repo.update_all(from(t in Task, where: t.id == ^a.task.id), set: [status: "planning"])

      click(view, ctx.canvas, "insight_delete_task:" <> key(a.filed))
      assert flash(view)["error"] =~ "picked up"

      assert %Task{deleted_at: nil, status: "planning"} = Repo.get!(Task, a.task.id)
      assert %Insight{state: "done"} = Repo.get!(Insight, a.filed.id)
      assert verdicts() == []

      assert CanvasDocument.get_node(live_doc(ctx.canvas), "applied-actions-" <> key(a.filed))

      # Control: back in backlog, the same click deletes it.
      Repo.update_all(from(t in Task, where: t.id == ^a.task.id), set: [status: "backlog"])
      click(view, ctx.canvas, "insight_delete_task:" <> key(a.filed))
      assert %Task{deleted_at: %DateTime{}} = Repo.get!(Task, a.task.id)
    end

    test "Revert refuses after a later edit", ctx do
      a = applied!(ctx)
      view = mount!(ctx.person, ctx.briefing.space_id)
      written = Wiki.get_page(a.key)

      {:ok, later} =
        Wiki.upsert_page(
          a.key,
          %{content: "Deploys go to host-c.", updated_by: ctx.person.id},
          expected_version: written.version
        )

      click(view, ctx.canvas, "insight_revert:" <> key(a.edit))
      assert flash(view)["error"] =~ "page changed"

      page = Wiki.get_page(a.key)
      assert {page.content, page.version} == {"Deploys go to host-c.", later.version}
      assert %Insight{state: "done"} = Repo.get!(Insight, a.edit.id)
      assert verdicts() == []
      assert CanvasDocument.get_node(live_doc(ctx.canvas), "applied-actions-" <> key(a.edit))
    end

    test "Flag on an auto-applied page_edit reverts it for a recipient without memory.write",
         ctx do
      a = applied!(ctx)

      {:ok, _} =
        Grants.deny(%{
          principal: ctx.person,
          permission: "memory.write",
          resource: {:memory, a.key}
        })

      person_scope = Scope.for_user(Accounts.get_user(ctx.person.id))
      refute Platform.Access.can?(person_scope, "memory.write", {:memory, a.key})

      view = mount!(ctx.person, ctx.briefing.space_id)
      k = key(a.edit)

      click(view, ctx.canvas, "insight_flag:" <> k)

      assert %{"type" => "form"} =
               CanvasDocument.get_node(live_doc(ctx.canvas), "insight_flag_reason:" <> k)

      submit(view, ctx.canvas, "insight_flag_reason:" <> k, %{"reason" => "Still on host-a."})
      assert flash(view)["info"] =~ "Flagged"

      page = Wiki.get_page(a.key)
      assert page.content == "Deploys go to host-a."
      assert page.updated_by == a.historian.id

      assert [%InsightVerdict{kind: "flagged", reason: "Still on host-a.", actor_id: actor_id}] =
               verdicts()

      assert actor_id == ctx.person.id
      assert %Insight{state: "dismissed"} = Repo.get!(Insight, a.edit.id)

      assert %{"props" => %{"value" => "Retracted: Still on host-a."}} =
               CanvasDocument.get_node(live_doc(ctx.canvas), "applied-" <> k)
    end

    test "Flag on an auto-filed task soft-deletes it while it is in backlog", ctx do
      a = applied!(ctx)
      view = mount!(ctx.person, ctx.briefing.space_id)
      k = key(a.filed)

      click(view, ctx.canvas, "insight_flag:" <> k)
      submit(view, ctx.canvas, "insight_flag_reason:" <> k, %{"reason" => "Not a real task."})
      assert flash(view)["info"] =~ "Flagged"

      assert %Task{deleted_at: %DateTime{}} = Repo.get!(Task, a.task.id)
      assert [%InsightVerdict{kind: "flagged", actor_id: actor_id}] = verdicts()
      assert actor_id == ctx.person.id

      document = live_doc(ctx.canvas)
      refute CanvasDocument.get_node(document, "applied-link-" <> k)

      assert %{"props" => %{"value" => "Retracted: Not a real task."}} =
               CanvasDocument.get_node(document, "applied-" <> k)
    end
  end
end
