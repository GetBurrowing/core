defmodule Platform.Chat.Canvas.CrossTenantReadTest do
  @moduledoc """
  Cross-tenant denial for the two canvas READS on the agent tool surface —
  `canvas_describe` and `canvas_versions` (task 019fb01b stage 3).

  Separate from `ToolHandlersTest` and `VersionHandlersTest` because those are
  organized by handler, and the property under test here is not a property of
  either handler. It is that the two of them answer the SAME way, for every
  shape of space a canvas can live in, to a caller from somewhere else. A hole
  in one and not the other is precisely the state stage 3 ends: `describe`
  ignored its context entirely, `versions` fell open on a nil `agent_id`, so one
  question had two answers depending on which door you knocked on.

  Every case runs through both reads from one list. A third canvas read means
  one entry, and the cross-tenant cases arrive with it rather than being
  remembered.

  ## The three shapes, and why each is here

    * CHANNEL in another org. `:org_reader` reaches channel canvases, so this is
      the shape where a grant exists and the question is whether it is scoped.
      It is also the only shape where a wrong answer leaks between customers.
    * DM (`org_id` nil, `kind` not "channel"). No org-derived grant can reach it
      by construction, so this pins that the handlers do not invent one.
    * EXECUTION space. Closed to org reach entirely, reachable only through
      space participation or a task binding. The shape the incident that opened
      this task was about.

  Plus the nil-`agent_id` context, which is a caller shape rather than a space
  shape: `agent_id` is a nullable `:binary_id` on `Platform.Agents.AgentRuntime`
  (agent_runtime.ex:24), so an authenticated runtime with no linked agent
  reaches these handlers, and until this stage it read anything.

  The two positive controls are deliberate. A regression module made only of
  denials passes just as well against a handler that denies everyone, which is a
  different bug with identical test output.
  """

  use Platform.DataCase, async: false

  import Platform.ExternalUserFixtures, except: [canvas!: 2]

  alias Ecto.UUID
  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.Canvas.ToolHandlers
  alias Platform.Chat.Canvas.VersionHandlers
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachments
  alias Platform.Tenancy

  @reads ["canvas_describe", "canvas_versions"]

  setup do
    %{org_a: Tenancy.get_org_by_slug!("sxi"), org_b: Tenancy.get_org_by_slug!("soylent")}
  end

  # Both reads behind one call, so no case can be written for one and quietly
  # skipped for the other.
  defp read("canvas_describe", args, context), do: ToolHandlers.describe(args, context)
  defp read("canvas_versions", args, context), do: VersionHandlers.versions(args, context)

  # ── Builders ──────────────────────────────────────────────────────────────

  defp space!(attrs) do
    n = System.unique_integer([:positive, :monotonic])
    default = %{name: "XT Space #{n}", slug: "xt-space-#{n}", kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  # The author is a throwaway user in the space, distinct from every caller
  # under test. An author who happened to be the caller would hand the case a
  # free `:member` grant and the denial would prove nothing.
  defp canvas!(space) do
    author = add_user!(space.id, create_user!().id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => author.id,
        "title" => "Merger Terms #{System.unique_integer([:positive])}"
      })

    canvas
  end

  defp task_in!(org) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "XT Project #{System.unique_integer([:positive])}",
        org_id: org.id
      })

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "XT Task"})
    task
  end

  defp attach!(task, canvas) do
    {:ok, _attachment} =
      CanvasAttachments.attach_canvas(:system, task.id, canvas.id,
        attached_by: %{kind: "user", id: UUID.generate()}
      )

    :ok
  end

  # An agent that exists and is rostered somewhere, just not anywhere touching
  # the canvas under test. A caller with no rows at all would be the weaker
  # case: it could be denied by accident.
  defp outsider_agent!(org) do
    agent_id = UUID.generate()
    add_agent!(space!(%{org_id: org.id}).id, agent_id)
    agent_id
  end

  # The exact shape `PlatformWeb.MCPController.build_context/2` and
  # `PlatformWeb.RuntimeChannel.execute_tool_call/4` construct.
  defp federation_context(space_id, agent_id, participant_id \\ nil) do
    %{
      space_id: space_id,
      agent_id: agent_id,
      agent_participant_id: participant_id,
      runtime_id: "runtime-#{System.unique_integer([:positive])}"
    }
  end

  defp assert_denied(payload, canvas) do
    assert payload.recoverable == false
    assert payload.error =~ ~r/access/i
    refute payload.error =~ "not found"

    refute Map.has_key?(payload, :document)
    refute Map.has_key?(payload, :versions)
    refute Map.has_key?(payload, :space_id)
    refute Map.has_key?(payload, :title)

    # Nothing about the canvas beyond the id the caller already had.
    serialized = inspect(payload)
    refute serialized =~ canvas.title
    refute serialized =~ canvas.space_id
  end

  # ── 1. Another org's channel canvas ───────────────────────────────────────

  describe "an agent whose only roster is in another org" do
    setup %{org_a: org_a, org_b: org_b} do
      %{canvas: canvas!(space!(%{org_id: org_a.id})), agent_id: outsider_agent!(org_b)}
    end

    for tool <- @reads do
      @tool tool

      test "#{tool} denies it org A's channel canvas", %{canvas: canvas, agent_id: agent_id} do
        assert {:error, payload} =
                 read(@tool, %{"canvas_id" => canvas.id}, federation_context(nil, agent_id))

        assert_denied(payload, canvas)
      end
    end

    # The org B agent supplying its OWN space_id must not shift the answer. The
    # handlers resolve the canvas from `canvas_id` and ask the membership
    # question about the canvas's space, never about the context's.
    test "a context carrying the caller's own space_id does not help", %{
      canvas: canvas,
      agent_id: agent_id,
      org_b: org_b
    } do
      own_space = space!(%{org_id: org_b.id})
      participant = add_agent!(own_space.id, agent_id)
      context = federation_context(own_space.id, agent_id, participant.id)

      for tool <- @reads do
        assert {:error, payload} = read(tool, %{"canvas_id" => canvas.id}, context)
        assert_denied(payload, canvas)
      end
    end
  end

  # ── 2. A DM canvas ────────────────────────────────────────────────────────

  describe "a DM canvas and a non-participant" do
    setup %{org_a: org_a} do
      # `org_id` is nil on a DM, so no org-derived grant can reach it. The
      # caller is an agent in the same org as the DM's humans, which is the
      # closest an outsider legitimately gets.
      canvas = canvas!(space!(%{kind: "dm", org_id: nil, is_direct: true}))
      %{canvas: canvas, agent_id: outsider_agent!(org_a)}
    end

    for tool <- @reads do
      @tool tool

      test "#{tool} denies it", %{canvas: canvas, agent_id: agent_id} do
        assert {:error, payload} =
                 read(@tool, %{"canvas_id" => canvas.id}, federation_context(nil, agent_id))

        assert_denied(payload, canvas)
      end
    end
  end

  # ── 3. An execution-space canvas ──────────────────────────────────────────

  describe "an execution-space canvas and an agent bound to neither roster nor task" do
    setup %{org_a: org_a} do
      canvas = canvas!(space!(%{kind: "execution", org_id: nil}))
      task = task_in!(org_a)
      attach!(task, canvas)

      %{canvas: canvas, task: task, agent_id: outsider_agent!(org_a)}
    end

    for tool <- @reads do
      @tool tool

      test "#{tool} denies it", %{canvas: canvas, agent_id: agent_id} do
        assert {:error, payload} =
                 read(@tool, %{"canvas_id" => canvas.id}, federation_context(nil, agent_id))

        assert_denied(payload, canvas)
      end
    end

    # The control that makes the denials above mean something: same canvas,
    # same execution space, an agent that IS bound to the attached task through
    # `phase_assignees` (the `:task_agent` grant, stage 2). Were this to fail,
    # the denials would be evidence of a handler that refuses everyone.
    test "but the task's own phase_assignees agent reads both", %{canvas: canvas, task: task} do
      bound_agent_id = UUID.generate()

      {:ok, _task} =
        Tasks.set_phase_assignees(task, %{
          "planning" => %{"assignee_id" => bound_agent_id, "assignee_type" => "agent"}
        })

      on_exit(fn -> CanvasServer.stop(canvas.id) end)
      context = federation_context(nil, bound_agent_id)

      assert {:ok, described} = ToolHandlers.describe(%{"canvas_id" => canvas.id}, context)
      assert described.canvas_id == canvas.id
      assert is_map(described.document)

      assert {:ok, listed} = VersionHandlers.versions(%{"canvas_id" => canvas.id}, context)
      assert is_list(listed.versions)
    end
  end

  # ── 4. A runtime with no linked agent ─────────────────────────────────────

  describe "a context with a nil agent_id" do
    setup %{org_a: org_a} do
      %{canvas: canvas!(space!(%{org_id: org_a.id}))}
    end

    for tool <- @reads do
      @tool tool

      test "#{tool} denies it", %{canvas: canvas} do
        assert {:error, payload} =
                 read(
                   @tool,
                   %{"canvas_id" => canvas.id},
                   federation_context(canvas.space_id, nil)
                 )

        assert_denied(payload, canvas)
      end
    end

    # A nil agent_id must not be rescued by anything else in the context: not
    # the space_id, not the runtime_id, and above all not `owner_user_id`, which
    # would hand a remote process its human owner's org-wide reach.
    test "an empty context is denied identically to a nil-agent one", %{canvas: canvas} do
      for tool <- @reads do
        assert {:error, from_empty} = read(tool, %{"canvas_id" => canvas.id}, %{})

        assert {:error, from_nil} =
                 read(
                   tool,
                   %{"canvas_id" => canvas.id},
                   federation_context(canvas.space_id, nil)
                 )

        assert from_empty == from_nil
      end
    end
  end

  # ── 5. The shapes are indistinguishable from outside ──────────────────────

  describe "denial payloads across space shapes" do
    # The e2e script for this task asserts this in a dev environment. Pinning it
    # here means a later edit to one handler's denial sentence cannot make the
    # shapes distinguishable without a red test first.
    test "one caller gets identical denials apart from the canvas id", %{
      org_a: org_a,
      org_b: org_b
    } do
      channel_canvas = canvas!(space!(%{org_id: org_a.id}))
      dm_canvas = canvas!(space!(%{kind: "dm", org_id: nil, is_direct: true}))
      execution_canvas = canvas!(space!(%{kind: "execution", org_id: nil}))
      attach!(task_in!(org_a), execution_canvas)

      context = federation_context(nil, outsider_agent!(org_b))

      denials =
        for canvas <- [channel_canvas, dm_canvas, execution_canvas], tool <- @reads do
          assert {:error, payload} = read(tool, %{"canvas_id" => canvas.id}, context)
          Map.delete(payload, :canvas_id)
        end

      assert length(Enum.uniq(denials)) == 1,
             "denials differ by space shape or by handler: #{inspect(Enum.uniq(denials))}"
    end
  end

  # ── 6. The in-space control ───────────────────────────────────────────────

  describe "the ordinary in-space agent" do
    test "still reads both surfaces after the gate", %{org_a: org_a} do
      space = space!(%{org_id: org_a.id})
      canvas = canvas!(space)
      agent_id = UUID.generate()
      participant = add_agent!(space.id, agent_id)

      on_exit(fn -> CanvasServer.stop(canvas.id) end)

      context = federation_context(space.id, agent_id, participant.id)

      assert {:ok, described} = ToolHandlers.describe(%{"canvas_id" => canvas.id}, context)
      assert described.canvas_id == canvas.id
      assert described.space_id == space.id
      assert is_map(described.document)

      assert {:ok, listed} = VersionHandlers.versions(%{"canvas_id" => canvas.id}, context)
      assert listed.canvas_id == canvas.id
      assert is_list(listed.versions)
    end
  end
end
