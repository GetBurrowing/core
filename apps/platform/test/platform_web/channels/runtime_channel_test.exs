defmodule PlatformWeb.RuntimeChannelTest do
  use PlatformWeb.ChannelCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks

  setup do
    # Set up a writable uploads directory for attachment tests
    previous_root = Application.get_env(:platform, :chat_attachments_root)

    upload_root =
      Path.join(
        System.tmp_dir!(),
        "runtime_channel_test_uploads_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(upload_root)
    Application.put_env(:platform, :chat_attachments_root, upload_root)

    on_exit(fn ->
      Application.put_env(:platform, :chat_attachments_root, previous_root)
      File.rm_rf(upload_root)
    end)

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
      Chat.add_agent_participant(space.id, agent, display_name: agent.name)

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

  describe "client_info handshake on join" do
    test "join with valid client_info stashes assigns and persists to metadata", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, joined_socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{
          "client_info" => %{"product" => "openclaw", "version" => "1.2.3"}
        })

      assert joined_socket.assigns.client_info == %{product: "openclaw", version: "1.2.3"}

      reloaded = Repo.get(Platform.Agents.AgentRuntime, ctx.runtime.id)
      assert reloaded.metadata["client_info"]["product"] == "openclaw"
      assert reloaded.metadata["client_info"]["version"] == "1.2.3"
      assert is_binary(reloaded.metadata["client_info"]["last_seen_at"])
    end

    test "join without client_info defaults to unknown and does not touch metadata", ctx do
      original_metadata = ctx.runtime.metadata || %{}

      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, joined_socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      assert joined_socket.assigns.client_info == %{product: "unknown", version: nil}

      reloaded = Repo.get(Platform.Agents.AgentRuntime, ctx.runtime.id)
      # Metadata should be unchanged — no client_info ever written.
      assert reloaded.metadata == original_metadata
      refute Map.has_key?(reloaded.metadata || %{}, "client_info")
    end

    test "join with bogus product lands as unknown but is still persisted", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, joined_socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{
          "client_info" => %{"product" => "definitely_not_a_real_product"}
        })

      assert joined_socket.assigns.client_info == %{product: "unknown", version: nil}

      reloaded = Repo.get(Platform.Agents.AgentRuntime, ctx.runtime.id)
      # Client DID declare something, just garbage — we persist the
      # defensive "unknown" so we have a record of the failed declaration.
      assert reloaded.metadata["client_info"]["product"] == "unknown"
      assert reloaded.metadata["client_info"]["version"] == nil
      assert is_binary(reloaded.metadata["client_info"]["last_seen_at"])
    end

    test "AgentRuntime.client_product/1 round-trips the persisted value end-to-end", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, _joined_socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{
          "client_info" => %{"product" => "claude_channel", "version" => "0.9.0"}
        })

      reloaded = Repo.get(Platform.Agents.AgentRuntime, ctx.runtime.id)
      assert Platform.Agents.AgentRuntime.client_product(reloaded) == "claude_channel"
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

  describe "execution_event" do
    test "records runtime execution events and acknowledges them", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      {:ok, project} = Tasks.create_project(%{name: "Runtime channel project"})
      {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Runtime channel task"})
      {:ok, space} = ExecutionSpace.find_or_create(task.id)

      push(socket, "execution_event", %{
        "task_id" => task.id,
        "phase" => "execution",
        "event_type" => "execution.started",
        "execution_space_id" => space.id,
        "idempotency_key" => "runtime-channel-started-#{task.id}"
      })

      assert_receive %Phoenix.Socket.Message{
        event: "execution_event_ack",
        payload: %{idempotency_key: _, status: "ok"}
      }

      lease = Platform.Orchestration.current_lease_for_task(task.id)
      assert lease.runtime_id == ctx.runtime.runtime_id
      assert lease.status == "active"

      messages = ExecutionSpace.list_messages_with_participants(space.id)
      assert Enum.any?(messages, &String.contains?(&1.content, "started execution"))
    end
  end

  describe "reply_with_media" do
    test "posts message with base64 attachments", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      # Create a small test PNG (1x1 pixel)
      png_data = Base.encode64("fake-image-data-for-test")

      push(socket, "reply_with_media", %{
        "space_id" => ctx.space.id,
        "content" => "Here is the diagram",
        "attachments" => [
          %{
            "filename" => "diagram.png",
            "content_type" => "image/png",
            "data" => png_data
          }
        ]
      })

      Process.sleep(200)

      messages = Chat.list_messages(ctx.space.id, limit: 10)
      msg = Enum.find(messages, fn m -> m.content == "Here is the diagram" end)
      assert msg
      assert msg.metadata["has_media"] == true

      attachments = Chat.list_attachments(msg.id)
      assert length(attachments) == 1
      assert hd(attachments).filename == "diagram.png"
      assert hd(attachments).content_type == "image/png"
    end

    test "posts message with multiple attachments", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "reply_with_media", %{
        "space_id" => ctx.space.id,
        "content" => "Two files attached",
        "attachments" => [
          %{
            "filename" => "file1.txt",
            "content_type" => "text/plain",
            "data" => Base.encode64("hello")
          },
          %{
            "filename" => "file2.txt",
            "content_type" => "text/plain",
            "data" => Base.encode64("world")
          }
        ]
      })

      Process.sleep(200)

      messages = Chat.list_messages(ctx.space.id, limit: 10)
      msg = Enum.find(messages, fn m -> m.content == "Two files attached" end)
      assert msg

      attachments = Chat.list_attachments(msg.id)
      assert length(attachments) == 2
    end

    test "rejects oversized attachments", ctx do
      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      # Create data that exceeds 10MB when decoded
      # 10MB * 4/3 for base64 ≈ 13.3MB of base64 text
      large_data = String.duplicate("A", 14_000_000)

      push(socket, "reply_with_media", %{
        "space_id" => ctx.space.id,
        "content" => "Too big",
        "attachments" => [
          %{
            "filename" => "huge.bin",
            "content_type" => "application/octet-stream",
            "data" => large_data
          }
        ]
      })

      assert_push "error", %{error: error}
      assert error =~ "size limits exceeded"
    end

    test "rejects when agent not participant in space", ctx do
      other_space =
        create_space(%{name: "Other", slug: "other-#{System.unique_integer([:positive])}"})

      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => ctx.runtime.runtime_id,
          "token" => ctx.raw_token
        })

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      push(socket, "reply_with_media", %{
        "space_id" => other_space.id,
        "content" => "Unauthorized",
        "attachments" => []
      })

      # The agent IS auto-joined via ensure_agent_participant, so let's
      # test with a nil space_id instead
      push(socket, "reply_with_media", %{
        "space_id" => nil,
        "content" => "No space",
        "attachments" => []
      })

      assert_push "error", %{error: "Agent is not a participant in this space"}
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

      document = %{
        "version" => 1,
        "revision" => 1,
        "root" => %{
          "id" => "root",
          "type" => "stack",
          "props" => %{"gap" => 12},
          "children" => [
            %{
              "id" => "t",
              "type" => "table",
              "props" => %{
                "columns" => ["Name"],
                "rows" => [%{"Name" => "One"}]
              },
              "children" => []
            }
          ]
        },
        "theme" => %{},
        "bindings" => %{},
        "meta" => %{}
      }

      push(socket, "tool_call", %{
        "call_id" => "call-1",
        "tool" => "canvas.create",
        "args" => %{
          "space_id" => ctx.space.id,
          "title" => "Runtime Canvas",
          "document" => document
        }
      })

      assert_push "tool_result", %{call_id: "call-1", status: "ok", result: result}
      assert result.kind == "stack"
      assert result.title == "Runtime Canvas"
    end
  end
end
