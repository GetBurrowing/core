defmodule Platform.Responsibilities.Handlers.ArchitectureCronSweepTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.Handlers.ArchitectureCronSweep` —
  the Architect role bundle's weekly cron sweep handler (ADR-0044
  stage 5, task `019f3da3`).

  Firing is gated on the `architect` role assignee at the Router;
  `build_prompt/1` and `handle_output/3` always run to completion once
  the Router has resolved an assignee.
  """
  use Platform.DataCase, async: false

  alias Platform.Responsibilities.Handlers.ArchitectureCronSweep
  alias Platform.Responsibilities.Responsibility

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: ArchitectureCronSweep.key(),
      feature: "architecture",
      trigger_kind: "cron",
      trigger_config: %{"expression" => "0 4 * * 1"},
      scope: "per_project",
      context_provided: ["open_prs", "recent_closed_tasks", "adr_index"],
      enabled: true
    }
  end

  describe "register/0" do
    test "returns exactly one spec with the canonical key + feature" do
      specs = ArchitectureCronSweep.register()

      assert length(specs) == 1
      [spec] = specs

      assert spec.key == "architecture.cron_sweep"
      assert spec.feature == "architecture"
      assert spec.trigger_kind == "cron"
      assert spec.trigger_config == %{"expression" => "0 4 * * 1"}
      assert spec.scope == "per_project"

      assert spec.context_provided ==
               ["open_prs", "recent_closed_tasks", "adr_index"]

      assert spec.default_prompt_template == "architecture.cron_sweep.v1"
      assert spec.cost_profile == "low_freq_capable"
    end

    test "output_contract is a map of string values — satisfies the M1 schema invariant" do
      [spec] = ArchitectureCronSweep.register()

      Enum.each(spec.output_contract, fn {key, value} ->
        assert is_binary(key)
        assert is_binary(value), "#{inspect(key)}=#{inspect(value)} must be a string type name"
      end)
    end

    test "metadata flags the owner, active status, role, and ADR" do
      [spec] = ArchitectureCronSweep.register()

      assert spec.metadata["owner"] == "platform.architecture"
      # Stage 5 promotes the row from placeholder → active.
      assert spec.metadata["status"] == "active"
      assert spec.metadata["role"] == "architect"
      assert spec.metadata["adr"] == "0044"
      # No `opt_in_flag` key — firing is gated at the Router by the
      # assignee, not by a runtime env-var flag.
      refute Map.has_key?(spec.metadata, "opt_in_flag")
    end
  end

  describe "gather_context/2" do
    test "returns a map with all three declared context slots" do
      assert {:ok, ctx} = ArchitectureCronSweep.gather_context(responsibility(), %{})

      for slot <- [:open_prs, :recent_closed_tasks, :adr_index] do
        assert Map.has_key?(ctx, slot), "context should carry :#{slot}"
      end
    end

    test "recent_closed_tasks is a list" do
      {:ok, ctx} = ArchitectureCronSweep.gather_context(responsibility(), %{})
      assert is_list(ctx.recent_closed_tasks)
    end

    test "open_prs carries a missing? marker when gh is unavailable" do
      {:ok, ctx} = ArchitectureCronSweep.gather_context(responsibility(), %{})

      # Either the gh walk succeeded (list) or it fell back to the
      # missing? marker (map). Both are valid — the test only rejects a
      # crash.
      case ctx.open_prs do
        list when is_list(list) -> :ok
        %{missing?: true} -> :ok
        other -> flunk("unexpected open_prs shape: #{inspect(other)}")
      end
    end
  end

  describe "build_prompt/1" do
    test "returns {:ok, %{system:, user:}} with the architect system prompt" do
      {:ok, ctx} = ArchitectureCronSweep.gather_context(responsibility(), %{})

      assert {:ok, %{system: system, user: user}} = ArchitectureCronSweep.build_prompt(ctx)
      assert is_binary(system) and system != ""
      assert is_binary(user) and user != ""
      # System prompt names the architect role + the follow-up cap.
      assert system =~ "Architect"
      assert system =~ "follow-up"
    end
  end

  describe "handle_output/3 — files follow-ups" do
    setup do
      # Per-project scope: seed a project the handler files follow-ups
      # against. `trigger_meta.project_id` is what the Router hands the
      # handler at fire time.
      {:ok, project} =
        Platform.Tasks.create_project(%{
          name: "CronSweepTest Project #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/org/cron-sweep-test",
          tech_stack: %{"language" => "elixir"},
          deploy_config: %{"target" => "fly"}
        })

      {:ok, project: project}
    end

    test "files backlog tasks with the filed_by metadata marker", %{project: project} do
      output = %{
        "followups" => [
          %{
            "title" => "Land ADR-0044 stage-5 followup",
            "rationale" => "The weekly sweep found a doc gap.",
            "refs" => ["#488", "ADR-0044"]
          }
        ]
      }

      before_count = count_backlog_tasks()

      assert :ok =
               ArchitectureCronSweep.handle_output(
                 responsibility(),
                 output,
                 %{kind: :cron, project_id: project.id}
               )

      # Exactly one new backlog task.
      assert count_backlog_tasks() == before_count + 1

      task = latest_backlog_task()
      assert task.title =~ "[architect]"
      assert task.title =~ "Land ADR-0044 stage-5 followup"
      assert task.project_id == project.id
      assert task.metadata["filed_by"] == "architect_cron_sweep"
      assert task.metadata["adr"] == "0044"
      assert "#488" in task.metadata["refs"]
    end

    test "caps at 3 follow-ups even when the model returns 5", %{project: project} do
      output = %{
        "followups" =>
          for(
            n <- 1..5,
            do: %{
              "title" => "Followup #{n}",
              "rationale" => "auto",
              "refs" => ["#100"]
            }
          )
      }

      before_count = count_backlog_tasks()

      assert :ok =
               ArchitectureCronSweep.handle_output(
                 responsibility(),
                 output,
                 %{kind: :cron, project_id: project.id}
               )

      assert count_backlog_tasks() == before_count + 3
    end

    test "skips follow-ups with empty titles", %{project: project} do
      output = %{
        "followups" => [
          %{"title" => "", "rationale" => "empty title"},
          %{"title" => "Valid one", "rationale" => "yes", "refs" => ["#1"]}
        ]
      }

      before_count = count_backlog_tasks()

      assert :ok =
               ArchitectureCronSweep.handle_output(
                 responsibility(),
                 output,
                 %{kind: :cron, project_id: project.id}
               )

      assert count_backlog_tasks() == before_count + 1
    end

    test "falls back to the first project when trigger_meta lacks project_id", %{project: project} do
      output = %{
        "followups" => [
          %{
            "title" => "No project_id in trigger_meta",
            "rationale" => "fallback path",
            "refs" => ["ADR-0044"]
          }
        ]
      }

      before_count = count_backlog_tasks()

      assert :ok =
               ArchitectureCronSweep.handle_output(
                 responsibility(),
                 output,
                 %{kind: :cron}
               )

      assert count_backlog_tasks() == before_count + 1

      task = latest_backlog_task()
      # Falls back to the earliest-inserted project — the one this
      # setup block seeded.
      assert task.project_id == project.id
    end
  end

  describe "handle_output/2 delegates to arity-3" do
    test "arity-2 no-ops when the followups list is empty" do
      before_count = count_backlog_tasks()

      assert :ok = ArchitectureCronSweep.handle_output(responsibility(), %{"followups" => []})

      # No follow-ups → no filed tasks. Exercises the arity-2 →
      # arity-3 delegation path without needing a project seed.
      assert count_backlog_tasks() == before_count
    end
  end

  describe "key/0 and template_slug/0" do
    test "key/0 matches the registered spec key" do
      [spec] = ArchitectureCronSweep.register()
      assert ArchitectureCronSweep.key() == spec.key
      assert ArchitectureCronSweep.key() == "architecture.cron_sweep"
    end

    test "template_slug/0 matches the registered default_prompt_template" do
      [spec] = ArchitectureCronSweep.register()
      assert ArchitectureCronSweep.template_slug() == spec.default_prompt_template
      assert ArchitectureCronSweep.template_slug() == "architecture.cron_sweep.v1"
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp count_backlog_tasks do
    Repo.aggregate(
      from(t in Platform.Tasks.Task,
        where:
          t.status == "backlog" and
            fragment("(?->>'filed_by') = ?", t.metadata, "architect_cron_sweep")
      ),
      :count,
      :id
    )
  rescue
    _ -> 0
  end

  defp latest_backlog_task do
    Repo.one(
      from(t in Platform.Tasks.Task,
        where:
          t.status == "backlog" and
            fragment("(?->>'filed_by') = ?", t.metadata, "architect_cron_sweep"),
        order_by: [desc: t.inserted_at],
        limit: 1
      )
    )
  end
end
