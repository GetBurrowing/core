defmodule Platform.Responsibilities.Handlers.DesignCritiqueReturnTest do
  @moduledoc """
  The return path for a `design.critique` job held by a native or federated
  Designer (a Claude Code runtime). Task 01a1eb2f.

  The Router sends such an agent a one-way signal, so its reply never
  reaches `handle_output/3`; the synchronous `design_critique_request` tool
  used to refuse it outright. Covered here:

    * `design_critique_request` against a native Designer dispatches, and the
      prompt names `design_critique_complete` and a signed `critique_ref`;
    * the tool lands the verdict on the review request named at request
      time, through `Critique.land_verdict/2`;
    * a forged ref, the wrong caller and malformed issues land nothing;
    * an external Designer's prompt carries no return block.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.DesignCritique
  alias Platform.Roles
  alias Platform.Tasks
  alias Platform.Tasks.ReviewRequests

  @capture_key :design_critique_return_capture_pid
  @probe "Primary action hidden below the fold"

  defmodule CaptureDispatcher do
    @moduledoc false
    def maybe_dispatch(signal) do
      pid = Application.get_env(:platform, :design_critique_return_capture_pid)
      if is_pid(pid), do: send(pid, {:captured_signal, signal})
      :ok
    end
  end

  setup do
    Application.put_env(:platform, @capture_key, self())

    Application.put_env(
      :platform,
      :responsibility_router_native_dispatcher,
      {CaptureDispatcher, :maybe_dispatch}
    )

    on_exit(fn ->
      Application.delete_env(:platform, @capture_key)
      Application.delete_env(:platform, :responsibility_router_native_dispatcher)
    end)

    [spec] = DesignCritique.register()
    {:ok, _row} = Responsibilities.upsert_by_key(spec)

    designer = native_agent!("designer")
    {:ok, _} = Roles.set_override(DesignCritique.key(), designer.id)

    task = task!()
    request = review_request!(task)
    canvas = canvas!()

    %{designer: designer, task: task, request: request, canvas: canvas}
  end

  defp native_agent!(slug) do
    %Agent{}
    |> Agent.changeset(%{
      slug: "#{slug}-#{System.unique_integer([:positive])}",
      name: "Critique Return",
      status: "active",
      kind: "native",
      runtime_type: "external"
    })
    |> Repo.insert!()
  end

  defp task! do
    {:ok, project} = Tasks.create_project(%{name: "Critique Return"})

    Repo.insert!(
      Ecto.Changeset.change(%Platform.Tasks.Task{}, %{
        project_id: project.id,
        title: "Checkout polish",
        status: "in_progress",
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      })
    )
  end

  defp review_request!(task) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "UI"})
    {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

    {:ok, request} =
      ReviewRequests.create_review_request(%{
        validation_id: validation.id,
        task_id: task.id,
        items: [%{label: "Desktop screenshot", content: "evidence"}]
      })

    request
  end

  defp canvas! do
    n = System.unique_integer([:positive])
    {:ok, space} = Chat.create_space(%{name: "cr-#{n}", slug: "cr-#{n}", kind: "channel"})
    {:ok, participant} = ExecutionSpace.ensure_system_participant(space.id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        space_id: space.id,
        created_by: participant.id,
        title: "Checkout",
        document: %{
          "version" => 1,
          "revision" => 1,
          "root" => %{
            "id" => "root",
            "type" => "stack",
            "children" => [
              %{"id" => "n", "type" => "markdown", "props" => %{"content" => @probe}}
            ]
          }
        }
      })

    canvas
  end

  defp request_critique(canvas, task, request) do
    reviewer = native_agent!("reviewer")

    capture_log(fn ->
      send(
        self(),
        {:result,
         ToolSurface.execute(
           "design_critique_request",
           %{
             "canvas_id" => canvas.id,
             "task_id" => task.id,
             "review_request_id" => request.id
           },
           %{agent: reviewer, agent_id: reviewer.id}
         )}
      )
    end)

    assert_receive {:result, result}
    result
  end

  defp ref_from(prompt) do
    [_, ref] = Regex.run(~r/critique_ref="([^"]+)"/, prompt)
    ref
  end

  defp item_contents(request) do
    request.id
    |> ReviewRequests.get_review_request()
    |> Map.fetch!(:items)
    |> Enum.map(& &1.content)
  end

  test "a native Designer is dispatched and its returned verdict lands on the review request",
       %{designer: designer, canvas: canvas, task: task, request: request} do
    assert {:ok, %{pending: true, issues: [], review_item_id: nil}} =
             request_critique(canvas, task, request)

    assert_receive {:captured_signal, signal}, 2_000
    prompt = signal.metadata.prompt
    assert prompt =~ @probe
    assert prompt =~ "design_critique_complete"
    ref = ref_from(prompt)

    assert {:ok, %{landed: true, issues: 1, review_item_id: item_id}} =
             ToolSurface.execute(
               "design_critique_complete",
               %{
                 "critique_ref" => ref,
                 "issues" => [
                   %{
                     "severity" => "major",
                     "location" => "checkout footer",
                     "issue" => "The pay button sits below the fold",
                     "suggestion" => "Pin it to the bottom bar"
                   }
                 ]
               },
               %{agent: designer}
             )

    assert is_binary(item_id)
    assert Enum.any?(item_contents(request), &(&1 =~ "The pay button sits below the fold"))
  end

  test "refusals land nothing", %{
    designer: designer,
    canvas: canvas,
    task: task,
    request: request
  } do
    {:ok, _} = request_critique(canvas, task, request)
    assert_receive {:captured_signal, signal}, 2_000
    ref = ref_from(signal.metadata.prompt)
    before = item_contents(request)

    stranger = native_agent!("stranger")
    issues = [%{"issue" => "x"}]

    assert {:error, %{code: :not_critique_assignee}} =
             ToolSurface.execute(
               "design_critique_complete",
               %{"critique_ref" => ref, "issues" => issues},
               %{agent: stranger}
             )

    assert {:error, %{code: :invalid_critique_ref}} =
             ToolSurface.execute(
               "design_critique_complete",
               %{"critique_ref" => ref <> "x", "issues" => issues},
               %{agent: designer}
             )

    assert {:error, %{code: :invalid_issues, recoverable: true}} =
             ToolSurface.execute(
               "design_critique_complete",
               %{"critique_ref" => ref, "issues" => "looks fine"},
               %{agent: designer}
             )

    assert {:error, %{code: :unauthorized}} =
             ToolSurface.execute(
               "design_critique_complete",
               %{"critique_ref" => ref, "issues" => issues},
               %{}
             )

    assert item_contents(request) == before
  end

  test "an external Designer's prompt carries no return block", %{canvas: canvas} do
    {:ok, context} =
      DesignCritique.gather_context(%Responsibilities.Responsibility{}, %{canvas_id: canvas.id})

    {:ok, %{user: external}} =
      DesignCritique.build_prompt(Map.put(context, :agent_kind, :ext_single_responsibility))

    refute external =~ "design_critique_complete"

    {:ok, %{user: native}} =
      DesignCritique.build_prompt(Map.put(context, :agent_kind, :fed_conversational))

    assert native =~ "design_critique_complete"
  end
end
