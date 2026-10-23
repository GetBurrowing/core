defmodule PlatformWeb.Tasks.TaskDetailMaskTest do
  @moduledoc """
  "Names masked" in the task detail panel (task 01a169e5 stage 2).

  Three sites rendered real names in `#tasks-detail` while masking was on:
  the header project, the header epic, and the `project_files` deploy-target
  row ("Project Files: <project>/<folder>"). Each now resolves through
  `TaskDisplay.label_for/4`.

  The absence sweep covers the WHOLE `#tasks-detail` subtree, attributes
  included, for all three names. The masking-off control asserts all three
  ARE in the same subtree for the same fixture, so absence is not vacuous.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.MaskAssertions

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks, Tenancy}
  alias Platform.Tenancy.OrgMembership

  @project_name "Zanzibar Freight Holdings"
  @epic_name "Operation Kestrel"
  @target_name "Quillfeather Labs"
  @names [@project_name, @epic_name, @target_name]

  # `value` only, as in RailMaskSurfacesTest: an `<option value>` carries a
  # project UUID, not a name.
  @machine_attrs ~w(value)

  defp acme_admin_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "task-detail-mask-#{n}@example.com",
        name: "Task Detail Mask User #{n}",
        oidc_sub: "oidc-task-detail-mask-#{n}"
      })

    Enum.each(Tenancy.list_orgs(), fn org ->
      role = if org.slug == "acme", do: "admin", else: "member"

      %OrgMembership{}
      |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
      |> Repo.insert!()
    end)

    init_test_session(conn, current_user_id: user.id)
  end

  defp seed do
    org_id = Tenancy.get_org_by_slug!("acme").id

    {:ok, project} =
      Tasks.create_project(%{
        name: @project_name,
        slug: "zanzibar-freight-holdings",
        org_id: org_id
      })

    {:ok, target} =
      Tasks.create_project(%{name: @target_name, slug: "quillfeather-labs", org_id: org_id})

    {:ok, epic} = Tasks.create_epic(%{project_id: project.id, name: @epic_name})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        epic_id: epic.id,
        title: "Mask probe card",
        status: "backlog",
        deploy_target_config: %{
          "strategy" => "project_files",
          "project_id" => target.id,
          "folder" => "exports"
        }
      })

    %{project: project, target: target, epic: epic, task: task}
  end

  defp subtree(html, selector) do
    fragment =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(selector)
      |> LazyHTML.to_html()

    assert fragment != "",
           "Expected #{inspect(selector)} to be in the DOM. An absence assertion " <>
             "against a subtree that did not render proves nothing."

    fragment
  end

  defp toggle_mask(view, masked?) do
    view
    |> element("[data-role=rail-mask-toggle]")
    |> render_click(%{"masked" => to_string(masked?)})
  end

  # The label the LiveView itself resolved for this project — read from the
  # mounted socket, not recomputed, so the test cannot agree with a copy.
  defp masked_label(view, project) do
    labels = :sys.get_state(view.pid).socket.assigns.mask_labels
    label = Map.fetch!(labels, {:project, project.id})
    refute label =~ project.name
    label
  end

  test "masking ON: no real project, epic or Project Files target name anywhere in #tasks-detail",
       %{conn: conn} do
    conn = acme_admin_conn(conn)
    %{task: task, target: target} = seed()

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    toggle_mask(view, true)
    detail = subtree(render(view), "#tasks-detail")

    # The panel under test is open on this task.
    assert detail =~ "Mask probe card"
    assert detail =~ ~s(data-strategy="project_files")

    for name <- @names, do: refute_name_anywhere(detail, name, @machine_attrs)

    for word <- ~w(Zanzibar Kestrel Quillfeather),
        do: refute_name_anywhere(detail, word, @machine_attrs)

    assert detail =~ "Project Files: #{masked_label(view, target)}/exports"
  end

  test "masking OFF (positive control): all three real names render in #tasks-detail",
       %{conn: conn} do
    conn = acme_admin_conn(conn)
    %{task: task} = seed()

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    detail = subtree(render(view), "#tasks-detail")

    assert detail =~ "Mask probe card"
    for name <- @names, do: assert_name_anywhere(detail, name)
    assert detail =~ "Project Files: #{@target_name}/exports"
  end
end
