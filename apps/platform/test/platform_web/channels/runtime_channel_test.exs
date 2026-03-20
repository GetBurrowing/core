defmodule PlatformWeb.RuntimeChannelTest do
  use PlatformWeb.ChannelCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Repo

  setup do
    user = create_user()
    agent = create_agent()

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "test-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, raw_token} = Federation.activate_runtime(runtime)
    {:ok, _linked} = Federation.link_agent(activated, agent)

    # Reload runtime to get agent_id
    runtime = Federation.get_runtime(activated.id)

    space = create_space()

    {:ok, agent_participant} =
      Chat.ensure_agent_participant(space.id, agent, display_name: agent.name)

    %{
      runtime: runtime,
      raw_token: raw_token,
      agent: agent,
      space: space,
      agent_participant: agent_participant,
      user: user
    }
  end

  defp create_user do
    Repo.insert!(%User{
      email: "channel_test_#{System.unique_integer([:positive])}@example.com",
      name: "Channel Test User",
      oidc_sub: "oidc-channel-test-#{System.unique_integer([:positive])}"
    })
  end

  defp create_agent(attrs \\ %{}) do
    defaults = %{
      slug: "agent-#{System.unique_integer([:positive])}",
      name: "Test Agent",
      status: "active"
    }

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    agent
  end

  defp create_space(attrs \\ %{}) do
    default = %{name: "Test", slug: "test-#{System.unique_integer([:positive])}", kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  describe "connect and join" do
    test "authenticated runtime can connect and join channel", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, _socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})
    end

    test "unauthenticated connection is rejected" do
      assert :error =
               connect(PlatformWeb.RuntimeSocket, %{
                 "runtime_id" => "bogus",
                 "token" => "bad-token"
               })
    end

    test "wrong runtime_id on join is rejected", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, "runtime:wrong-id", %{})
    end
  end

  describe "reply message" do
    test "posts to space as agent", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "reply", %{
        "space_id" => ctx.space.id,
        "content" => "Hello from external runtime!"
      })

      # Give it time to process
      Process.sleep(100)

      # Verify message was posted
      messages = Chat.list_messages(ctx.space.id, limit: 10)
      assert Enum.any?(messages, fn m -> m.content == "Hello from external runtime!" end)
    end
  end

  describe "tool_call" do
    test "executes tool and returns result", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "tool_call", %{
        "call_id" => "call-1",
        "tool" => "canvas_create",
        "args" => %{
          "space_id" => ctx.space.id,
          "canvas_type" => "table",
          "title" => "Runtime Canvas"
        }
      })

      assert_push "tool_result", %{call_id: "call-1", status: "ok", result: result}
      assert result.type == "table"
      assert result.title == "Runtime Canvas"
    end
  end
end
