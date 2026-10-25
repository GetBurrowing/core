defmodule PlatformWeb.Tasks.BoardDataFiltersTest do
  @moduledoc """
  Task 01a161fd stage 1: the URL layer for the Tasks filters.

    * the decoders for `project`, `epic`, `status`, the kind LIST and `mine`,
      including garbage;
    * the round trip `decode(tasks_path(x)) == x` over every presence
      combination of the new keys (crossed with every sort mode), and over
      every subset of statuses and of kinds;
    * `BoardData.narrow_list/3`, one predicate at a time, each absence after a
      positive control on the same fixture;
    * `Platform.Tasks.mine?/2` against `Tasks.list_my_open_tasks/2` on the
      same rows (parity), with the agent-assignee negative case;
    * org-scope parity with `BoardComponent`'s scope lens.

  `async: false`: the parity half writes rows, as
  `Platform.Tasks.ListMyOpenTasksTest` does.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task
  alias PlatformWeb.Tasks.BoardData

  # Every doctest in the module, old and new: the positional outputs stay
  # byte-identical and the map form's new example holds.
  doctest BoardData

  @p "0a161fd0-0000-7000-8000-000000000001"
  @p2 "0a161fd0-0000-7000-8000-000000000002"
  @e "0a161fd0-0000-7000-8000-0000000000e1"
  @me "0a161fd0-0000-7000-8000-00000000a001"

  defp decode(path) do
    %URI{path: "/tasks", query: query} = URI.parse(path)
    BoardData.decode_filter_params(URI.decode_query(query || ""))
  end

  # Every subset of `list`, each in `list` order.
  defp subsets([]), do: [[]]

  defp subsets([head | tail]) do
    rest = subsets(tail)
    Enum.map(rest, &[head | &1]) ++ rest
  end

  defp filters(attrs) do
    Map.merge(
      %{
        board_sort: :priority,
        selected_project_id: nil,
        selected_epic_id: nil,
        status_filters: [],
        kind_filters: [],
        mine_filter: false
      },
      attrs
    )
  end

  describe "decoders" do
    test "status: a comma list intersected with Task.statuses/0, in that order, no duplicates" do
      assert BoardData.decode_status_param("blocked,in_progress") == ["in_progress", "blocked"]
      assert BoardData.decode_status_param("done, done ,bogus,") == ["done"]
      assert BoardData.decode_status_param("failed") == []
      assert BoardData.decode_status_param("") == []
      assert BoardData.decode_status_param(nil) == []
      assert BoardData.decode_status_param(["done"]) == []
      assert BoardData.decode_status_param(Enum.join(Task.statuses(), ",")) == Task.statuses()
    end

    test "kind list: intersected with Task.kinds/0" do
      assert BoardData.decode_kind_list_param("bug,feature") == ["feature", "bug"]
      assert BoardData.decode_kind_list_param("bug,Bug,widget") == ["bug"]
      assert BoardData.decode_kind_list_param(nil) == []
    end

    test "a shared single ?kind=bug decodes to a one-element :kind_filters" do
      for kind <- Task.kinds() do
        decoded = BoardData.decode_filter_params(%{"kind" => kind})
        assert decoded.kind_filters == [kind]

        assert decoded |> Map.keys() |> Enum.sort() ==
                 ~w(board_sort kind_filters mine_filter selected_epic_id selected_project_id
                    status_filters)a
      end

      assert BoardData.decode_filter_params(%{"kind" => "nope"}).kind_filters == []
    end

    test "project and epic: canonical UUIDs only, downcased; 'all' and garbage are nil" do
      assert BoardData.decode_project_param(@p) == @p
      assert BoardData.decode_project_param(String.upcase(@p)) == @p
      assert BoardData.decode_project_param("all") == nil
      assert BoardData.decode_project_param("burrow") == nil
      # 16 bytes: a bare Ecto.UUID.cast/1 would invent a uuid from this.
      assert BoardData.decode_project_param("0123456789abcdef") == nil
      assert BoardData.decode_project_param(nil) == nil
      assert BoardData.decode_epic_param(@e) == @e
      assert BoardData.decode_epic_param("redesign") == nil
    end

    test "mine: only \"1\" is on" do
      assert BoardData.decode_mine_param("1") == true
      for v <- [nil, "0", "true", "me", ""], do: assert(BoardData.decode_mine_param(v) == false)
    end
  end

  describe "tasks_path/1 round trip" do
    test "all defaults are the bare board" do
      assert BoardData.tasks_path(filters(%{})) == "/tasks"
      assert decode("/tasks") == filters(%{})
    end

    test "every presence combination of project, epic, status, kind list and mine, at every sort" do
      combos =
        for sort <- BoardData.sort_modes(),
            project <- [nil, @p],
            epic <- if(project, do: [nil, @e], else: [nil]),
            status <- [[], ["in_progress", "blocked"]],
            kinds <- [[], ["bug"], ["feature", "bug"]],
            mine <- [false, true] do
          filters(%{
            board_sort: sort,
            selected_project_id: project,
            selected_epic_id: epic,
            status_filters: status,
            kind_filters: kinds,
            mine_filter: mine
          })
        end

      assert length(combos) == 4 * 3 * 2 * 3 * 2

      for x <- combos do
        path = BoardData.tasks_path(x)
        assert decode(path) == x, "round trip broke for #{path}"
      end
    end

    test "every subset of statuses and every subset of kinds" do
      status_sets = subsets(Task.statuses())
      kind_sets = subsets(Task.kinds())
      assert length(status_sets) == 512 and length(kind_sets) == 32

      for status <- status_sets do
        x = filters(%{selected_project_id: @p, status_filters: status, mine_filter: true})
        assert decode(BoardData.tasks_path(x)) == x
      end

      for kinds <- kind_sets do
        x = filters(%{board_sort: :oldest, kind_filters: kinds})
        assert decode(BoardData.tasks_path(x)) == x
      end
    end

    test "fixed key order, literal comma lists, and the new keys after origin" do
      path =
        BoardData.tasks_path(%{
          sponsor_filter: :mine,
          board_sort: :newest,
          task_search_query: "a,b",
          scope_filter: "acme",
          kind_filters: ["feature", "bug"],
          origin_filter: "external_feedback",
          selected_project_id: @p,
          selected_epic_id: @e,
          status_filters: ["in_progress", "blocked"],
          mine_filter: true
        })

      assert path ==
               "/tasks?sponsor=mine&sort=newest&q=a%2Cb&scope=acme&kind=feature,bug" <>
                 "&origin=external_feedback&project=#{@p}&epic=#{@e}" <>
                 "&status=in_progress,blocked&mine=1"
    end

    test "kind: emitted from :kind_filters only" do
      assert BoardData.tasks_path(%{kind_filters: []}) == "/tasks"
      assert BoardData.tasks_path(%{kind_filters: ["chore"]}) == "/tasks?kind=chore"
      assert BoardData.tasks_path(%{kind_filters: ["chore", "ops"]}) == "/tasks?kind=chore,ops"
    end

    test "the positional arities take the kind set as a list" do
      assert BoardData.tasks_path(:all, :priority, "", :all, []) == "/tasks"

      assert BoardData.tasks_path(:mine, :updated, "zephyr", "acme", ["chore"]) ==
               "/tasks?sponsor=mine&sort=updated&q=zephyr&scope=acme&kind=chore"

      assert BoardData.tasks_path(:all, :priority, "", :all, ["bug"], "external_feedback") ==
               "/tasks?kind=bug&origin=external_feedback"

      assert BoardData.tasks_path(:all, :priority, "", :all, ["bug", "chore"]) ==
               "/tasks?kind=bug,chore"

      assert BoardData.tasks_path(:mine, :updated) == "/tasks?sponsor=mine&sort=updated"
    end
  end

  # ── narrow_list/3 ─────────────────────────────────────────────────────

  defp dt(day), do: DateTime.new!(Date.new!(2026, 1, day), ~T[09:00:00.000000], "Etc/UTC")

  defp t(n, attrs) do
    struct!(
      Task,
      Map.merge(
        %{
          id: "0a161fd0-0000-7000-8000-#{String.pad_leading(to_string(n), 12, "0")}",
          title: "task #{n}",
          project_id: @p,
          epic_id: nil,
          status: "backlog",
          kind: "feature",
          priority: "medium",
          origin: "internal",
          sponsor_user_id: nil,
          assignee_id: nil,
          assignee_type: nil,
          phase_assignees: %{},
          stack_id: nil,
          inserted_at: dt(n),
          updated_at: dt(n)
        },
        attrs
      )
    )
  end

  defp ctx, do: %{current_user_id: @me, agent_names: %{}, root_org_slug: "root"}
  defp narrow(tasks, f), do: tasks |> BoardData.narrow_list(f, ctx()) |> Enum.map(& &1.id)
  defp id_of(task), do: task.id

  describe "narrow_list/3 per predicate" do
    setup do
      %{
        a: t(1, %{status: "in_progress", kind: "bug", sponsor_user_id: @me, epic_id: @e}),
        b: t(2, %{status: "blocked", kind: "feature", project_id: @p2}),
        c: t(3, %{status: "done", kind: "chore", origin: "external_feedback", title: "Zephyr"}),
        d:
          t(4, %{
            phase_assignees: %{"review" => %{"assignee_id" => @me, "assignee_type" => "user"}}
          })
      }
    end

    test "no filter keeps every task, done included, in priority order", %{a: a, b: b, c: c, d: d} do
      all = [a, b, c, d]
      assert narrow(all, %{}) == Enum.map(BoardData.sort_items(all, :priority), &id_of/1)
      assert c.id in narrow(all, %{})
    end

    test "project and epic", %{a: a, b: b, c: c, d: d} do
      all = [a, b, c, d]
      assert b.id in narrow(all, %{}), "positive control"
      refute b.id in narrow(all, %{selected_project_id: @p})
      assert Enum.sort(narrow(all, %{selected_project_id: @p})) == Enum.sort([a.id, c.id, d.id])
      assert narrow(all, %{selected_project_id: @p, selected_epic_id: @e}) == [a.id]
    end

    test "status set", %{a: a, b: b, c: c, d: d} do
      all = [a, b, c, d]

      assert Enum.sort(narrow(all, %{status_filters: ["in_progress", "blocked"]})) ==
               Enum.sort([a.id, b.id])
    end

    test "kind set", %{a: a, b: b, c: c} do
      all = [a, b, c]
      assert Enum.sort(narrow(all, %{kind_filters: []})) == Enum.sort([a.id, b.id, c.id])
      assert Enum.sort(narrow(all, %{kind_filters: ["bug", "chore"]})) == Enum.sort([a.id, c.id])
      assert narrow(all, %{kind_filters: ["feature"]}) == [b.id]
    end

    test "mine: sponsor or a user assignee in any phase", %{a: a, b: b, c: c, d: d} do
      all = [a, b, c, d]
      assert Enum.sort(narrow(all, %{mine_filter: true})) == Enum.sort([a.id, d.id])
    end

    test "sponsor :mine is sponsor only", %{a: a, d: d} do
      assert narrow([a, d], %{sponsor_filter: :mine}) == [a.id]
    end

    test "search and origin", %{a: a, b: b, c: c} do
      all = [a, b, c]
      assert narrow(all, %{task_search_query: " zePHyr "}) == [c.id]
      assert narrow(all, %{origin_filter: "external_feedback"}) == [c.id]
    end

    test "sort mode is applied", %{a: a, b: b, c: c} do
      assert narrow([a, b, c], %{board_sort: :oldest}) == [a.id, b.id, c.id]
      assert narrow([a, b, c], %{board_sort: :newest}) == [c.id, b.id, a.id]
    end
  end

  describe "org scope parity with BoardComponent's scope lens" do
    test ":all, nil and the root slug keep everything; any other org is empty today" do
      tasks = [t(1, %{}), t(2, %{status: "done"})]
      assert length(BoardData.narrow_list(tasks, %{scope_filter: :all}, ctx())) == 2
      assert length(BoardData.narrow_list(tasks, %{scope_filter: nil}, ctx())) == 2
      assert length(BoardData.narrow_list(tasks, %{scope_filter: "root"}, ctx())) == 2
      assert BoardData.narrow_list(tasks, %{scope_filter: "acme"}, ctx()) == []
    end
  end

  # ── Tasks.mine?/2 parity with list_my_open_tasks/2 ────────────────────

  defp u, do: System.unique_integer([:positive])

  defp user! do
    n = u()
    Repo.insert!(%User{email: "nf-#{n}@example.com", name: "NF #{n}", oidc_sub: "nf-#{n}"})
  end

  defp slot(id, type), do: %{"assignee_id" => id, "assignee_type" => type}

  defp seed(project, set) do
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "nf #{u()}"})
    {1, _} = Repo.update_all(from(t in Task, where: t.id == ^task.id), set: set)
    Repo.get!(Task, task.id)
  end

  describe "Tasks.mine?/2 parity with list_my_open_tasks/2" do
    setup do
      me = user!()
      other = user!()
      {:ok, p} = Tasks.create_project(%{name: "NF Proj #{u()}"})
      agent_id = Ecto.UUID.generate()

      rows = %{
        sponsored: seed(p, sponsor_user_id: me.id),
        flat_user: seed(p, assignee_id: me.id, assignee_type: "user"),
        slot_user:
          seed(p,
            assignee_id: agent_id,
            assignee_type: "agent",
            phase_assignees: %{"review" => slot(me.id, "user")}
          ),
        flat_agent_same_id: seed(p, assignee_id: me.id, assignee_type: "agent"),
        slot_agent_same_id: seed(p, phase_assignees: %{"planning" => slot(me.id, "agent")}),
        theirs: seed(p, sponsor_user_id: other.id),
        null_slot: seed(p, phase_assignees: %{"execution" => nil})
      }

      %{me: me, other: other, p: p, rows: rows}
    end

    test "same set on the same open rows", %{me: me, p: p, rows: rows} do
      open = Tasks.list_all_tasks(project_id: p.id)
      assert length(open) == map_size(rows), "every seeded row is loaded"

      in_memory = open |> Enum.filter(&Tasks.mine?(&1, me.id)) |> MapSet.new(& &1.id)
      queried = me.id |> Tasks.list_my_open_tasks() |> MapSet.new(& &1.id)

      assert in_memory == queried

      assert in_memory ==
               MapSet.new([rows.sponsored.id, rows.flat_user.id, rows.slot_user.id])
    end

    test "an agent assignee carrying the user's id is not mine", %{me: me, rows: rows} do
      assert Tasks.mine?(rows.flat_user, me.id), "positive control: the user-typed twin"
      refute Tasks.mine?(rows.flat_agent_same_id, me.id)
      refute Tasks.mine?(rows.slot_agent_same_id, me.id)
      refute rows.flat_agent_same_id.id in Enum.map(Tasks.list_my_open_tasks(me.id), & &1.id)
    end

    test "a nil user is never mine", %{rows: rows} do
      refute Tasks.mine?(rows.sponsored, nil)
      refute Tasks.mine?(%{sponsor_user_id: nil}, nil)
    end
  end
end
