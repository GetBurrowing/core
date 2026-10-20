defmodule Platform.Federation.ToolSurfaceStackCanvasTest do
  @moduledoc """
  `stack_attach_canvas` and `stack_detach_canvas` (task 01a1559a stage 2),
  driven over the real `/mcp` transport with runtime bearer tokens, because
  the caller's Scope is built by the transport and a hand-written context
  cannot show what it carries.

  Covers:

    * an agent whose runtime holds `tasks.write` in the stack's org, and that
      is on no member's assignee, phase assignee or execution space, attaches
      and detaches; every new row records that agent;
    * a cross-org (fenced) runtime gets an envelope byte-identical to the one
      a random-UUID `stack_id` gets, and nothing is written;
    * a runtime without `tasks.write` is refused by
      `Platform.Federation.ToolAuthorization.authorize/2`, before any handler.

  The refusal taxonomy of both tools is driven in
  `test/security/task_canvas_attachment_authorization_test.exs`, beside the
  three single-task tools.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Federation.ToolAuthorization
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachment
  alias Platform.Tasks.Stacks
  alias Platform.Tenancy

  setup do
    %{org_a: Tenancy.get_org_by_slug!("globex"), org_b: Tenancy.get_org_by_slug!("initech")}
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp n, do: System.unique_integer([:positive])

  defp user! do
    Repo.insert!(%User{
      email: "tssc-#{n()}@example.com",
      name: "Stack Canvas User",
      oidc_sub: "oidc-tssc-#{n()}"
    })
  end

  defp agent! do
    Repo.insert!(%Agent{slug: "tssc-agent-#{n()}", name: "TSSC Agent #{n()}", status: "active"})
  end

  defp member_of!(org) do
    user = user!()
    Platform.ExternalUserFixtures.plain_member!(user, org)
    user
  end

  defp stack!(org, count) do
    {:ok, project} = Tasks.create_project(%{name: "TSSC Project #{n()}", org_id: org.id})

    slug = "tssc-#{n()}"

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "TSSC Stack",
        rollup_branch: "stack/#{slug}"
      })

    members =
      for i <- 1..count//1 do
        {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "TSSC member #{i}"})
        {:ok, member} = Stacks.add_task(stack, task)
        member
      end

    {stack, members}
  end

  defp canvas_in!(org) do
    {:ok, space} =
      Chat.create_space(%{
        name: "TSSC canvas #{n()}",
        slug: "tssc-canvas-#{n()}",
        kind: "channel",
        org_id: org.id
      })

    {:ok, author} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Author",
        joined_at: DateTime.utc_now()
      })

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => author.id,
        "title" => "Stack canvas #{n()}"
      })

    {space, canvas}
  end

  # A runtime bound to `agent`, owned by `owner`, carrying `bundles`. Its
  # Scope is fenced to the owner's org membership.
  defp runtime!(agent, owner, bundles) do
    raw = AgentRuntime.generate_token()

    {:ok, runtime} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "tssc-rt-#{n()}",
        owner_user_id: owner.id,
        agent_id: agent.id,
        auth_token_hash: AgentRuntime.hash_token(raw),
        status: "active"
      })
      |> Repo.insert()

    {:ok, _profile} =
      Platform.Access.RuntimeProfiles.create_for_runtime(
        runtime,
        bundles,
        Platform.Access.RuntimeProfiles.translated_permissions(bundles)
      )

    {runtime, raw}
  end

  defp call(token, tool, args) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => n(),
      "method" => "tools/call",
      "params" => %{"name" => tool, "arguments" => args}
    }

    Phoenix.ConnTest.build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", body)
    |> json_response(200)
  end

  defp unwrap(%{"result" => %{"isError" => is_error, "content" => [%{"text" => text}]}}) do
    if is_error, do: {:error, Jason.decode!(text)}, else: {:ok, Jason.decode!(text)}
  end

  defp tool_text(%{"result" => %{"content" => [%{"text" => text}]}}), do: text

  defp rows_for(canvas_id) do
    Repo.all(from(a in CanvasAttachment, where: a.canvas_id == ^canvas_id))
  end

  defp swap_id(text, from, to) when is_binary(text), do: String.replace(text, from, to)

  # ── tests ─────────────────────────────────────────────────────────────────

  describe "an unbound same-org agent" do
    test "attaches and detaches across the stack; rows record the agent", %{org_a: org_a} do
      {stack, members} = stack!(org_a, 3)
      {space, canvas} = canvas_in!(org_a)
      agent = agent!()
      {:ok, _} = Chat.add_agent_participant(space.id, agent)
      {_rt, token} = runtime!(agent, member_of!(org_a), ["task", "canvas"])

      for m <- members do
        task = Repo.get!(Platform.Tasks.Task, m.id)
        refute task.assignee_id == agent.id
        assert task.phase_assignees in [nil, %{}]
        assert ExecutionSpace.find_by_task_id(task.id) == nil
      end

      assert {:ok, attached} =
               token
               |> call("stack_attach_canvas", %{
                 "stack_id" => stack.id,
                 "canvas_id" => canvas.id,
                 "note" => "for every member"
               })
               |> unwrap()

      member_ids = Enum.map(members, & &1.id)

      assert attached == %{
               "stack_id" => stack.id,
               "canvas_id" => canvas.id,
               "member_count" => 3,
               "attached_count" => 3,
               "skipped_count" => 0,
               "attached_task_ids" => member_ids,
               "skipped_task_ids" => []
             }

      rows = rows_for(canvas.id)
      assert length(rows) == 3

      for row <- rows do
        assert row.attached_by_kind == "agent"
        assert row.attached_by_id == agent.id
        assert row.note == "for every member"
      end

      assert {:ok, %{"attached_count" => 0, "skipped_count" => 3}} =
               token
               |> call("stack_attach_canvas", %{"stack_id" => stack.id, "canvas_id" => canvas.id})
               |> unwrap()

      assert {:ok, %{"detached_count" => 3, "detached_task_ids" => ^member_ids}} =
               token
               |> call("stack_detach_canvas", %{"stack_id" => stack.id, "canvas_id" => canvas.id})
               |> unwrap()

      assert rows_for(canvas.id) == []
    end
  end

  describe "a cross-org (fenced) runtime" do
    # The `@task_write_targets` intercept swaps a stack the caller may not
    # write for a fresh UUID, so the handler takes its own not-found arm.
    test "gets the random-UUID envelope, byte for byte, and writes nothing",
         %{org_a: org_a, org_b: org_b} do
      {stack, _members} = stack!(org_a, 2)
      {space, canvas} = canvas_in!(org_a)
      agent = agent!()
      {:ok, _} = Chat.add_agent_participant(space.id, agent)
      {_rt, token} = runtime!(agent, member_of!(org_b), ["task", "canvas"])

      {:ok, _} =
        Platform.Tasks.CanvasAttachments.attach_canvas_to_stack(
          Platform.Access.Scope.system(),
          stack.id,
          canvas.id,
          attached_by: %{kind: "user", id: Ecto.UUID.generate()}
        )

      before = rows_for(canvas.id)
      assert length(before) == 2

      for tool <- ~w(stack_attach_canvas stack_detach_canvas) do
        refused = call(token, tool, %{"stack_id" => stack.id, "canvas_id" => canvas.id})
        random = Ecto.UUID.generate()
        answer = call(token, tool, %{"stack_id" => random, "canvas_id" => canvas.id})

        assert {:error, %{"code" => "stack_not_found"}} = unwrap(refused)

        # BYTE-identical: the tool-result text exactly as it left the server,
        # with the random id read as the stack id it stands in for.
        assert tool_text(refused) == answer |> tool_text() |> swap_id(random, stack.id)
        assert refused["result"]["isError"] == answer["result"]["isError"]
      end

      assert rows_for(canvas.id) == before

      # Positive control: the same runtime on a stack in its own org, with a
      # canvas it reads inside its fence.
      {own_stack, _} = stack!(org_b, 2)
      {own_space, own_canvas} = canvas_in!(org_b)
      {:ok, _} = Chat.add_agent_participant(own_space.id, agent)

      assert {:ok, %{"attached_count" => 2}} =
               token
               |> call("stack_attach_canvas", %{
                 "stack_id" => own_stack.id,
                 "canvas_id" => own_canvas.id
               })
               |> unwrap()
    end
  end

  describe "a runtime without tasks.write" do
    test "is refused by ToolAuthorization.authorize/2, not by the handler", %{org_a: org_a} do
      {stack, _members} = stack!(org_a, 2)
      {space, canvas} = canvas_in!(org_a)
      agent = agent!()
      {:ok, _} = Chat.add_agent_participant(space.id, agent)
      owner = member_of!(org_a)
      {runtime, token} = runtime!(agent, owner, ["canvas"])

      for tool <- ~w(stack_attach_canvas stack_detach_canvas) do
        assert ToolAuthorization.authorize(tool, runtime) == {:error, :forbidden}

        response = call(token, tool, %{"stack_id" => stack.id, "canvas_id" => canvas.id})

        # Refused at the transport's authorization step: a JSON-RPC error,
        # never a tool result the handler produced.
        assert %{"error" => %{"message" => message}} = response
        refute Map.has_key?(response, "result")
        assert message =~ "tasks.write"
      end

      assert rows_for(canvas.id) == []

      # Positive control: the same owner and agent with the `task` bundle are
      # authorized and the attach lands.
      {granted, granted_token} = runtime!(agent, owner, ["task", "canvas"])
      assert ToolAuthorization.authorize("stack_attach_canvas", granted) == :ok

      assert {:ok, %{"attached_count" => 2}} =
               granted_token
               |> call("stack_attach_canvas", %{"stack_id" => stack.id, "canvas_id" => canvas.id})
               |> unwrap()
    end
  end
end
