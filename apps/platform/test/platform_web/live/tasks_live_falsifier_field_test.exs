defmodule PlatformWeb.TasksLiveFalsifierFieldTest do
  @moduledoc """
  Task 01a0a5f5 stage 3: the task-create sheet asks a third question,
  `Wrong`, and the submit handler composes it into the description body
  ABOVE What and Why.

  The ordering assertion here is by BYTE INDEX, not by presence. A
  presence assertion passes on a falsifier appended to the end of the
  body, and an appended falsifier IS the failure mode this field exists
  to prevent — a fixer reads a ticket to find the instruction and stops
  scanning once they find one.

  Required-ness is FORM-LEVEL ONLY. There is no column, no changeset
  field and no migration; a ticket filed through MCP `task_create`, a
  seed or a script arrives with no falsifier and nothing rejects it.
  That is the documented state of this feature, not a defect, and the
  last test in this file pins it.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks}
  alias Platform.Tasks.Task
  alias PlatformWeb.Tasks.TaskCreateComponent

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "falsifier_#{System.unique_integer([:positive])}@example.com",
        name: "Falsifier Test User",
        oidc_sub: "oidc-falsifier-#{System.unique_integer([:positive])}"
      })
      |> Platform.TenancyFixtures.member_of_all_orgs!()

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Falsifier Project #{System.unique_integer([:positive])}",
        repo_url: "git@github.com:test/repo.git"
      })

    project
  end

  defp create(view), do: Phoenix.LiveViewTest.with_target(view, "#tasks-create")

  describe "the form" do
    test "renders Wrong as a peer of What and Why, same treatment, after Why", %{conn: conn} do
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = render_click(create(view), "taskcreate_toggle_sheet", %{})

      # All three go through the same `<.input type="textarea">`
      # component, so their class strings are identical by construction.
      # Hand-written markup for the third field would break that and is
      # what this assertion exists to catch.
      [c_what, c_why, c_wrong] =
        for name <- ~w(what why wrong) do
          tag =
            case Regex.run(~r/<textarea[^>]*name="task\[#{name}\]"[^>]*>/, html) do
              [tag] -> tag
              nil -> flunk("no textarea rendered for task[#{name}]")
            end

          case Regex.run(~r/class="([^"]*)"/, tag) do
            [_, class] -> class
            nil -> flunk("no class on the task[#{name}] textarea")
          end
        end

      assert c_what == c_why
      assert c_wrong == c_what

      # One-word label, and no demotion: no disclosure, no helper line,
      # no warning colour. The canvas is explicit that any token that
      # distinguishes this field from its siblings works against the
      # single design call.
      assert html =~ ~s(<label for="task-sheet-wrong">)
      assert html =~ ~s(Wrong<span aria-hidden="true">*</span>)

      [wrong_label] =
        Regex.run(~r{<label for="task-sheet-wrong">[\s\S]*?</label>}, html) ||
          flunk("no label rendered for the Wrong field")

      [what_label] = Regex.run(~r{<label for="task-sheet-what">[\s\S]*?</label>}, html)

      # The label span carries the same treatment as What's, and nothing
      # recasts the field as a caution or explains itself in a helper
      # line — a helper line is the tell that the placeholder failed.
      assert label_span_class(wrong_label) == label_span_class(what_label)
      refute wrong_label =~ "warning"
      refute wrong_label =~ "text-error"
      refute html =~ "Any caveats or uncertainties?"
      refute html =~ "How confident are you?"

      # Form order is What · Why · Wrong. The COMPOSED order inverts it;
      # see compose_description/3.
      i_what = index!(html, ~s(name="task[what]"))
      i_why = index!(html, ~s(name="task[why]"))
      i_wrong = index!(html, ~s(name="task[wrong]"))
      assert i_what < i_why
      assert i_why < i_wrong

      # Required, matching its siblings — the only place in the system
      # where falsifier presence has teeth.
      assert Regex.match?(
               ~r/<textarea[^>]*name="task\[wrong\]"[^>]*required/,
               html
             ) or
               Regex.match?(
                 ~r/<textarea[^>]*required[^>]*name="task\[wrong\]"/,
                 html
               )
    end
  end

  describe "compose_description/3" do
    test "puts ## Wrong BEFORE ## What, asserted by index not presence" do
      body =
        TaskCreateComponent.compose_description(
          "The grep for FooBar comes back empty",
          "Rename FooBar",
          "It reads wrong"
        )

      i_wrong = index!(body, "## Wrong")
      i_what = index!(body, "## What")
      i_why = index!(body, "## Why")

      # Moving {"Wrong", wrong} to the end of the composer's list must
      # turn THIS line red. A presence assertion would stay green.
      assert i_wrong < i_what
      assert i_what < i_why
      assert String.starts_with?(body, "## Wrong\n")
    end

    test "what+why only is byte-identical to the pre-rewrite two-section output" do
      assert TaskCreateComponent.compose_description("", "the what", "the why") ==
               "## What\nthe what\n\n## Why\nthe why"
    end

    test "reproduces every branch of the case it replaced" do
      # The four clauses of the old `case {what, why}`, including the
      # `{"", w} -> "## Why"` branch whose binding was hand-maintained.
      assert TaskCreateComponent.compose_description("", "", "") == nil
      assert TaskCreateComponent.compose_description("", "w only", "") == "## What\nw only"
      assert TaskCreateComponent.compose_description("", "", "y only") == "## Why\ny only"

      assert TaskCreateComponent.compose_description("", "w", "y") ==
               "## What\nw\n\n## Why\ny"

      # And the partials the third field adds.
      assert TaskCreateComponent.compose_description("x", "", "") == "## Wrong\nx"
      assert TaskCreateComponent.compose_description("x", "w", "") == "## Wrong\nx\n\n## What\nw"
      assert TaskCreateComponent.compose_description("x", "", "y") == "## Wrong\nx\n\n## Why\ny"

      assert TaskCreateComponent.compose_description("x", "w", "y") ==
               "## Wrong\nx\n\n## What\nw\n\n## Why\ny"

      # Whitespace-only is blank, and sections are trimmed.
      assert TaskCreateComponent.compose_description("  ", "  w  ", "  ") == "## What\nw"
    end
  end

  describe "submit" do
    test "the persisted description opens with ## Wrong", %{conn: conn} do
      project = create_project()
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      render_submit(create(view), "taskcreate_submit", %{
        "task" => %{
          "title" => "Falsifier round trip",
          "project_id" => project.id,
          "what" => "Add the Wrong field",
          "why" => "Human-filed tickets carry no falsifier",
          "wrong" => "If the form already has three textareas, stop and re-derive",
          "action" => "create",
          "assignee_id" => "",
          "assignee_type" => "agent",
          "deploy_target" => "",
          "epic_id" => ""
        }
      })

      created =
        Tasks.list_tasks_by_project(project.id)
        |> Enum.find(&(&1.title == "Falsifier round trip"))

      assert created
      assert String.starts_with?(created.description, "## Wrong\n")
      assert index!(created.description, "## Wrong") < index!(created.description, "## What")
    end

    test "what+why with no wrong still persists the exact two-section body", %{conn: conn} do
      project = create_project()
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      render_submit(create(view), "taskcreate_submit", %{
        "task" => %{
          "title" => "No falsifier supplied",
          "project_id" => project.id,
          "what" => "the what",
          "why" => "the why",
          "action" => "create",
          "assignee_id" => "",
          "assignee_type" => "agent",
          "deploy_target" => "",
          "epic_id" => ""
        }
      })

      created =
        Tasks.list_tasks_by_project(project.id)
        |> Enum.find(&(&1.title == "No falsifier supplied"))

      assert created
      assert created.description == "## What\nthe what\n\n## Why\nthe why"
    end
  end

  describe "the scope bound" do
    test "no tasks column and no changeset field were added for the falsifier" do
      refute :wrong in Task.__schema__(:fields)
      refute :falsifier in Task.__schema__(:fields)

      # Presence is a FORM-LEVEL requirement only: a programmatic filing
      # path supplies no falsifier and is accepted. This test passing on
      # an ACCEPTANCE is the point — a rejection here would mean someone
      # took the schema route the ticket's scope bound rules out.
      {:ok, task} =
        Tasks.create_task(%{
          title: "Filed with no falsifier",
          description: "## What\njust a prescription",
          project_id: create_project().id
        })

      assert task.description == "## What\njust a prescription"
      refute task.description =~ "## Wrong"
    end
  end

  defp label_span_class(label_html) do
    [_, class] = Regex.run(~r/<span class="(label[^"]*)"/, label_html)
    class
  end

  defp index!(haystack, needle) do
    case :binary.match(haystack, needle) do
      {i, _len} -> i
      :nomatch -> flunk("#{inspect(needle)} not found in #{inspect(haystack)}")
    end
  end
end
