defmodule Platform.Memory.Insights.DisseminatorTest do
  @moduledoc """
  Task 01a13867 stage 3: the daily delivery run.

  Mutation probe (c): dropping the `(user_id, digest_date)` lookup turns
  "one digest per person per day" red.

  Task 01a15587 stage 3 (unattended page edits and tasks): probe (c),
  rendering an insight whose apply returned `{:error, _}`, turns "a refused
  apply leaves the insight open and off the briefing" red; probe (b),
  dropping the `open/1` re-read in `Actions.apply_unattended/2`, is aimed at
  "running twice applies once".
  """

  use Platform.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Platform.InsightFixtures
  import Platform.RuntimeProfileFixtures
  import Platform.TenancyFixtures

  alias Platform.Chat.Canvas
  alias Platform.Chat.CanvasDocument
  alias Platform.Agents.Agent
  alias Platform.Chat.Participant
  alias Platform.Memory.Briefing
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights
  alias Platform.Memory.Insights.BriefingCard
  alias Platform.Memory.Insights.Disseminator
  alias Platform.Org.Wiki
  alias Platform.Repo
  alias Platform.Tasks.Task

  defmodule PushRecorder do
    @moduledoc false
    def fan_out_to_humans(participant_ids, payload, _opts) do
      send(self(), {:push, participant_ids, payload})
      :ok
    end
  end

  # 12:00 UTC on 2026-10-18 is 07:00 America/Chicago (CDT).
  @now ~U[2026-10-18 12:00:00.000000Z]

  defp run!(opts \\ []) do
    Disseminator.run(Keyword.merge([now: @now, notifications_module: PushRecorder], opts))
  end

  defp canvases_in(space_id),
    do: Repo.all(from(c in Canvas, where: c.space_id == ^space_id and is_nil(c.deleted_at)))

  defp dm_canvases(user_id) do
    Repo.all(
      from(c in Canvas,
        join: p in Participant,
        on: p.space_id == c.space_id,
        where: p.participant_type == "user" and p.participant_id == ^user_id,
        select: c
      )
    )
  end

  defp text_values(document) do
    walk = fn
      %{"children" => children} = node, walk -> [node | Enum.flat_map(children, &walk.(&1, walk))]
      node, _walk -> [node]
    end

    for %{"type" => "text", "props" => %{"value" => v}} <- walk.(document["root"], walk), do: v
  end

  test "run/1 delivers nothing while dissemination is off" do
    dreaming_agent!()
    person = person!()
    insight = insight!(addressee: person)

    assert {:ok, %{users: 0, items: 0}} = run!()

    assert dm_canvases(person.id) == []
    assert Repo.aggregate(Briefing, :count) == 0
    assert %Insight{delivered_at: nil, state: "open"} = Repo.get!(Insight, insight.id)
    refute_received {:push, _, _}

    # Positive control: the same fixture with dissemination on delivers.
    enable_dissemination!()
    assert {:ok, %{users: 1, items: 1}} = run!()
    assert [_canvas] = dm_canvases(person.id)
  end

  test "one digest per person per day" do
    enable_dissemination!()
    agent = dreaming_agent!()
    person = person!()
    first = insight!(addressee: person, body: "First line.")

    assert {:ok, %{users: 1, items: 1}} = run!()

    assert [%Briefing{} = briefing] = Repo.all(Briefing)
    assert briefing.user_id == person.id
    assert briefing.digest_date == ~D[2026-10-18]
    assert briefing.items == %{BriefingCard.node_key(first) => first.id}

    assert [canvas] = canvases_in(briefing.space_id)
    assert canvas.id == briefing.canvas_id
    assert text_values(canvas.document) |> Enum.count(&(&1 == "First line.")) == 1

    # The canvas is posted by the dreaming agent into the person's DM.
    assert Repo.exists?(
             from(p in Participant,
               where:
                 p.space_id == ^briefing.space_id and p.participant_type == "agent" and
                   p.participant_id == ^agent.id
             )
           )

    assert %Insight{delivered_at: %DateTime{}} = Repo.get!(Insight, first.id)

    user_p =
      Repo.get_by!(Participant,
        space_id: briefing.space_id,
        participant_type: "user",
        participant_id: person.id
      )

    assert_received {:push, [participant_id], %{title: "Your briefing"}}
    assert participant_id == user_p.id

    # Same day, nothing new: no canvas, no row, no push.
    assert {:ok, %{users: 0, items: 0}} = run!(now: DateTime.add(@now, 3600))
    assert Repo.aggregate(Briefing, :count) == 1
    assert length(canvases_in(briefing.space_id)) == 1
    refute_received {:push, _, _}

    # Same day, a new insight: appended to the SAME canvas, no duplicate line.
    second = insight!(addressee: person, body: "Second line.")
    assert {:ok, %{users: 1, items: 1}} = run!(now: DateTime.add(@now, 7200))

    assert [%Briefing{} = again] = Repo.all(Briefing)
    assert again.id == briefing.id
    assert again.canvas_id == briefing.canvas_id
    assert map_size(again.items) == 2
    assert again.items[BriefingCard.node_key(second)] == second.id

    assert [updated] = canvases_in(briefing.space_id)
    values = text_values(updated.document)
    assert Enum.count(values, &(&1 == "First line.")) == 1
    assert Enum.count(values, &(&1 == "Second line.")) == 1
    assert {:ok, _} = CanvasDocument.validate(updated.document)
    assert_received {:push, [_], _}

    # The next day gets its own canvas.
    insight!(addressee: person, body: "Tomorrow's line.")
    assert {:ok, %{users: 1}} = run!(now: DateTime.add(@now, 86_400))
    assert Repo.aggregate(Briefing, :count) == 2
    assert length(canvases_in(briefing.space_id)) == 2
  end

  test "with no agent holding memory.dreaming nothing is delivered" do
    enable_dissemination!()
    person = person!()
    insight = insight!(addressee: person)

    assert {:ok, %{users: 0, items: 0, reason: :no_agent}} = run!()
    assert dm_canvases(person.id) == []
    assert %Insight{delivered_at: nil} = Repo.get!(Insight, insight.id)
  end

  test "a needs_call insight reaches the admin's briefing as a link only" do
    enable_dissemination!()
    dreaming_agent!()
    admin = person!("admin")
    guest = person!("member", external: true)
    insight!(addressee: guest, action_type: "question", body: "Can you renew the cert?")

    assert {:ok, %{items: items}} = run!()
    assert items >= 1

    assert dm_canvases(guest.id) == []
    assert [canvas] = dm_canvases(admin.id)
    assert CanvasDocument.get_node(canvas.document, "section-call")
    refute CanvasDocument.get_node(canvas.document, "section-questions")
    assert "Can you renew the cert?" in text_values(canvas.document)
  end

  describe "unattended page edits and tasks (task 01a15587 stage 3)" do
    @journal "org/journal/2026-10-18.md"

    defp n, do: System.unique_integer([:positive])

    # `agent`'s brain runtime, owned by a root admin, carrying `modules`.
    defp brain_runtime!(agent, modules) do
      runtime = runtime!(root_admin!().id, modules, %{agent_id: agent.id})
      Repo.update_all(from(a in Agent, where: a.id == ^agent.id), set: [runtime_id: runtime.id])
      runtime
    end

    defp historian! do
      agent =
        Repo.insert!(%Agent{slug: "historian-#{n()}", name: "Historian #{n()}", status: "active"})

      {:ok, _} = Platform.Roles.assign_role("historian", agent.id)
      brain_runtime!(agent, ["memory"])
      agent
    end

    # A dreaming agent whose brain runtime may file tasks.
    defp dreamer! do
      dreamer = dreaming_agent!()
      brain_runtime!(dreamer, ["task"])
      dreamer
    end

    defp ingest!(content, author) do
      before = Repo.all(from(i in Insight, select: i.id))
      {:ok, 1} = Insights.ingest_from_journal(nil, @journal, content, author.id)
      Repo.one!(from(i in Insight, where: i.id not in ^before))
    end

    # An org page last edited by `editor` (so routing addresses them) and a
    # page_edit insight on it authored by `author`.
    defp page_edit!(editor, author) do
      key = "org/page/disseminate-#{n()}.md"
      {:ok, _} = Wiki.upsert_page(key, %{content: "Deploys go to host-a.", updated_by: editor.id})

      insight =
        ingest!(
          ~s(<synthesis-insight action="page_edit" confidence="high" target="#{key}" source="page:#{key}">
          The deploy host moved, ref #{n()}.
          <old>go to host-a</old><new>go to host-b</new>
          </synthesis-insight>),
          author
        )

      assert insight.addressee_user_id == editor.id
      assert insight.tier == "reversible"
      {key, insight}
    end

    defp task_insight!(addressee, author) do
      {:ok, project} = Platform.Tasks.create_project(%{name: "dis-#{n()}", org_id: acme_org_id()})

      insight =
        ingest!(
          ~s(<synthesis-insight action="task" confidence="high" target="#{project.id}" addressee="#{addressee.id}">
          Rotate the deploy key on the build box, ref #{n()}.
          </synthesis-insight>),
          author
        )

      assert insight.tier == "reversible"
      {project, insight}
    end

    defp briefing_document(person) do
      [%Briefing{canvas_id: canvas_id}] =
        Repo.all(from(b in Briefing, where: b.user_id == ^person.id))

      Repo.get!(Canvas, canvas_id).document
    end

    defp done_values(document) do
      document |> CanvasDocument.get_node("section-done") |> then(&text_values(%{"root" => &1}))
    end

    defp project_tasks(project),
      do: Repo.all(from(t in Task, where: t.project_id == ^project.id))

    test "run/1 applies a page_edit as the Historian and lists it under Already done" do
      enable_dissemination!(%{dissemination_enabled: true, apply_page_edits: true})
      dreamer = dreamer!()
      historian = historian!()
      person = person!()
      {key, insight} = page_edit!(person, dreamer)
      version = Wiki.get_page(key).version

      assert {:ok, %{users: 1, items: 1}} = run!()

      page = Wiki.get_page(key)
      assert page.content == "Deploys go to host-b."
      assert page.version == version + 1
      assert page.updated_by == historian.id

      acted = Repo.get!(Insight, insight.id)
      assert acted.state == "done"
      assert acted.acted_by == historian.id
      assert %DateTime{} = acted.delivered_at
      assert acted.pre_image["unattended"] == true
      assert acted.pre_image["acting_agent_id"] == historian.id
      assert acted.pre_image["content"] == "Deploys go to host-a."

      document = briefing_document(person)
      assert insight.body in done_values(document)
      assert CanvasDocument.get_node(document, "applied-" <> BriefingCard.node_key(insight))
      assert {:ok, _} = CanvasDocument.validate(document)
    end

    test "run/1 files a backlog task and lists it under Already done" do
      enable_dissemination!(%{dissemination_enabled: true, file_tasks: true})
      dreamer = dreamer!()
      person = person!()
      {project, insight} = task_insight!(person, dreamer)

      assert {:ok, %{users: 1, items: 1}} = run!()

      assert [task] = project_tasks(project)
      assert task.status == "backlog"
      assert task.assignee_id == nil
      assert task.sponsor_user_id == person.id
      assert task.metadata["insight_id"] == insight.id

      acted = Repo.get!(Insight, insight.id)
      assert acted.state == "done"
      assert acted.artefact_ref == "task:" <> task.id
      assert acted.acted_by == dreamer.id

      assert insight.body in done_values(briefing_document(person))
    end

    test "a refused apply leaves the insight open and off the briefing" do
      enable_dissemination!(%{dissemination_enabled: true, apply_page_edits: true})
      dreamer = dreamer!()
      # No Historian is assigned, so the page_edit apply is refused.
      person = person!()
      {key, insight} = page_edit!(person, dreamer)
      before = Wiki.get_page(key)
      other = insight!(addressee: person, body: "The rest of the briefing.")

      log = capture_log(fn -> assert {:ok, %{users: 1, items: 1}} = run!() end)

      assert log =~ insight.id
      assert log =~ "no_historian"

      after_page = Wiki.get_page(key)
      assert {after_page.content, after_page.version} == {before.content, before.version}

      assert %Insight{state: "open", delivered_at: nil, acted_by: nil} =
               Repo.get!(Insight, insight.id)

      # The rest of the person's briefing still went out.
      document = briefing_document(person)
      values = text_values(document)
      assert other.body in values
      refute insight.body in values
      refute CanvasDocument.get_node(document, "applied-" <> BriefingCard.node_key(insight))

      # Control: once a Historian exists, the next run applies and lists it.
      historian!()
      assert {:ok, %{items: 1}} = run!(now: DateTime.add(@now, 3600))
      assert Wiki.get_page(key).content == "Deploys go to host-b."
      assert insight.body in done_values(briefing_document(person))
    end

    test "running twice applies once" do
      enable_dissemination!(%{
        dissemination_enabled: true,
        apply_page_edits: true,
        file_tasks: true
      })

      dreamer = dreamer!()
      historian!()
      person = person!()
      {key, edit} = page_edit!(person, dreamer)
      {project, task} = task_insight!(person, dreamer)
      version = Wiki.get_page(key).version

      assert {:ok, %{users: 1, items: 2}} = run!()
      assert {:ok, %{users: 0, items: 0}} = run!(now: DateTime.add(@now, 3600))

      assert Wiki.get_page(key).version == version + 1
      assert length(project_tasks(project)) == 1

      values = text_values(briefing_document(person))
      assert Enum.count(values, &(&1 == edit.body)) == 1
      assert Enum.count(values, &(&1 == task.body)) == 1
    end
  end

  test "the next fire is 07:00 America/Chicago" do
    ms = Disseminator.ms_until_next_fire(~U[2026-10-18 11:00:00Z])
    assert ms == 60 * 60 * 1000
    assert Disseminator.local_date(~U[2026-10-19 03:00:00Z]) == ~D[2026-10-18]
  end
end
