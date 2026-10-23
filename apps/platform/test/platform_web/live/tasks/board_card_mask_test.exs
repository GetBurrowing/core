defmodule PlatformWeb.Tasks.BoardCardMaskTest do
  @moduledoc """
  "Names masked" on the desktop kanban card (task 01a169e5 stage 1).

  The desktop card printed `{@task.project.name}` raw above the title while
  every other Tasks surface (rail, Filter row, epic strip) followed the mask.
  The card now resolves through `TaskDisplay.label_for/4`, the same helper the
  Filter row uses.

  The absence assertion sweeps the WHOLE `#tasks-board` subtree, not the card's
  `<p>`, so a leak relocated anywhere else on the board (an attribute, a stack
  card, the mobile card) also fails. The card is pinned present first, and a
  masking-off control proves the same fixture does put the real name on the
  card, so the absence is not vacuous.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.MaskAssertions

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks, Tenancy}
  alias Platform.Tenancy.OrgMembership

  @real_name "Zanzibar Freight Holdings"

  # `value` only, as in RailMaskSurfacesTest: an `<option value>` carries a
  # project UUID, not a name.
  @machine_attrs ~w(value)

  defp acme_admin_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "board-card-mask-#{n}@example.com",
        name: "Board Card Mask User #{n}",
        oidc_sub: "oidc-board-card-mask-#{n}"
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
    {:ok, project} =
      Tasks.create_project(%{
        name: @real_name,
        slug: "zanzibar-freight-holdings",
        org_id: Tenancy.get_org_by_slug!("acme").id
      })

    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "Mask probe card", status: "backlog"})

    {project, task}
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
    refute label =~ "Zanzibar"
    label
  end

  test "masking ON: the real project name appears nowhere on the board; the card shows the mask label",
       %{conn: conn} do
    conn = acme_admin_conn(conn)
    {project, task} = seed()

    {:ok, view, _html} = live(conn, ~p"/tasks")

    html = toggle_mask(view, true)
    board = subtree(html, "#tasks-board")
    card = subtree(html, "#task-card-#{task.id}")

    # The card is the desktop card under test, and it rendered.
    assert card =~ "Mask probe card"

    refute_name_anywhere(board, @real_name, @machine_attrs)
    refute_name_anywhere(board, "Zanzibar", @machine_attrs)

    label = masked_label(view, project)
    assert card =~ label
  end

  test "masking OFF (positive control): the card shows the real project name", %{conn: conn} do
    conn = acme_admin_conn(conn)
    {_project, task} = seed()

    {:ok, _view, html} = live(conn, ~p"/tasks")

    _board = subtree(html, "#tasks-board")
    card = subtree(html, "#task-card-#{task.id}")

    assert card =~ "Mask probe card"
    assert_name_anywhere(card, @real_name)
  end
end
