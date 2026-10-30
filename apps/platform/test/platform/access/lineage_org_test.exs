defmodule Platform.Access.LineageOrgTest do
  @moduledoc """
  Task 01a18d38 stage 2: the `{:org, _}` edges and the project → meeting
  chat space edge in `Platform.Access.Lineage`, read directly. Each expansion
  is checked to include what it should AND to exclude another org's rows, so
  an expansion that returned everything would fail as surely as one that
  returned nothing.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access.Lineage
  alias Platform.Chat
  alias Platform.Chat.Space
  alias Platform.Meetings
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task

  setup do
    root = acme_org_id()
    client = tenant_org_id("nettlefold")
    {:ok, project} = Tasks.create_project(%{name: "Lineage #{uniq()}", org_id: client})
    {:ok, root_project} = Tasks.create_project(%{name: "Lineage root #{uniq()}", org_id: root})
    %{root: root, client: client, project: project, root_project: root_project}
  end

  defp uniq, do: System.unique_integer([:positive])

  defp space!(org_id, kind \\ "channel", metadata \\ %{}) do
    n = uniq()

    %Space{}
    |> Space.changeset(%{
      kind: kind,
      name: "ln-#{n}",
      slug: "ln-#{n}",
      org_id: org_id,
      metadata: metadata
    })
    |> Repo.insert!()
  end

  defp canvas!(space) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        joined_at: DateTime.utc_now()
      })

    {:ok, canvas} = Chat.create_canvas(%{space_id: space.id, created_by: p.id, title: "ln"})
    canvas
  end

  test "typed/1 accepts an org tuple and an Org struct, never a malformed id", ctx do
    assert Lineage.typed({:org, ctx.client}) == {:org, ctx.client}
    assert Lineage.typed(Platform.Tenancy.get_org(ctx.client)) == {:org, ctx.client}
    assert Lineage.typed({:org, "not-a-uuid"}) == :untyped
    refute :org in Lineage.id_types()
  end

  test "ancestors/1 puts the org above a project, task, space and canvas", ctx do
    task = Repo.insert!(%Task{project_id: ctx.project.id, title: "ln task"})
    channel = space!(ctx.client)
    canvas = canvas!(channel)

    assert {:org, ctx.client} in Lineage.ancestors({:project, ctx.project.id})
    assert {:org, ctx.client} in Lineage.ancestors({:task, task.id})
    assert {:org, ctx.client} in Lineage.ancestors({:space, channel.id})
    assert {:org, ctx.client} in Lineage.ancestors({:canvas, canvas.id})
    refute {:org, ctx.root} in Lineage.ancestors({:space, channel.id})
    assert Lineage.ancestors({:org, ctx.client}) == [{:org, ctx.client}]
  end

  test "a meeting chat space has its meeting's project and that project's org above it", ctx do
    {:ok, meeting} = Meetings.create_meeting(%{project_id: ctx.project.id, name: "ln meeting"})

    above = Lineage.ancestors({:space, meeting.chat_space_id})
    assert {:project, ctx.project.id} in above
    assert {:org, ctx.client} in above
  end

  test "a space with a NULL org inherits no org (fail closed, not open)" do
    orphan = space!(nil)
    assert Lineage.ancestors({:space, orphan.id}) == [{:space, orphan.id}]
  end

  test "descendant_ids/2 expands an org to its projects, spaces and canvases, and no further",
       ctx do
    task = Repo.insert!(%Task{project_id: ctx.project.id, title: "ln task"})
    exec = space!(ctx.client, "execution", %{"task_id" => task.id})
    channel = space!(ctx.client)
    canvas = canvas!(channel)
    {:ok, meeting} = Meetings.create_meeting(%{project_id: ctx.project.id, name: "ln meeting"})

    root_channel = space!(ctx.root)
    root_canvas = canvas!(root_channel)
    orphan = space!(nil)

    target = [{:org, ctx.client}]

    projects = Lineage.descendant_ids(:project, target)
    assert ctx.project.id in projects
    refute ctx.root_project.id in projects

    assert task.id in Lineage.descendant_ids(:task, target)

    spaces = Lineage.descendant_ids(:space, target)
    for id <- [exec.id, channel.id, meeting.chat_space_id], do: assert(id in spaces)
    for id <- [root_channel.id, orphan.id], do: refute(id in spaces)

    canvases = Lineage.descendant_ids(:canvas, target)
    assert canvas.id in canvases
    refute root_canvas.id in canvases
  end

  test "descendant_ids/2 expands a project to its meetings' chat spaces", ctx do
    {:ok, meeting} = Meetings.create_meeting(%{project_id: ctx.project.id, name: "ln meeting"})

    {:ok, other} =
      Meetings.create_meeting(%{project_id: ctx.root_project.id, name: "ln other meeting"})

    spaces = Lineage.descendant_ids(:space, [{:project, ctx.project.id}])
    assert meeting.chat_space_id in spaces
    refute other.chat_space_id in spaces
  end
end
