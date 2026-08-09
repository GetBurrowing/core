defmodule Platform.Design.CritiqueTest do
  @moduledoc """
  Detectors for the synchronous critique path (task `019fe844` stage 2).

  ## The load-bearing assertion is on the OUTBOUND BYTES

  `request/1` returning `{:ok, %{issues: [...]}}` proves only that the
  function returns something — a stub endpoint answers with the same
  payload whether the prompt carried the canvas or carried nothing at all.
  The defect being fixed is that context never reached the model, and the
  ONLY place that is observable is the JSON body the stub received. So
  every happy-path test here asserts `@probe` is present in the captured
  outbound body, modelled on
  `test/platform/responsibilities/architecture_context_bridge_test.exs`.

  The same discipline applies to the landing: review items are asserted by
  CONTENT, never by count. A count of 1 is satisfied by an item carrying
  the empty string.

  ## What each test detonated on before the change

  Recorded because a guard that has not been shown to fire proves nothing.
  Run against `c5657d89` (stage 1's tree) with `Platform.Design.Critique`
  and `ReviewRequests.add_item/2` absent:

    * every test in this file — `UndefinedFunctionError`,
      `Platform.Design.Critique.request/1 is undefined (module
      Platform.Design.Critique is not available)`. The module did not
      exist, which is precisely the defect: there was no seam an agent
      could call at all, the chat trigger being closed to agents by
      `Router.maybe_fire_chat_patterns/3`'s feedback-loop guard.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Design.Critique
  alias Platform.Design.Critique.Verdict
  alias Platform.ExternalAgents.EphemeralCredentials
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.DesignCritique
  alias Platform.Roles
  alias Platform.Roles.Role
  alias Platform.Roles.RoleResponsibility
  alias Platform.Tasks
  alias Platform.Tasks.ReviewRequests

  # In the canvas document fixture and nowhere else in the prompt path, so
  # a hit on the wire came from the canvas or it came from nowhere.
  @probe "Submit button, grey on grey"

  # In the stub's reply and nowhere else, so a hit in a review item came
  # from the model's answer rather than from any canned rendering.
  @verdict_probe "contrast ratio 2.1:1"

  setup do
    {:ok, _} = Application.ensure_all_started(:req)

    Application.put_env(
      :platform,
      :external_agents_dispatcher_req_client,
      Req.new(plug: {Req.Test, :design_critique_test})
    )

    on_exit(fn ->
      Application.delete_env(:platform, :external_agents_dispatcher_req_client)
    end)

    :ok
  end

  describe "request/1 — the wire" do
    test "the canvas text reaches the model and the parsed verdict comes back" do
      %{canvas: canvas} = wire_everything()
      stub_reply!(issues_json())

      assert {:ok, result} = Critique.request(%{canvas_id: canvas.id})

      assert [%{"severity" => "high"} | _] = result.issues
      refute result.unparseable?

      # THE assertion. Everything above passes over an empty context.
      assert_receive {:outbound, body}
      user = message_content(body, "user")
      assert user =~ @probe

      system = message_content(body, "system")
      assert system =~ "Saru"
      refute system =~ "Vega"
    end

    test "the requester's note travels with the canvas" do
      %{canvas: canvas} = wire_everything()
      stub_reply!(issues_json())

      assert {:ok, _} =
               Critique.request(%{
                 canvas_id: canvas.id,
                 note: "the empty state is what worries me"
               })

      assert_receive {:outbound, body}
      user = message_content(body, "user")
      assert user =~ @probe
      assert user =~ "the empty state is what worries me"
    end
  end

  describe "request/1 — landing on the review request" do
    test "the verdict lands as an item on the pending request, by content" do
      %{canvas: canvas, task: task} = wire_everything()
      request = pending_review_request!(task)
      stub_reply!(issues_json())

      assert {:ok, result} =
               Critique.request(%{
                 canvas_id: canvas.id,
                 task_id: task.id,
                 review_request_id: request.id
               })

      assert is_binary(result.review_item_id)

      reloaded = ReviewRequests.get_review_request(request.id)
      item = Enum.find(reloaded.items, &(&1.label =~ "Saru"))

      refute is_nil(item), "no Saru-labelled item on the review request"
      assert item.content =~ @verdict_probe
      assert item.status == "pending"

      # The gate the human is supposed to click is still unclicked.
      assert reloaded.status == "pending"
    end

    test "the audit-trail landing posts the critique into the execution space" do
      %{canvas: canvas, task: task} = wire_everything()
      {:ok, space} = ExecutionSpace.find_or_create(task.id)
      stub_reply!(issues_json())

      assert {:ok, _} = Critique.request(%{canvas_id: canvas.id, task_id: task.id})

      contents = space.id |> Chat.list_messages() |> Enum.map(& &1.content)
      assert Enum.any?(contents, &(&1 =~ @verdict_probe))
    end

    test "a missing review request does not take the returned verdict down" do
      %{canvas: canvas} = wire_everything()
      stub_reply!(issues_json())

      assert {:ok, result} =
               Critique.request(%{
                 canvas_id: canvas.id,
                 review_request_id: Ecto.UUID.generate()
               })

      assert result.review_item_id == nil
      assert [%{"severity" => "high"} | _] = result.issues
    end
  end

  describe "request/1 — refusals reach the caller" do
    test "an unfilled Designer role returns an error and bills no model call" do
      %{canvas: canvas} = wire_everything(assign_role?: false)
      stub_reply!(issues_json())

      assert {:error, :responsibility_unfilled} = Critique.request(%{canvas_id: canvas.id})

      refute_receive {:outbound, _body}
    end

    test "an unresolvable canvas is propagated verbatim and reaches no endpoint" do
      wire_everything()
      stub_reply!(issues_json())

      assert {:error, :no_canvas_resolved} =
               Critique.request(%{canvas_id: Ecto.UUID.generate()})

      refute_receive {:outbound, _body}
    end

    test "a native assignee is refused rather than silently no-opped" do
      %{canvas: canvas} = wire_everything(agent_kind: "native")
      stub_reply!(issues_json())

      assert {:error, {:assignee_not_external, "native"}} =
               Critique.request(%{canvas_id: canvas.id})

      refute_receive {:outbound, _body}
    end
  end

  describe "request/1 — fall open on an unparseable reply" do
    test "prose still returns ok and still lands as a review item" do
      %{canvas: canvas, task: task} = wire_everything()
      request = pending_review_request!(task)

      stub_reply!(
        "Honestly the #{@verdict_probe} thing is the only problem and I " <>
          "am not going to format it as JSON."
      )

      assert {:ok, result} =
               Critique.request(%{
                 canvas_id: canvas.id,
                 review_request_id: request.id
               })

      assert result.unparseable?
      assert result.issues == []
      assert result.raw =~ @verdict_probe

      reloaded = ReviewRequests.get_review_request(request.id)
      item = Enum.find(reloaded.items, &(&1.label =~ "Saru"))

      # The prose the model DID produce is what the human sees. A
      # malformed reply must never hard-block the gate.
      assert item.content =~ @verdict_probe
      assert reloaded.status == "pending"
    end

    test "a fenced json block with prose either side parses" do
      %{canvas: canvas} = wire_everything()

      stub_reply!("""
      Here is what I found.

      ```json
      #{issues_json()}
      ```

      Happy to look again once those land.
      """)

      assert {:ok, result} = Critique.request(%{canvas_id: canvas.id})

      refute result.unparseable?
      assert [%{"issue" => issue} | _] = result.issues
      assert issue =~ @verdict_probe
    end
  end

  describe "handle_output/3 — the async arm shares the same landing" do
    test "a human-typed critique lands on the review request too" do
      %{task: task} = wire_everything()
      request = pending_review_request!(task)

      [spec] = DesignCritique.register()
      row = Responsibilities.get_by_key(spec.key)

      assert :ok =
               DesignCritique.handle_output(row, issues_json(), %{
                 task_id: task.id,
                 review_request_id: request.id
               })

      reloaded = ReviewRequests.get_review_request(request.id)
      item = Enum.find(reloaded.items, &(&1.label =~ "Saru"))

      assert item.content =~ @verdict_probe
    end
  end

  describe "land_verdict/2 — the shape the chat path actually produces" do
    # The chat trigger meta carries a space id and NOTHING ELSE: no
    # task_id, no review_request_id. Every other test in this file hands
    # land_verdict/2 one of the two keys the tool path supplies, which is
    # why the whole unit suite stayed green while a human typing the
    # handle got nothing at all. These two pin the space-only shape.
    test "an execution space named only by :space_id still receives the verdict" do
      %{task: task} = wire_everything()
      {:ok, space} = ExecutionSpace.find_or_create(task.id)

      assert Critique.land_verdict(Verdict.parse(issues_json()), %{space_id: space.id}) == nil

      contents = space.id |> Chat.list_messages() |> Enum.map(& &1.content)

      assert Enum.any?(contents, &(&1 =~ @verdict_probe)),
             "verdict landed nowhere for the space-only shape the chat path produces"
    end

    test "an ordinary channel named only by :space_id gets the verdict as a visible message" do
      wire_everything()
      space = space_fixture()

      assert Critique.land_verdict(Verdict.parse(issues_json()), %{space_id: space.id}) == nil

      messages = Chat.list_messages(space.id)
      posted = Enum.find(messages, &(&1.content =~ @verdict_probe))

      refute is_nil(posted),
             "a human who typed the handle in a normal channel saw nothing"

      # A log-only message is chrome in a normal channel — the person who
      # asked has to be able to read the answer they asked for.
      refute posted.log_only
    end
  end

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp wire_everything(opts \\ []) do
    [spec] = DesignCritique.register()
    {:ok, row} = Responsibilities.upsert_by_key(spec)

    {:ok, project} = Tasks.create_project(%{name: "Critique Project"})

    task =
      Repo.insert!(
        Ecto.Changeset.change(%Platform.Tasks.Task{}, %{
          project_id: project.id,
          title: "Critique the checkout surface",
          status: "in_progress",
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        })
      )

    space = space_fixture()
    {:ok, participant} = ExecutionSpace.ensure_system_participant(space.id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        space_id: space.id,
        created_by: participant.id,
        title: "Checkout screen",
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

    agent = maybe_wire_designer(row.key, opts)

    %{row: row, task: task, space: space, canvas: canvas, agent: agent}
  end

  # The Designer role is deliberately optional: the "unfilled
  # responsibility" test needs the row registered and the canvas real, so
  # that its refusal is attributable to the missing assignee and nothing
  # else.
  defp maybe_wire_designer(responsibility_key, opts) do
    if Keyword.get(opts, :assign_role?, true) do
      wire_designer(responsibility_key, Keyword.get(opts, :agent_kind, "external"))
    end
  end

  defp wire_designer(responsibility_key, kind) do
    Repo.insert!(
      %Role{
        key: "designer",
        name: "Designer",
        description: "test",
        icon: "hero-swatch"
      },
      on_conflict: :nothing,
      conflict_target: :key
    )

    %RoleResponsibility{}
    |> RoleResponsibility.changeset(%{
      role_key: "designer",
      responsibility_key: responsibility_key
    })
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:role_key, :responsibility_key])

    attrs =
      %{
        slug: "saru-critique-test-#{System.unique_integer([:positive])}",
        name: "Saru Critique Test",
        status: "active",
        kind: kind,
        workspace_id: nil
      }
      |> then(fn base ->
        if kind == "external" do
          Map.merge(base, %{
            endpoint_kind: "openai_compat",
            base_url: "https://api.example.test",
            model: "test-model"
          })
        else
          base
        end
      end)

    agent = %Agent{} |> Agent.changeset(attrs) |> Repo.insert!()

    if kind == "external" do
      :ok = EphemeralCredentials.put(agent.id, "sk-design-critique-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)
    end

    {:ok, _} = Roles.assign_role("designer", agent.id)

    agent
  end

  defp pending_review_request!(task) do
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

  defp space_fixture do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{name: "critique-#{n}", slug: "critique-#{n}", kind: "channel"})

    space
  end

  defp issues_json do
    Jason.encode!(%{
      "issues" => [
        %{
          "severity" => "high",
          "location" => "Submit button",
          "issue" => "The submit button sits at #{@verdict_probe} against its background.",
          "suggestion" => "Darken the fill to at least 4.5:1."
        }
      ]
    })
  end

  defp stub_reply!(content) do
    test_pid = self()

    Req.Test.stub(:design_critique_test, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:outbound, Jason.decode!(raw)})

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}]
      })
    end)

    :ok
  end

  defp message_content(%{"messages" => messages}, role) do
    case Enum.find(messages, &(&1["role"] == role)) do
      %{"content" => content} when is_binary(content) -> content
      _ -> nil
    end
  end
end
