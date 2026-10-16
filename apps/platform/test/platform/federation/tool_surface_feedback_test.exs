defmodule Platform.Federation.ToolSurfaceFeedbackTest do
  @moduledoc """
  Task 01a11ec3 stage 2: `feedback.submit` exists on the federated tool
  surface exactly when `Platform.Feedback.Policy.enabled?/0` holds.

  "Exists" is asserted on every surface a caller can reach it through: the
  full catalogue (`tool_definitions/0`), the bundle listing, a runtime's
  effective (listed == callable) set via `ToolAuthorization`, and the
  argument-gated dispatch entry point. A disabled installation must fail all
  four, and the handler must refuse even a caller that skips authorization.

  Written before the implementation: against the unfixed base the
  enabled-installation tests fail (the tool is in no listing and dispatch
  answers `Unknown tool`), and the module fails to call the absent
  `Platform.Feedback` modules.

  async: false — flips `:feedback_policy`.
  """
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Access.RuntimeProfiles
  alias Platform.Federation.ToolArguments
  alias Platform.Federation.ToolAuthorization
  alias Platform.Federation.ToolSurface
  alias Platform.Repo

  @tool "feedback.submit"
  @broker Platform.Feedback.GithubPublisher.Broker

  setup do
    saved = Application.fetch_env(:platform, :feedback_policy)

    on_exit(fn ->
      case saved do
        {:ok, v} -> Application.put_env(:platform, :feedback_policy, v)
        :error -> Application.delete_env(:platform, :feedback_policy)
      end
    end)

    test_pid = self()

    Req.Test.stub(@broker, fn conn ->
      send(test_pid, {:broker, conn.method})

      Req.Test.json(Plug.Conn.put_status(conn, 201), %{
        "repository" => "Startup-Suite/core",
        "issue_number" => 7
      })
    end)

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "feedback-tool-#{System.unique_integer([:positive])}",
        name: "Feedback tool agent",
        status: "active"
      })
      |> Repo.insert!()

    runtime =
      Repo.insert!(%AgentRuntime{
        runtime_id: "feedback-surface-#{System.unique_integer([:positive])}",
        owner_user_id: root_admin!().id
      })

    {:ok, _profile} =
      RuntimeProfiles.create_for_runtime(
        runtime,
        ["federation"],
        RuntimeProfiles.translated_permissions(["federation"])
      )

    %{agent: agent, runtime: runtime}
  end

  defp set_policy(value), do: Application.put_env(:platform, :feedback_policy, value)

  defp names(tools), do: Enum.map(tools, & &1.name)

  defp args do
    %{
      "category" => "bug",
      "title" => "Stage list omits the review gate",
      "expected_behavior" => "The review gate is listed.",
      "observed_behavior" => "It is missing.",
      "space_id" => "019f0000-0000-7000-8000-000000000000"
    }
  end

  describe "disabled installation" do
    setup do
      set_policy("disabled")
      :ok
    end

    test "lists the tool nowhere", %{runtime: runtime} do
      refute @tool in names(ToolSurface.tool_definitions())
      refute @tool in names(ToolSurface.list_tools(ToolSurface.all_bundles()))
      refute @tool in ToolAuthorization.tool_names(runtime)
      assert {:error, :forbidden} = ToolAuthorization.authorize(@tool, runtime)
    end

    test "refuses execution server-side, even past authorization", %{agent: agent} do
      for call <- [
            fn -> ToolArguments.dispatch(@tool, args(), %{agent_id: agent.id}) end,
            fn -> ToolSurface.execute(@tool, args(), %{agent_id: agent.id}) end
          ] do
        assert {:error, %{code: :feedback_disabled, recoverable: false}} = call.()
      end

      refute_received {:broker, _}
    end

    test "no value outside the policy names turns it on", %{runtime: runtime} do
      for value <- [nil, "", "on", "true", "enabled", "QUARANTINE", "trust"] do
        set_policy(value)
        refute @tool in ToolAuthorization.tool_names(runtime), "#{inspect(value)} enabled it"
      end
    end
  end

  describe "enabled installation" do
    test "quarantined and trusted both list it in the default federation bundle",
         %{runtime: runtime} do
      for value <- ["quarantined", "trusted", " Trusted "] do
        set_policy(value)

        assert @tool in names(ToolSurface.tool_definitions())

        assert [%{bundle: "federation"}] =
                 Enum.filter(ToolSurface.list_tools(["federation"]), &(&1.name == @tool))

        assert @tool in ToolAuthorization.tool_names(runtime)
        assert :ok = ToolAuthorization.authorize(@tool, runtime)
      end
    end

    test "an external principal's chat-only scope never gains it" do
      set_policy("quarantined")
      scoped = ToolSurface.scope_for_external(ToolSurface.list_tools(["federation"]), true)
      refute @tool in names(scoped)
    end

    test "declares the allowlisted fields as its only parameters" do
      set_policy("quarantined")
      [tool] = Enum.filter(ToolSurface.tool_definitions(), &(&1.name == @tool))

      assert tool.parameters |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort() ==
               Enum.sort(Platform.Feedback.Submission.allowed_keys())

      for p <- [:category, :title, :expected_behavior, :observed_behavior],
          do: assert(tool.parameters[p].required)
    end

    test "dispatch publishes once and returns only the bounded identity", %{agent: agent} do
      set_policy("quarantined")

      assert {:ok, first} = ToolArguments.dispatch(@tool, args(), %{agent_id: agent.id})
      assert first.status == "created"

      assert first.issue == %{
               repository: "Startup-Suite/core",
               issue_number: 7,
               url: "https://github.com/Startup-Suite/core/issues/7"
             }

      assert first.ignored_fields == ["space_id"]

      assert {:ok, %{status: "duplicate"}} =
               ToolArguments.dispatch(@tool, args(), %{agent_id: agent.id})

      assert_received {:broker, "POST"}
      refute_received {:broker, _}
    end

    test "a missing required field is refused by the argument gate", %{agent: agent} do
      set_policy("quarantined")

      assert {:error, %{code: :missing_title}} =
               ToolArguments.dispatch(@tool, Map.delete(args(), "title"), %{agent_id: agent.id})

      refute_received {:broker, _}
    end

    test "an anonymous caller is refused", _ctx do
      set_policy("quarantined")
      assert {:error, %{code: :unauthorized}} = ToolSurface.execute(@tool, args(), %{})
      refute_received {:broker, _}
    end

    test "a refusal envelope names the field and never echoes submitted text", %{agent: agent} do
      set_policy("quarantined")

      assert {:error, envelope} =
               ToolSurface.execute(
                 @tool,
                 Map.put(args(), "category", "SENTINEL-CATEGORY"),
                 %{agent_id: agent.id}
               )

      assert envelope.code == :invalid_category
      refute inspect(envelope) =~ "SENTINEL-CATEGORY"
    end
  end
end
