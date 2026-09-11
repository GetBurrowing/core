defmodule PlatformWeb.Tasks.StackMemberParkedReasonTest do
  @moduledoc """
  A stack member the board surfaces must explain itself (task 01a06df3 stage 3).

  Stages 1–2 made a `stack_pending` member findable by search and visible
  without a further click. That trades one confusion for another unless the row
  says WHY it cannot be worked: a member parked behind the stack's closed
  commencement gate has `blocked_by: []`, so `dep_annotation_text/2` returns
  `nil` and the row rendered a status badge and nothing else. The reader clicks
  it, tries to work it, and hits the gate with no explanation — the same
  misleading signal the ticket names on `stack_get`, where `executable_now: []`
  reads as a dependency problem when it is actually the gate.

  Three cases, and the middle one is the whole point:

    * `stack_pending` with no in-stack deps → the parked reason renders.
    * `stack_pending` WITH an in-stack predecessor → the dep annotation renders
      and the parked reason does NOT. The new line must not replace the
      truthful one.
    * `in_progress` → neither.

  A helper that returned the reason for every status would pass the first and
  fail the last two.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Tasks.{Stacks, Task}
  alias Platform.Tasks.StackGraph
  alias Platform.{Repo, Tasks}
  alias PlatformWeb.Tasks.StackStyles

  @parked_role ~s([data-role="stack-member-parked-reason"])
  @dep_role ~s([data-role="dep-annotation"])
  @parked_copy "parked until the stack starts"

  # ── The helper, in isolation ───────────────────────────────────────────
  #
  # Cheap and pure, so the discriminating cases are stated twice: once here
  # against the function and once below against the rendered DOM. The render
  # tests are the deliverable; these localise a failure to the helper.
  describe "StackStyles.member_parked_reason/2" do
    test "a stack_pending member with no dep annotation gets a reason" do
      assert StackStyles.member_parked_reason("stack_pending", nil) =~ @parked_copy
    end

    test "a stack_pending member WITH a dep annotation gets none" do
      refute StackStyles.member_parked_reason("stack_pending", "needs ①")
    end

    test "no other status gets a reason, dep annotation or not" do
      for status <- ~w(in_progress in_review deploying done blocked planning backlog) do
        refute StackStyles.member_parked_reason(status, nil),
               "#{status} with no dep annotation should get no parked reason"

        refute StackStyles.member_parked_reason(status, "needs ①"),
               "#{status} with a dep annotation should get no parked reason"
      end
    end
  end

  # ── The rendered board ────────────────────────────────────────────────

  describe "board stack-member rows" do
    setup %{conn: conn} do
      project = create_project()
      stack = create_stack(project)

      # ① parked, nothing in front of it — the gate is the only reason.
      parked =
        create_member(project, stack, 1, %{
          title: "Parked with no predecessor",
          status: "stack_pending"
        })

      # ② parked AND behind ①, so it has a truthful dependency reason.
      dependent =
        create_member(project, stack, 2, %{
          title: "Parked behind a predecessor",
          status: "stack_pending",
          dependencies: [%{"task_id" => parked.id, "kind" => "blocks"}]
        })

      # ③ actually running: neither line belongs on it.
      running =
        create_member(project, stack, 3, %{
          title: "Already running member",
          status: "in_progress"
        })

      # The stack has to roll up to a status that is a real board column or
      # the card — and therefore every row under it — never renders at all.
      {:ok, _} = Stacks.recompute_stack_status(stack)

      # PREMISE, not decoration. `create_task/2` is not obliged to honour the
      # status we asked for, and this whole stage is about one specific
      # status. If the seed does not park these two at `stack_pending` then
      # every assertion below is about some other code path.
      assert Repo.get!(Task, parked.id).status == "stack_pending"
      assert Repo.get!(Task, dependent.id).status == "stack_pending"
      assert Repo.get!(Task, running.id).status == "in_progress"

      # PREMISE for the middle case, and the reason it is not vacuous.
      # "the parked reason is absent" would also be true of a row that
      # rendered nothing at all, or of a fixture whose dependency never
      # landed. Prove the discriminating input really discriminates: the
      # dependent member HAS an in-stack predecessor the annotator can see,
      # and the member it is compared against does NOT.
      members = Repo.all(Task) |> Enum.filter(&(&1.stack_id == stack.id))
      assert length(members) == 3
      assert StackGraph.dep_annotation_text(find(members, parked), members) == nil
      assert StackGraph.dep_annotation_text(find(members, dependent), members) == "needs ①"
      assert StackGraph.dep_annotation_text(find(members, running), members) == nil

      {:ok, view, _html} = live(authenticated_conn(conn), ~p"/tasks")

      # The rows only exist inside an EXPANDED card, so this click is what
      # puts the subject of the test on screen at all. Asserting the closed
      # state first means a later `refute` cannot be satisfied by the card
      # simply having failed to open.
      refute has_element?(view, desktop(parked))

      _ =
        view
        |> with_target("#tasks-stacks")
        |> render_click("stack_toggle_expand", %{"id" => stack.id})

      _ = :sys.get_state(view.pid)

      %{view: view, stack: stack, parked: parked, dependent: dependent, running: running}
    end

    test "every member row is on screen, so an absence below is a real absence", ctx do
      for member <- [ctx.parked, ctx.dependent, ctx.running] do
        assert has_element?(ctx.view, desktop(member)), "desktop row missing for #{member.title}"
        assert has_element?(ctx.view, mobile(member)), "mobile row missing for #{member.title}"
        assert render(ctx.view) =~ member.title
      end
    end

    test "a stack_pending member with no in-stack deps explains the gate, on both surfaces",
         ctx do
      for row <- [desktop(ctx.parked), mobile(ctx.parked)] do
        assert has_element?(ctx.view, "#{row} #{@parked_role}"),
               "no parked reason in #{row}"

        assert ctx.view |> element("#{row} #{@parked_role}") |> render() =~ @parked_copy

        # It says the gate, not a predecessor — the wording is the payload.
        assert ctx.view |> element("#{row} #{@parked_role}") |> render() =~
                 "not waiting on another member"

        # And there is no dep annotation to contradict it.
        refute has_element?(ctx.view, "#{row} #{@dep_role}")
      end
    end

    test "a stack_pending member WITH an unmet in-stack dep keeps the dep annotation and gets no parked reason",
         ctx do
      for row <- [desktop(ctx.dependent), mobile(ctx.dependent)] do
        assert has_element?(ctx.view, row), "the dependent row itself is missing: #{row}"

        # POSITIVE half. Without this the refute below is satisfied by a row
        # that rendered no reason line of any kind.
        assert has_element?(ctx.view, "#{row} #{@dep_role}"),
               "the dep annotation is what must render here, and it did not, in #{row}"

        assert ctx.view |> element("#{row} #{@dep_role}") |> render() =~ "needs ①"

        # NEGATIVE half: the new line must not replace it or sit beside it.
        refute has_element?(ctx.view, "#{row} #{@parked_role}")
      end
    end

    test "an in_progress member gets neither line, on both surfaces", ctx do
      for row <- [desktop(ctx.running), mobile(ctx.running)] do
        # Both refutes below would also hold of a row that never rendered, and
        # "the stack card failed to expand" is a live failure mode on this
        # surface, not a hypothetical. Pin the row IN THIS TEST rather than
        # leaning on a sibling test to have checked it.
        assert has_element?(ctx.view, row), "the in_progress row itself is missing: #{row}"
        assert ctx.view |> element(row) |> render() =~ ctx.running.title

        refute has_element?(ctx.view, "#{row} #{@parked_role}")
        refute has_element?(ctx.view, "#{row} #{@dep_role}")
      end
    end

    test "the parked copy appears exactly as many times as there are parked-without-deps members",
         ctx do
      # One member qualifies and two do not, and each qualifying member has a
      # desktop row and a mobile row in the one shared DOM (`lg:hidden` /
      # `hidden lg:grid` is CSS visibility, not presence). A helper that
      # ignored its arguments would land at 6 here, and a leak into the
      # dependent or running row would land at 4.
      html = render(ctx.view)
      occurrences = html |> String.split(@parked_copy) |> length() |> Kernel.-(1)
      assert occurrences == 2, "expected 2 occurrences (desktop + mobile), got #{occurrences}"
    end
  end

  # ── Fixtures ──────────────────────────────────────────────────────────

  defp find(members, %Task{id: id}), do: Enum.find(members, &(&1.id == id))

  defp desktop(%Task{id: id}), do: "#stack-member-#{id}"
  defp mobile(%Task{id: id}), do: "#stack-member-mobile-#{id}"

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "parked_reason_#{System.unique_integer([:positive])}@example.com",
        name: "Parked Reason User",
        oidc_sub: "oidc-parked-reason-#{System.unique_integer([:positive])}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_project do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Parked Reason Project #{System.unique_integer([:positive])}",
        repo_url: "git@github.com:test/repo.git"
      })

    project
  end

  defp create_stack(project) do
    slug = "parked-reason-stack-#{System.unique_integer([:positive])}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Parked Reason Stack #{System.unique_integer([:positive])}",
        rollup_branch: Stacks.rollup_branch_name(slug)
      })

    stack
  end

  defp create_member(project, stack, position, attrs) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{
            project_id: project.id,
            priority: "medium",
            stack_id: stack.id,
            stack_position: position
          },
          attrs
        )
      )

    task
  end
end
