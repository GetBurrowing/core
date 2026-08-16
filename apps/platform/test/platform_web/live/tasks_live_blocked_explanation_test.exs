defmodule PlatformWeb.TasksLiveBlockedExplanationTest do
  @moduledoc """
  Read-side coverage for the blocked-explanation helpers on
  `PlatformWeb.TasksLive` (task 01a004ad, stage 2).

  `Tasks.stamp_blocked_reason/2` (stage 1) writes a human sentence to
  `metadata["blocked_reason"]` plus an ISO-8601 `metadata["blocked_reason_at"]`.
  Nothing read it. `blocked_explanation/1` is the single dispatcher the
  detail panel will call in stage 3; these tests pin its contract before a
  template ever depends on it.

  The precedence rule is the load-bearing assertion: when a task carries
  BOTH an escalation sentence and unmet dependency ids, the sentence wins.
  A watchdog-exhausted task needs a person; a dependency-parked one clears
  itself when its blockers finish. Collapsing those two into one branch
  would send the first case to the wrong reader.

  The card-face count badge (`unmet_dependency_count/1`, rendered at
  `tasks_live.html.heex`) must be untouched by this addition, so one test
  asserts it still returns the dependency count for a task that ALSO
  carries `blocked_reason` — i.e. precisely the task whose explanation the
  new dispatcher routes away from the dependency branch.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks}
  alias PlatformWeb.TasksLive

  defp authenticated_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "tasks-blocked-explanation-#{n}@example.com",
        name: "Blocked Explanation User #{n}",
        oidc_sub: "oidc-tasks-blocked-explanation-#{n}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Blocked Explanation Project"})
    %{project: project}
  end

  defp task_with(project, attrs) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{project_id: project.id, title: "Subject", status: "blocked"},
          attrs
        )
      )

    task
  end

  describe "blocked_reason/1" do
    test "returns the trimmed sentence", %{project: project} do
      task =
        task_with(project, %{metadata: %{"blocked_reason" => "  Executor never acked.  "}})

      assert TasksLive.blocked_reason(task) == "Executor never acked."
    end

    test "reads absent, non-binary, empty and whitespace-only as nil", %{project: project} do
      assert TasksLive.blocked_reason(task_with(project, %{metadata: %{}})) == nil

      assert TasksLive.blocked_reason(task_with(project, %{metadata: %{"blocked_reason" => ""}})) ==
               nil

      assert TasksLive.blocked_reason(
               task_with(project, %{metadata: %{"blocked_reason" => "   \n\t "}})
             ) == nil

      assert TasksLive.blocked_reason(
               task_with(project, %{metadata: %{"blocked_reason" => %{"nested" => "map"}}})
             ) == nil
    end

    test "returns nil for a non-task term" do
      assert TasksLive.blocked_reason(nil) == nil
      assert TasksLive.blocked_reason(%{metadata: %{"blocked_reason" => "not a task"}}) == nil
    end
  end

  describe "blocked_reason_at/1" do
    test "parses an ISO-8601 stamp into a DateTime", %{project: project} do
      task =
        task_with(project, %{
          metadata: %{
            "blocked_reason" => "Safety-net exceeded.",
            "blocked_reason_at" => "2026-08-15T17:03:44Z"
          }
        })

      assert %DateTime{} = at = TasksLive.blocked_reason_at(task)
      assert DateTime.to_iso8601(at) == "2026-08-15T17:03:44Z"
    end

    test "returns nil — not the epoch — for an unparseable stamp", %{project: project} do
      task =
        task_with(project, %{
          metadata: %{
            "blocked_reason" => "Safety-net exceeded.",
            "blocked_reason_at" => "yesterday afternoon"
          }
        })

      assert TasksLive.blocked_reason_at(task) == nil
    end

    test "returns nil for absent and non-binary stamps", %{project: project} do
      assert TasksLive.blocked_reason_at(task_with(project, %{metadata: %{}})) == nil

      assert TasksLive.blocked_reason_at(
               task_with(project, %{metadata: %{"blocked_reason_at" => 1_755_000_000}})
             ) == nil
    end
  end

  describe "blocked_explanation/1" do
    test "returns {:reason, sentence, at} when a reason is stamped", %{project: project} do
      task =
        task_with(project, %{
          metadata: %{
            "blocked_reason" => "Executor never acked the dispatch.",
            "blocked_reason_at" => "2026-08-15T17:03:44Z"
          }
        })

      assert {:reason, "Executor never acked the dispatch.", %DateTime{} = at} =
               TasksLive.blocked_explanation(task)

      assert DateTime.to_iso8601(at) == "2026-08-15T17:03:44Z"
    end

    test "returns {:reason, sentence, nil} when the timestamp is missing", %{project: project} do
      task = task_with(project, %{metadata: %{"blocked_reason" => "No stamp here."}})

      assert {:reason, "No stamp here.", nil} = TasksLive.blocked_explanation(task)
    end

    test "returns {:dependencies, rows} from the existing resolver", %{project: project} do
      upstream = task_with(project, %{title: "Upstream", status: "in_progress"})

      task =
        task_with(project, %{
          title: "Downstream",
          dependencies: [%{"task_id" => upstream.id, "kind" => "blocks"}],
          metadata: %{"unmet_dependencies" => [upstream.id]}
        })

      assert {:dependencies, rows} = TasksLive.blocked_explanation(task)
      assert [%{id: id, title: "Upstream", status: "in_progress"}] = rows
      assert id == upstream.id
    end

    test "prefers the reason over dependencies when BOTH are present", %{project: project} do
      upstream = task_with(project, %{title: "Upstream", status: "in_progress"})

      task =
        task_with(project, %{
          title: "Downstream",
          dependencies: [%{"task_id" => upstream.id, "kind" => "blocks"}],
          metadata: %{
            "blocked_reason" => "Watchdog exhausted after three dispatches.",
            "unmet_dependencies" => [upstream.id]
          }
        })

      # Not a smoke test: the dependency branch is fully satisfiable here
      # (the previous test proves it fires on exactly this metadata minus
      # the sentence), so a precedence inversion would return
      # {:dependencies, _} and detonate this assertion.
      assert {:reason, "Watchdog exhausted after three dispatches.", nil} =
               TasksLive.blocked_explanation(task)
    end

    test "returns :none for a blocked task with neither signal", %{project: project} do
      assert TasksLive.blocked_explanation(task_with(project, %{metadata: %{}})) == :none
    end

    test "returns :none for a blank reason with no dependencies", %{project: project} do
      task = task_with(project, %{metadata: %{"blocked_reason" => "   "}})

      assert TasksLive.blocked_explanation(task) == :none
    end

    test "returns :none for every non-blocked status, whatever the metadata says", %{
      project: project
    } do
      for status <- ~w(backlog planning in_progress in_review deploying done) do
        task =
          task_with(project, %{
            status: status,
            metadata: %{
              "blocked_reason" => "Stale sentence from an earlier escalation.",
              "unmet_dependencies" => [Ecto.UUID.generate()]
            }
          })

        assert TasksLive.blocked_explanation(task) == :none,
               "status #{status} must explain nothing, but returned " <>
                 inspect(TasksLive.blocked_explanation(task))
      end
    end

    test "returns :none for a non-task term" do
      assert TasksLive.blocked_explanation(nil) == :none
    end
  end

  describe "the card-face dependency badge is unaffected" do
    test "the board still renders 'Blocked · 3' for a task that ALSO carries blocked_reason",
         %{conn: conn, project: project} do
      ids = [Ecto.UUID.generate(), Ecto.UUID.generate(), Ecto.UUID.generate()]

      task =
        task_with(project, %{
          title: "Badge Subject",
          metadata: %{
            "blocked_reason" => "Watchdog exhausted.",
            "unmet_dependencies" => ids
          }
        })

      {:ok, _view, html} = live(authenticated_conn(conn), ~p"/tasks")

      # The badge reads `unmet_dependency_count/1` directly. The new
      # dispatcher routes THIS task to {:reason, _, _} — the badge must be
      # indifferent to that and still show all three.
      badges =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([title="Waiting on dependencies"]))
        |> LazyHTML.text()

      assert badges =~ "Blocked · 3"
      assert {:reason, "Watchdog exhausted.", nil} = TasksLive.blocked_explanation(task)
    end
  end

  # The whole point of the defect is that a careful sentence was written and
  # never shown. The render assertions below therefore compare the rendered
  # text to the WHOLE sentence by equality, not by `=~`: a substring
  # assertion passes just as happily against a clamped or truncated value,
  # which is the exact regression the design direction forbids.
  defp explanation_nodes(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="blocked-explanation"]))
  end

  defp explanation_text(html, selector) do
    html
    |> explanation_nodes()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end

  @watchdog "Stage 2 was dispatched 3 times over 47 minutes and never acked. Automatic retry is exhausted; the last attempt re-queued the executor before giving up."

  describe "the detail panel renders the explanation (stage 3)" do
    test "renders the watchdog sentence in full, unclamped", %{conn: conn, project: project} do
      task =
        task_with(project, %{
          title: "Watchdog Subject",
          metadata: %{
            "blocked_reason" => @watchdog,
            "blocked_reason_at" => "2026-08-15T09:00:00Z"
          }
        })

      {:ok, _view, html} = live(authenticated_conn(conn), ~p"/tasks?task_id=#{task.id}")

      # Equality, not containment: the final clause names what was already
      # retried automatically, and that is the clause a line-clamp drops.
      assert explanation_text(html, "p") == @watchdog

      assert explanation_text(html, "span") =~ "Why this is blocked"

      # No clamping utilities may reach the sentence element.
      #
      # Stage 4 mutation probe: the earlier form of this check was
      # `refute block_html =~ "truncate\""` over the whole block's HTML. It
      # was written that way to tolerate the legitimate `truncate flex-1` on
      # the dependency rows, and in doing so it only saw a `truncate` that
      # happened to sit LAST in a class attribute. A mutant that wrote
      # `class="text-sm truncate text-base-content"` on the sentence
      # survived it with 23/23 green. Tokenise the sentence element's own
      # class list instead: position-independent, and scoped so the
      # dependency rows keep their `truncate` without weakening this.
      #
      # Note the text-equality assertion above CANNOT stand in for this.
      # Clamping is CSS-only — the server still renders the whole sentence
      # into the DOM, so `explanation_text(html, "p") == @watchdog` is green
      # under every clamp. The class check is the only observable that
      # separates the two states.
      sentence_classes =
        html
        |> explanation_nodes()
        |> LazyHTML.query("p")
        |> LazyHTML.attribute("class")
        |> Enum.flat_map(&String.split(&1, ~r/\s+/, trim: true))

      assert "text-sm" in sentence_classes, "the sentence element was not found"

      for clamp <- sentence_classes do
        refute clamp == "truncate",
               "the sentence must wrap freely; got classes #{inspect(sentence_classes)}"

        refute String.starts_with?(clamp, "line-clamp"),
               "the sentence must wrap freely; got classes #{inspect(sentence_classes)}"
      end

      # The dependency branch must not co-render.
      refute explanation_text(html, "p") =~ "nothing is needed from you"
    end

    test "renders the timestamp only when blocked_reason_at parsed", %{
      conn: conn,
      project: project
    } do
      garbled =
        task_with(project, %{
          title: "Garbled Stamp Subject",
          metadata: %{
            "blocked_reason" => @watchdog,
            "blocked_reason_at" => "not-a-timestamp"
          }
        })

      {:ok, _view, html} = live(authenticated_conn(conn), ~p"/tasks?task_id=#{garbled.id}")

      assert explanation_text(html, "p") == @watchdog
      assert TasksLive.blocked_reason_at(garbled) == nil

      # Only the label span survives; no timestamp line is emitted.
      spans =
        html
        |> explanation_nodes()
        |> LazyHTML.query("span")
        |> LazyHTML.to_tree()

      assert length(spans) == 1
    end

    test "renders the dependency copy including the 'nothing is needed from you' clause",
         %{conn: conn, project: project} do
      dep_a = task_with(project, %{title: "Make the registration land", status: "done"})

      dep_b =
        task_with(project, %{title: "Stop reporting a phantom grant", status: "in_progress"})

      task =
        task_with(project, %{
          title: "Dependency Subject",
          dependencies: [
            %{"task_id" => dep_a.id, "kind" => "blocks"},
            %{"task_id" => dep_b.id, "kind" => "blocks"}
          ],
          metadata: %{"unmet_dependencies" => [dep_a.id, dep_b.id]}
        })

      {:ok, _view, html} = live(authenticated_conn(conn), ~p"/tasks?task_id=#{task.id}")

      # The clause is the whole reason this copy exists: readers supply
      # "someone do something" from the word Blocked alone, and for this
      # population that is false.
      assert explanation_text(html, "p") ==
               "Waiting on 2 tasks. This clears itself when they finish; nothing is needed from you."

      rows = html |> explanation_nodes() |> LazyHTML.query("li") |> LazyHTML.text()
      assert rows =~ "Make the registration land"
      assert rows =~ "Stop reporting a phantom grant"
    end

    test "singularises the dependency copy for exactly one blocker", %{
      conn: conn,
      project: project
    } do
      dep = task_with(project, %{title: "The only blocker", status: "in_progress"})

      task =
        task_with(project, %{
          title: "Single Dependency Subject",
          dependencies: [%{"task_id" => dep.id, "kind" => "blocks"}],
          metadata: %{"unmet_dependencies" => [dep.id]}
        })

      {:ok, _view, html} = live(authenticated_conn(conn), ~p"/tasks?task_id=#{task.id}")

      assert explanation_text(html, "p") ==
               "Waiting on 1 task. This clears itself when it finishes; nothing is needed from you."
    end

    test "renders nothing when metadata lists unmet ids the dependencies field never recorded",
         %{conn: conn, project: project} do
      # `unmet_dependency_count/1` counts metadata ids; `dependency_summary/1`
      # resolves the `dependencies` FIELD. They can disagree, and when they
      # do `blocked_explanation/1` returns `{:dependencies, []}` — a branch
      # that would otherwise print "Waiting on 0 tasks".
      task =
        task_with(project, %{
          title: "Phantom Dependency Subject",
          metadata: %{"unmet_dependencies" => [Ecto.UUID.generate()]}
        })

      assert TasksLive.blocked_explanation(task) == {:dependencies, []}

      {:ok, _view, html} = live(authenticated_conn(conn), ~p"/tasks?task_id=#{task.id}")

      assert explanation_nodes(html) |> LazyHTML.to_tree() == []
      refute html =~ "Waiting on 0 tasks"
      assert html =~ "Phantom Dependency Subject"
    end

    test "never renders both branches: a task carrying BOTH signals shows only the sentence",
         %{conn: conn, project: project} do
      dep = task_with(project, %{title: "A dependency that must stay hidden", status: "done"})

      task =
        task_with(project, %{
          title: "Both Signals Subject",
          dependencies: [%{"task_id" => dep.id, "kind" => "blocks"}],
          metadata: %{
            "blocked_reason" => @watchdog,
            "unmet_dependencies" => [dep.id]
          }
        })

      # Anti-vacuity: the dependency branch is fully satisfiable on this
      # task minus the sentence, so the refutes below are about precedence
      # and not about an unresolvable dependency.
      assert {:dependencies, [_]} =
               TasksLive.blocked_explanation(%{
                 task
                 | metadata: %{"unmet_dependencies" => [dep.id]}
               })

      {:ok, _view, html} = live(authenticated_conn(conn), ~p"/tasks?task_id=#{task.id}")

      assert explanation_text(html, "p") == @watchdog

      # Two independent refutes, one per side of the dependency branch —
      # the copy AND the rows — so neither can vanish vacuously.
      block_text = html |> explanation_nodes() |> LazyHTML.text()
      refute block_text =~ "nothing is needed from you"
      refute block_text =~ "A dependency that must stay hidden"

      assert html |> explanation_nodes() |> LazyHTML.query("li") |> LazyHTML.to_tree() == []
    end

    test "a non-blocked task renders no blocked-explanation node at all", %{
      conn: conn,
      project: project
    } do
      task =
        task_with(project, %{
          title: "Running Subject",
          status: "in_progress",
          metadata: %{
            "blocked_reason" => @watchdog,
            "unmet_dependencies" => [Ecto.UUID.generate()]
          }
        })

      {:ok, _view, html} = live(authenticated_conn(conn), ~p"/tasks?task_id=#{task.id}")

      # `LazyHTML.query/2` returns a struct, so `== []` on it is always
      # false — compare the materialised tree instead.
      assert explanation_nodes(html) |> LazyHTML.to_tree() == []
      refute html =~ ~s(data-role="blocked-explanation")

      # Anti-vacuity: the panel really did open on this task.
      assert html =~ "Running Subject"
    end

    test "a blocked task with neither signal renders no node and no placeholder", %{
      conn: conn,
      project: project
    } do
      task = task_with(project, %{title: "Bare Blocked Subject", metadata: %{}})

      {:ok, _view, html} = live(authenticated_conn(conn), ~p"/tasks?task_id=#{task.id}")

      assert explanation_nodes(html) |> LazyHTML.to_tree() == []
      refute html =~ "Why this is blocked"
      refute html =~ "no reason recorded"
      assert html =~ "Bare Blocked Subject"
    end
  end
end
