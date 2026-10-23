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

  Task 01a15ee1 stage 1 (the briefing is ONE Inbox row per person per day;
  no DM, no canvas): probe, putting `Chat.find_or_create_dm(user_id,
  "agent", agent.id)` back into `deliver/6`, turns "no DM space or canvas is
  created" red.

  Task 01a15ee1 stage 5: probe, dropping the `tier: "reversible"` guard in
  `apply_unattended/4` (apply every selected page_edit / task), turns "a
  needs_call page_edit routed to a root admin is listed as a call, not
  applied" red.
  """

  use Platform.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Platform.InsightFixtures
  import Platform.RuntimeProfileFixtures
  import Platform.TenancyFixtures

  alias Platform.Agents.Agent
  alias Platform.Chat.Canvas
  alias Platform.Chat.Participant
  alias Platform.Chat.Space
  alias Platform.Inbox
  alias Platform.Inbox.Item
  alias Platform.Memory.Briefing
  alias Platform.Memory.Insight
  alias Platform.Memory.Insights
  alias Platform.Memory.Insights.BriefingCard
  alias Platform.Memory.Insights.Briefings
  alias Platform.Memory.Insights.Disseminator
  alias Platform.Org.Wiki
  alias Platform.Repo
  alias Platform.Tasks.Task

  defmodule PushRecorder do
    @moduledoc false
    def fan_out_to_user(user_id, payload) do
      send(self(), {:push, user_id, payload})
      :ok
    end
  end

  # 12:00 UTC on 2026-10-18 is 07:00 America/Chicago (CDT).
  @now ~U[2026-10-18 12:00:00.000000Z]

  defp run!(opts \\ []) do
    Disseminator.run(Keyword.merge([now: @now, notifications_module: PushRecorder], opts))
  end

  # Every chat space `user_id` participates in, and every canvas in one.
  defp dm_spaces(user_id) do
    Repo.all(
      from(p in Participant,
        where: p.participant_type == "user" and p.participant_id == ^user_id,
        select: p.space_id
      )
    )
  end

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

  defp briefing_rows(user_id), do: Inbox.list_unread_for_user(user_id, kind: "briefing")

  defp all_briefing_rows(user_id),
    do: Repo.all(from(i in Item, where: i.user_id == ^user_id and i.kind == "briefing"))

  defp briefing_of(user_id), do: Repo.one!(from(b in Briefing, where: b.user_id == ^user_id))

  test "run/1 delivers nothing while dissemination is off" do
    dreaming_agent!()
    person = person!()
    insight = insight!(addressee: person)

    assert {:ok, %{users: 0, items: 0}} = run!()

    assert Repo.aggregate(Briefing, :count) == 0
    assert briefing_rows(person.id) == []
    assert %Insight{delivered_at: nil, state: "open"} = Repo.get!(Insight, insight.id)
    refute_received {:push, _, _}

    # Positive control: the same fixture with dissemination on delivers.
    enable_dissemination!()
    assert {:ok, %{users: 1, items: 1}} = run!()
    assert [_row] = briefing_rows(person.id)
  end

  test "one run writes one briefing row with no canvas and one Inbox briefing row" do
    enable_dissemination!()
    dreaming_agent!()
    person = person!()
    first = insight!(addressee: person, body: "First line.")

    assert {:ok, %{users: 1, items: 1}} = run!()

    assert [%Briefing{} = briefing] = Repo.all(Briefing)
    assert briefing.user_id == person.id
    assert briefing.digest_date == ~D[2026-10-18]
    assert briefing.items == %{BriefingCard.node_key(first) => first.id}
    assert briefing.canvas_id == nil
    assert briefing.space_id == nil
    assert briefing.receipts == %{}

    assert [%Item{} = row] = briefing_rows(person.id)
    assert row.kind == "briefing"
    assert row.source_type == "briefing"
    assert row.source_id == briefing.id
    assert row.title == "Today's briefing"
    assert row.body == "1 item · FYI only"
    assert row.url == "/inbox/briefing/2026-10-18"
    assert row.read_at == nil

    assert %Insight{delivered_at: %DateTime{}} = Repo.get!(Insight, first.id)

    # ONE push, to the person, pointing at the Inbox route.
    assert_received {:push, user_id, %{kind: "insight_briefing", title: "Your briefing"} = push}
    assert user_id == person.id
    assert push.url == "/inbox/briefing/2026-10-18"
    refute_received {:push, _, _}
  end

  test "no DM space or canvas is created" do
    enable_dissemination!()
    agent = dreaming_agent!()
    person = person!()
    insight!(addressee: person, body: "First line.")
    spaces_before = Repo.aggregate(Space, :count)
    canvases_before = Repo.aggregate(Canvas, :count)

    assert {:ok, %{users: 1, items: 1}} = run!()
    assert [_row] = briefing_rows(person.id)

    # Neither the person nor the dreaming agent joined any space, and no
    # space or canvas row exists that did not exist before the run.
    assert dm_spaces(person.id) == []
    assert dm_canvases(person.id) == []

    refute Repo.exists?(
             from(p in Participant,
               where: p.participant_type == "agent" and p.participant_id == ^agent.id
             )
           )

    assert Repo.aggregate(Space, :count) == spaces_before
    assert Repo.aggregate(Canvas, :count) == canvases_before

    # deliver_now/3 (a person asked) takes the same path.
    extra = insight!(addressee: person, action_type: "question", body: "Who owns it?")
    assert {:ok, 1} = Disseminator.deliver_now(person.id, [extra], now: @now)
    assert dm_spaces(person.id) == []
    assert Repo.aggregate(Canvas, :count) == canvases_before
  end

  test "a second same-day run updates the SAME Inbox row, re-marks it unread, and does not push" do
    enable_dissemination!()
    dreaming_agent!()
    person = person!()
    insight!(addressee: person, body: "First line.")

    assert {:ok, %{users: 1, items: 1}} = run!()
    assert [%Item{} = row] = briefing_rows(person.id)
    assert_received {:push, _, _}

    # The person opens it: read, still listed.
    assert {:ok, %Item{read_at: %DateTime{}}} = Inbox.open_item(row.id, person.id)

    # Same day, nothing new: nothing written, no push, the row stays read.
    assert {:ok, %{users: 0, items: 0}} = run!(now: DateTime.add(@now, 3600))
    assert [%Item{read_at: %DateTime{}}] = briefing_rows(person.id)
    refute_received {:push, _, _}

    # Same day, new insights (one of them a question): the SAME row, unread
    # again, with a fresh subtitle; one briefing row; no second push.
    second = insight!(addressee: person, body: "Second line.")
    question = insight!(addressee: person, action_type: "question", body: "Who owns it?")
    assert {:ok, %{users: 1, items: 2}} = run!(now: DateTime.add(@now, 7200))

    assert [%Item{} = again] = all_briefing_rows(person.id)
    assert again.id == row.id
    assert again.read_at == nil
    assert again.dismissed_at == nil
    assert again.body == "3 items · 1 needs your call"
    refute_received {:push, _, _}

    assert [%Briefing{} = briefing] = Repo.all(Briefing)
    assert map_size(briefing.items) == 3
    assert briefing.items[BriefingCard.node_key(second)] == second.id
    assert briefing.items[BriefingCard.node_key(question)] == question.id

    # A dismissed row comes back (the same row) when new items arrive.
    assert {:ok, _} = Inbox.mark_dismissed(row.id, person.id)
    insight!(addressee: person, body: "Third line.")
    assert {:ok, %{items: 1}} = run!(now: DateTime.add(@now, 9000))
    assert [%Item{id: id, dismissed_at: nil, read_at: nil}] = all_briefing_rows(person.id)
    assert id == row.id
    refute_received {:push, _, _}

    # The next day gets its own briefing, its own row and its own push.
    insight!(addressee: person, body: "Tomorrow's line.")
    assert {:ok, %{users: 1}} = run!(now: DateTime.add(@now, 86_400))
    assert Repo.aggregate(Briefing, :count) == 2
    assert length(all_briefing_rows(person.id)) == 2
    assert_received {:push, _, %{url: "/inbox/briefing/2026-10-19"}}
  end

  test "deliver_now/3 appends to today's briefing and Inbox row" do
    enable_dissemination!()
    dreaming_agent!()
    person = person!()
    first = insight!(addressee: person, body: "First line.")
    assert {:ok, %{users: 1, items: 1}} = run!()
    assert [%Item{} = row] = briefing_rows(person.id)
    assert_received {:push, _, _}

    asked = insight!(addressee: person, action_type: "question", body: "Who owns it?")

    assert {:ok, 1} =
             Disseminator.deliver_now(person.id, [asked],
               now: DateTime.add(@now, 600),
               notifications_module: PushRecorder
             )

    briefing = briefing_of(person.id)

    assert briefing.items == %{
             BriefingCard.node_key(first) => first.id,
             BriefingCard.node_key(asked) => asked.id
           }

    assert [%Item{id: id, body: "2 items · 1 needs your call"}] = all_briefing_rows(person.id)
    assert id == row.id
    assert %Insight{delivered_at: %DateTime{}} = Repo.get!(Insight, asked.id)
    refute_received {:push, _, _}

    # Already in today's briefing: nothing added.
    assert {:ok, 0} = Disseminator.deliver_now(person.id, [asked], now: DateTime.add(@now, 900))

    # The contract is kept: opt-out and :no_agent.
    Platform.Roles.clear_override("memory.dreaming")
    assert {:error, :no_agent} = Disseminator.deliver_now(person.id, [asked], now: @now)
  end

  test "with no agent holding memory.dreaming nothing is delivered" do
    enable_dissemination!()
    person = person!()
    insight = insight!(addressee: person)

    assert {:ok, %{users: 0, items: 0, reason: :no_agent}} = run!()
    assert Repo.aggregate(Briefing, :count) == 0
    assert briefing_rows(person.id) == []
    assert %Insight{delivered_at: nil} = Repo.get!(Insight, insight.id)
  end

  test "a needs_call insight reaches the admin's briefing, not the guest's" do
    enable_dissemination!()
    dreaming_agent!()
    admin = person!("admin")
    guest = person!("member", external: true)

    call =
      insight!(addressee: guest, action_type: "question", body: "Can you renew the cert?")

    assert {:ok, %{items: items}} = run!()
    assert items >= 1

    assert briefing_rows(guest.id) == []
    refute Repo.exists?(from(b in Briefing, where: b.user_id == ^guest.id))

    assert BriefingCard.node_key(call) in Map.keys(briefing_of(admin.id).items)
    assert [%Item{body: body}] = briefing_rows(admin.id)
    assert body =~ "need"
  end

  test "deliver_now/3 refuses a guest: no briefing, no Inbox row, not delivered" do
    dreaming_agent!()
    guest = person!("member", external: true)
    asked = insight!(addressee: guest, action_type: "question", body: "Can you renew the cert?")

    assert {:error, :guest_addressee} =
             Disseminator.deliver_now(guest.id, [asked],
               now: @now,
               notifications_module: PushRecorder
             )

    # Read the tables directly: the Inbox's own listing hides a briefing row
    # from an external viewer, so asking it would pass whether or not a row
    # was written.
    refute Repo.exists?(from(b in Briefing, where: b.user_id == ^guest.id))
    refute Repo.exists?(from(i in Item, where: i.user_id == ^guest.id))
    assert %Insight{state: "open", delivered_at: nil} = Repo.get!(Insight, asked.id)
    refute_received {:push, _, _}

    # Control: the same call for an internal member delivers.
    member = person!()
    line = insight!(addressee: member, action_type: "question", body: "Who owns it?")
    assert {:ok, 1} = Disseminator.deliver_now(member.id, [line], now: @now)
    assert Repo.exists?(from(b in Briefing, where: b.user_id == ^member.id))
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

    defp delivered?(person, insight) do
      %Briefing{canvas_id: nil, items: items} = briefing_of(person.id)
      Map.get(items, BriefingCard.node_key(insight)) == insight.id
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

      assert delivered?(person, insight)
      assert [%Item{body: "1 item · FYI only"}] = briefing_rows(person.id)
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

      assert delivered?(person, insight)
    end

    # Task 01a15ee1 stage 2: file_tasks is on by default, and the project is
    # inferred (here from the cited task, rung 3), not only named.
    test "with file_tasks at its default, run/1 files the task into the inferred project" do
      assert Platform.Memory.Insights.Settings.get().file_tasks
      enable_dissemination!(%{dissemination_enabled: true})
      dreamer = dreamer!()
      person = person!()

      {:ok, cited_project} =
        Platform.Tasks.create_project(%{name: "cited-#{n()}", org_id: acme_org_id()})

      {:ok, _other} =
        Platform.Tasks.create_project(%{name: "other-#{n()}", org_id: acme_org_id()})

      {:ok, cited} =
        Platform.Tasks.create_task(%{project_id: cited_project.id, title: "cited #{n()}"})

      insight =
        ingest!(
          ~s(<synthesis-insight action="task" confidence="high" source="task:#{cited.id}" addressee="#{person.id}">
          Follow up on the cited work, ref #{n()}.
          </synthesis-insight>),
          dreamer
        )

      assert insight.action["project_id"] == cited_project.id
      assert insight.action["project_reason"] == "cited task's project"

      assert {:ok, %{users: 1, items: 1}} = run!()

      assert [filed] = Enum.reject(project_tasks(cited_project), &(&1.id == cited.id))
      assert filed.status == "backlog"
      assert filed.metadata["insight_id"] == insight.id

      acted = Repo.get!(Insight, insight.id)
      assert acted.state == "done"
      assert acted.artefact_ref == "task:" <> filed.id
      assert delivered?(person, insight)
      assert [%Item{body: "1 item · FYI only"}] = briefing_rows(person.id)
    end

    test "a task with no inferable project is delivered as needing a call and nothing is filed" do
      enable_dissemination!(%{dissemination_enabled: true})
      dreamer = dreamer!()
      person = person!()
      {:ok, a} = Platform.Tasks.create_project(%{name: "np-a-#{n()}", org_id: acme_org_id()})
      {:ok, b} = Platform.Tasks.create_project(%{name: "np-b-#{n()}", org_id: acme_org_id()})
      tasks_before = Repo.aggregate(Task, :count)

      insight =
        ingest!(
          ~s(<synthesis-insight action="task" confidence="high" addressee="#{person.id}">
          Someone should own the release notes, ref #{n()}.
          </synthesis-insight>),
          dreamer
        )

      refute Map.has_key?(insight.action, "project_id")

      log = capture_log(fn -> assert {:ok, %{users: 1, items: 1}} = run!() end)

      # Kept, not dropped as a refused apply: no warning, delivered, open.
      refute log =~ insight.id
      assert Repo.aggregate(Task, :count) == tasks_before
      assert project_tasks(a) == [] and project_tasks(b) == []
      assert %Insight{state: "open", acted_by: nil} = acted = Repo.get!(Insight, insight.id)
      assert %DateTime{} = acted.delivered_at
      assert delivered?(person, insight)
      assert [%Item{body: "1 item · 1 needs your call"}] = briefing_rows(person.id)

      # A re-run does not file it either: it waits for the person's pick.
      assert {:ok, %{users: 0, items: 0}} = run!(now: DateTime.add(@now, 3600))
      assert Repo.aggregate(Task, :count) == tasks_before
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
      assert delivered?(person, other)
      refute delivered?(person, insight)

      # Control: once a Historian exists, the next run applies and lists it.
      historian!()
      assert {:ok, %{items: 1}} = run!(now: DateTime.add(@now, 3600))
      assert Wiki.get_page(key).content == "Deploys go to host-b."
      assert delivered?(person, insight)
    end

    # Task 01a15ee1 stage 5 (carry-forward from stage 3): a needs_call
    # page_edit is routed to the root admins and must reach their "Needs
    # your call" open, never be tried unattended (which was refused and
    # dropped). Probe: restoring the apply-everything clause turns this red.
    test "a needs_call page_edit routed to a root admin is listed as a call, not applied" do
      enable_dissemination!(%{dissemination_enabled: true, apply_page_edits: true})
      dreamer = dreamer!()
      historian!()
      admin = person!("admin")
      guest = person!("member", external: true)
      key = "org/page/disseminate-call-#{n()}.md"
      {:ok, _} = Wiki.upsert_page(key, %{content: "Deploys go to host-a.", updated_by: guest.id})
      version = Wiki.get_page(key).version

      insight =
        ingest!(
          ~s(<synthesis-insight action="page_edit" confidence="high" target="#{key}" source="page:#{key}">
          The deploy host moved, ref #{n()}.
          <old>go to host-a</old><new>go to host-b</new>
          </synthesis-insight>),
          dreamer
        )

      assert insight.tier == "needs_call"

      {result, log} = with_log(fn -> run!() end)
      assert {:ok, %{users: users}} = result
      assert users >= 1
      refute log =~ insight.id

      # Not applied: the page and the insight are as they were.
      page = Wiki.get_page(key)
      assert {page.content, page.version} == {"Deploys go to host-a.", version}
      assert %Insight{state: "open", acted_by: nil} = Repo.get!(Insight, insight.id)

      # Listed for the admin, under Needs your call.
      assert delivered?(admin, insight)
      briefing = briefing_of(admin.id)
      view = Briefings.view(briefing, Platform.Access.Scope.for_user(admin))
      assert BriefingCard.node_key(insight) in Enum.map(view.needs_call, & &1.key)
      assert [%{kind: :page_edit, insight: %Insight{id: id}}] = view.needs_call
      assert id == insight.id
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

      assert delivered?(person, edit)
      assert delivered?(person, task)
      assert map_size(briefing_of(person.id).items) == 2
      assert [_one_row] = all_briefing_rows(person.id)
    end
  end

  test "the next fire is 07:00 America/Chicago" do
    ms = Disseminator.ms_until_next_fire(~U[2026-10-18 11:00:00Z])
    assert ms == 60 * 60 * 1000
    assert Disseminator.local_date(~U[2026-10-19 03:00:00Z]) == ~D[2026-10-18]
  end
end
