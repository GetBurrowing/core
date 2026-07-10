defmodule Platform.Tasks.Stacks.DepInferenceTest do
  @moduledoc """
  Unit coverage for `Platform.Tasks.Stacks.DepInference`.

  Exercises the pure-Elixir parse/validate surface via the
  `StubAdapter` — no HTTP is made. The `stacks.dep_inference.v1`
  prompt template is seeded per-test so `render_template/2` succeeds
  before the adapter is dispatched.
  """

  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates
  alias Platform.Tasks.Stack
  alias Platform.Tasks.Stacks.DepInference
  alias Platform.Tasks.Stacks.DepInference.StubAdapter

  # UUIDs are the only member fields the module actually keys off — the
  # id set + presence of `title` / `description` for prompt rendering.
  @id_a "00000000-0000-0000-0000-000000000001"
  @id_b "00000000-0000-0000-0000-000000000002"
  @id_c "00000000-0000-0000-0000-000000000003"

  setup do
    :ok = PromptTemplates.seed_defaults()

    stack = %Stack{
      id: "00000000-0000-0000-0000-0000000000aa",
      name: "Auth foundation",
      description: "Ship user accounts and session-based login."
    }

    members = [
      %{id: @id_a, title: "Add users table", description: "Users schema + migration."},
      %{id: @id_b, title: "Add auth context", description: "Register/login on users."},
      %{id: @id_c, title: "Session cookie plug", description: "Auth-gated plug."}
    ]

    # Ensure a clean stub slate — the stub reads Process dict entries
    # that persist across setup blocks within the same test process.
    Process.delete({:dep_inference_stub, :response})
    Process.delete({:dep_inference_stub, :calls})

    {:ok, stack: stack, members: members}
  end

  describe "infer_edges/2 — happy path" do
    test "returns the validated edge list from a well-formed JSON body", %{
      stack: stack,
      members: members
    } do
      Process.put(
        {:dep_inference_stub, :response},
        {:ok,
         ~s({"edges": [{"from_task_id": "#{@id_b}", "to_task_id": "#{@id_a}", "reason": "B waits on A's users schema"}]})}
      )

      assert {:ok, edges} = DepInference.infer_edges(stack, members)

      assert edges == [
               %{
                 from_task_id: @id_b,
                 to_task_id: @id_a,
                 reason: "B waits on A's users schema"
               }
             ]

      assert Process.get({:dep_inference_stub, :calls}, 0) == 1
    end

    test "empty edges array is a legitimate success (no dependencies inferable)", %{
      stack: stack,
      members: members
    } do
      Process.put({:dep_inference_stub, :response}, {:ok, ~s({"edges": []})})

      assert {:ok, []} = DepInference.infer_edges(stack, members)
    end
  end

  describe "infer_edges/2 — filtering" do
    test "strips self-edges (from_task_id == to_task_id)", %{stack: stack, members: members} do
      body =
        Jason.encode!(%{
          "edges" => [
            %{"from_task_id" => @id_a, "to_task_id" => @id_a, "reason" => "self-edge nonsense"},
            %{"from_task_id" => @id_b, "to_task_id" => @id_a, "reason" => "legit"}
          ]
        })

      Process.put({:dep_inference_stub, :response}, {:ok, body})

      assert {:ok, edges} = DepInference.infer_edges(stack, members)
      assert length(edges) == 1
      assert hd(edges).from_task_id == @id_b
      assert hd(edges).to_task_id == @id_a
    end

    test "strips edges whose endpoints are not in the members set (orphan-id)", %{
      stack: stack,
      members: members
    } do
      orphan_id = "00000000-0000-0000-0000-0000000000ff"

      body =
        Jason.encode!(%{
          "edges" => [
            %{
              "from_task_id" => orphan_id,
              "to_task_id" => @id_a,
              "reason" => "hallucinated from"
            },
            %{"from_task_id" => @id_a, "to_task_id" => orphan_id, "reason" => "hallucinated to"},
            %{"from_task_id" => @id_b, "to_task_id" => @id_c, "reason" => "legit within-stack"}
          ]
        })

      Process.put({:dep_inference_stub, :response}, {:ok, body})

      assert {:ok, edges} = DepInference.infer_edges(stack, members)

      assert edges == [
               %{
                 from_task_id: @id_b,
                 to_task_id: @id_c,
                 reason: "legit within-stack"
               }
             ]
    end

    test "strips structurally-malformed entries (missing / wrong-type keys)", %{
      stack: stack,
      members: members
    } do
      body =
        Jason.encode!(%{
          "edges" => [
            # Missing reason
            %{"from_task_id" => @id_a, "to_task_id" => @id_b},
            # Wrong type on reason
            %{"from_task_id" => @id_a, "to_task_id" => @id_b, "reason" => 42},
            # Wrong shape entirely
            "not-a-map",
            # Legit
            %{"from_task_id" => @id_c, "to_task_id" => @id_a, "reason" => "keeper"}
          ]
        })

      Process.put({:dep_inference_stub, :response}, {:ok, body})

      assert {:ok, edges} = DepInference.infer_edges(stack, members)
      assert edges == [%{from_task_id: @id_c, to_task_id: @id_a, reason: "keeper"}]
    end
  end

  describe "infer_edges/2 — terminal failures" do
    test "returns :parse_failed when the body is not valid JSON", %{
      stack: stack,
      members: members
    } do
      Process.put({:dep_inference_stub, :response}, {:ok, "not-json { garbage"})

      assert {:error, :parse_failed} = DepInference.infer_edges(stack, members)
    end

    test "returns :parse_failed when JSON parses but lacks an \"edges\" list", %{
      stack: stack,
      members: members
    } do
      Process.put({:dep_inference_stub, :response}, {:ok, ~s({"other_key": true})})

      assert {:error, :parse_failed} = DepInference.infer_edges(stack, members)
    end

    test "returns :empty_response when the adapter body is empty / whitespace-only", %{
      stack: stack,
      members: members
    } do
      Process.put({:dep_inference_stub, :response}, {:ok, "   \n"})

      assert {:error, :empty_response} = DepInference.infer_edges(stack, members)
    end

    test "returns :adapter_failed when the adapter itself errors", %{
      stack: stack,
      members: members
    } do
      Process.put({:dep_inference_stub, :response}, {:error, :boom})

      assert {:error, :adapter_failed} = DepInference.infer_edges(stack, members)
    end

    test "returns :adapter_failed when the prompt template is missing" do
      # Delete only the dep-inference template so `render_template/2`
      # returns `{:error, :not_found}` and we short-circuit before any
      # adapter dispatch. Other templates stay seeded.
      case PromptTemplates.get_template_by_slug("stacks.dep_inference.v1") do
        nil -> :ok
        template -> {:ok, _} = PromptTemplates.delete_template(template)
      end

      stack = %Stack{id: "s", name: "n", description: "d"}
      members = [%{id: @id_a, title: "t", description: "d"}]

      Process.put({:dep_inference_stub, :response}, {:ok, ~s({"edges": []})})

      assert {:error, :adapter_failed} = DepInference.infer_edges(stack, members)

      # Adapter must NOT have been reached — the template-render check
      # short-circuits before any HTTP work.
      assert Process.get({:dep_inference_stub, :calls}, 0) == 0
    end
  end

  describe "StubAdapter behaviour" do
    test "increments a per-process call counter on each invocation" do
      Process.put({:dep_inference_stub, :response}, {:ok, "hi"})

      assert {:ok, "hi"} = StubAdapter.chat("prompt", [])
      assert {:ok, "hi"} = StubAdapter.chat("prompt", [])
      assert {:ok, "hi"} = StubAdapter.chat("prompt", [])

      assert Process.get({:dep_inference_stub, :calls}) == 3
    end

    test "reset_calls/0 zeroes the counter" do
      Process.put({:dep_inference_stub, :response}, {:ok, "hi"})
      assert {:ok, "hi"} = StubAdapter.chat("prompt", [])
      assert Process.get({:dep_inference_stub, :calls}) == 1

      :ok = StubAdapter.reset_calls()
      assert Process.get({:dep_inference_stub, :calls}) == 0
    end

    test "pops successive canned responses when a list is seeded" do
      Process.put(
        {:dep_inference_stub, :response},
        [{:ok, "first"}, {:ok, "second"}, {:error, :timeout}]
      )

      assert {:ok, "first"} = StubAdapter.chat("p", [])
      assert {:ok, "second"} = StubAdapter.chat("p", [])
      assert {:error, :timeout} = StubAdapter.chat("p", [])
      assert {:error, :no_stub_response_configured} = StubAdapter.chat("p", [])
    end
  end
end
