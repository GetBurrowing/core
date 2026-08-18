defmodule PlatformWeb.TasksLiveInputLabelsTest do
  @moduledoc """
  Guards the design-system `<.input>` migration of the Tasks create sheets
  (docs/design-system/IMPLEMENTATION.md step 4).

  Every migrated field must render a real programmatic `label[for]` →
  control `id` association (WCAG 1.3.1); the hand-rolled markup these
  replaced had visually-styled labels with no association at all.

  Note the assertions read the *rendered* DOM. A `form/3` test that hands
  the param key in cannot see the template drop the control, so the ids
  are pulled out of the HTML the template actually produced.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Repo

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "input_labels_#{System.unique_integer([:positive])}@example.com",
        name: "Input Labels User",
        oidc_sub: "oidc-input-labels-#{System.unique_integer([:positive])}"
      })
      |> member_of_all_orgs!()

    init_test_session(conn, current_user_id: user.id)
  end

  # Asserts a control with `id` exists AND a <label for="id"> points at it.
  defp assert_labelled(html, id) do
    assert html =~ ~s(id="#{id}"),
           "expected a control rendered with id=#{id}; the template did not render it"

    assert html =~ ~s(for="#{id}"),
           "control #{id} rendered but no label[for=#{id}] is associated with it"
  end

  defp open_create_menu(view) do
    view
    |> element(~s(button[data-role="header-create-menu-trigger"]))
    |> render_click()

    view
  end

  describe "new-project sheet" do
    test "name and slug are label-associated", %{conn: conn} do
      {:ok, view, _html} = live(authenticated_conn(conn), ~p"/tasks")

      view
      |> element(~s(button[data-role="project-create-trigger"]))
      |> render_click()

      html = render(view)

      assert_labelled(html, "project_name")
      assert_labelled(html, "project_slug")
    end
  end

  describe "new-epic sheet" do
    test "every migrated epic field is label-associated", %{conn: conn} do
      {:ok, view, _html} = live(authenticated_conn(conn), ~p"/tasks")

      view
      |> open_create_menu()
      |> element(~s(#header-create-menu button[phx-click="sidebar_toggle_epic_sheet"]))
      |> render_click()

      html = render(view)
      assert html =~ ~s(id="create-epic-form")

      for id <- ~w(epic_name epic_description epic_acceptance_criteria
                   epic_target_branch epic_deploy_target) do
        assert_labelled(html, id)
      end
    end
  end

  describe "new-task sheet" do
    test "title/what/why are label-associated and the auto-resize textareas are on-scale",
         %{conn: conn} do
      {:ok, view, _html} = live(authenticated_conn(conn), ~p"/tasks")

      view
      |> element(~s(button[data-role="header-new-task"]))
      |> render_click()

      html = render(view)
      assert html =~ ~s(id="create-task-form")

      assert_labelled(html, "task_title")
      assert_labelled(html, "task-sheet-what")
      assert_labelled(html, "task-sheet-why")

      # The `kind={:auto_resize}` contract, at the call site rather than in
      # isolation: the sheet's What/Why textareas must carry the blessed
      # inline style and the design-system height clamp.
      what =
        Regex.run(~r/<textarea[^>]*id="task-sheet-what"[^>]*>/, html) |> List.first()

      assert what, "expected a <textarea id=\"task-sheet-what\"> in the create-task sheet"
      assert what =~ "field-sizing: content"
      assert what =~ "min-h-10"
      assert what =~ "max-h-50"
    end
  end
end
