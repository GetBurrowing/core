defmodule Platform.Sharing.HelpChannelTest do
  @moduledoc """
  Task 01a1b678 stage 3: the Help & feedback channel. A new install gets it
  with General (and an install with any channel gets neither); the Burrow
  agent is seated as its principal, so a person's post reaches it; and a
  `feedback_submit` from the channel reaches the broker stub once, gated on
  the owner's "Help channel bug reports" switch.

  async: false: flips `:feedback_policy` and `:feedback_rate_limits`.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts.User
  alias Platform.Agents.{AgentRuntime, Burrow}
  alias Platform.Chat
  alias Platform.Chat.{AttentionRouter, DefaultSpace, Participant, Space}
  alias Platform.Federation.ToolArguments
  alias Platform.Repo
  alias Platform.Sharing
  alias Platform.Sharing.HelpChannel

  @broker Platform.Feedback.GithubPublisher.Broker

  setup do
    saved =
      for key <- [:feedback_policy, :feedback_rate_limits],
          do: {key, Application.fetch_env(:platform, key)}

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    Application.put_env(:platform, :feedback_policy, "quarantined")
    Application.put_env(:platform, :feedback_rate_limits, per_actor: 50, per_installation: 50)

    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)
    on_exit(fn -> Application.put_env(:platform, :chat_agent_dispatch_mode, previous_mode) end)

    router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), router)

    Repo.delete_all(from(s in Space, where: s.kind == "channel"))
    _ = Platform.TenancyFixtures.acme_org_id()
    :ok
  end

  defp channels,
    do: Repo.all(from(s in Space, where: s.kind == "channel", order_by: s.slug))

  describe "the default channels" do
    test "a new install gets General and Help & feedback, once" do
      assert {:ok, %Space{slug: "general"}} = DefaultSpace.ensure()
      assert DefaultSpace.ensure() == :exists

      assert [%Space{slug: "general"}, %Space{} = help] = channels()
      assert help.slug == HelpChannel.slug()
      assert help.name == "Help & feedback"
      assert help.org_id == Platform.Tenancy.get_root_org().id
      assert help.agent_attention_policy == "directed"
      assert HelpChannel.space().id == help.id
    end

    test "an install with any channel gets neither" do
      {:ok, _} =
        Chat.create_space(%{
          name: "Ops",
          slug: "ops-#{System.unique_integer([:positive])}",
          kind: "channel",
          org_id: Platform.Tenancy.get_root_org().id
        })

      assert DefaultSpace.ensure() == :exists
      assert [%Space{name: "Ops"}] = channels()
      assert HelpChannel.space() == nil
    end
  end

  describe "the Burrow agent in the channel" do
    setup do
      {:ok, _general} = DefaultSpace.ensure()
      owner = admin_user!()
      {:ok, agent} = Burrow.ensure(owner.id, "claude_code")
      runtime = Repo.get!(AgentRuntime, agent.runtime_id)
      help = HelpChannel.space()

      # The context both transports build for a call made from the channel.
      ctx = Platform.Federation.ToolCall.build_context(%{"space_id" => help.id}, runtime)
      %{agent: agent, help: help, ctx: ctx}
    end

    test "is seated as principal, once", %{agent: agent, help: help} do
      assert :ok = HelpChannel.ensure_agent(agent)
      assert :ok = HelpChannel.ensure_agent(agent)

      assert [%Participant{role: "principal"}] =
               Repo.all(
                 from(p in Participant,
                   where:
                     p.space_id == ^help.id and p.participant_type == "agent" and
                       p.participant_id == ^agent.id
                 )
               )
    end

    test "a person's post reaches it, and its report reaches the broker once",
         %{agent: agent, help: help, ctx: ctx} do
      :ok = HelpChannel.ensure_agent(agent)
      {:ok, _} = Sharing.set(:help_channel_reports, true, :system)
      test_pid = self()

      Req.Test.stub(@broker, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:broker, conn.method, raw})

        Req.Test.json(Plug.Conn.put_status(conn, 201), %{
          "repository" => "GetBurrowing/core",
          "issue_number" => 3001
        })
      end)

      {:ok, person} =
        Chat.add_participant(help.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Member",
          joined_at: DateTime.utc_now()
        })

      {:ok, message} =
        Chat.post_message(%{
          space_id: help.id,
          participant_id: person.id,
          content_type: "text",
          content: "The calendar shows my meeting an hour late."
        })

      burrow = Chat.get_agent_participant(help.id, agent)
      {:ok, decisions} = AttentionRouter.route(message)
      assert Enum.any?(decisions, &(&1.participant_id == burrow.id))

      args = %{
        "category" => "bug",
        "title" => "Calendar shows meetings an hour late",
        "expected_behavior" => "A meeting shows at the time it was booked.",
        "observed_behavior" => "It shows one hour later.",
        "space_id" => help.id
      }

      assert {:ok, %{status: "created", issue: %{issue_number: 3001}} = first} =
               ToolArguments.dispatch("feedback_submit", args, ctx)

      assert first.ignored_fields == []
      assert_received {:broker, "POST", _}

      assert {:ok, %{status: "duplicate"}} = ToolArguments.dispatch("feedback_submit", args, ctx)
      refute_received {:broker, "POST", _}
    end

    test "with Help channel bug reports off, a report from the channel is refused; elsewhere it is not",
         %{agent: agent, ctx: ctx} do
      :ok = HelpChannel.ensure_agent(agent)
      {:ok, _} = Sharing.set(:help_channel_reports, false, :system)
      Req.Test.stub(@broker, fn conn -> Req.Test.json(Plug.Conn.put_status(conn, 500), %{}) end)

      args = %{
        "category" => "bug",
        "title" => "Something",
        "expected_behavior" => "It works.",
        "observed_behavior" => "It does not."
      }

      assert {:error, %{code: :help_channel_reports_off}} =
               ToolArguments.dispatch("feedback_submit", args, ctx)

      assert {:error, %{code: code}} =
               ToolArguments.dispatch("feedback_submit", args, %{ctx | space_id: nil})

      refute code == :help_channel_reports_off
    end

    # Stage 4 (from the stage 3 audit): the originating space is derived
    # server-side, so leaving `space_id` out cannot skip the gate.
    test "with Help channel bug reports off, a call that originates in the channel WITHOUT space_id files nothing",
         %{agent: agent, help: help} do
      :ok = HelpChannel.ensure_agent(agent)
      {:ok, _} = Sharing.set(:help_channel_reports, false, :system)
      test_pid = self()

      Req.Test.stub(@broker, fn conn ->
        send(test_pid, :broker_called)

        Req.Test.json(Plug.Conn.put_status(conn, 201), %{
          "repository" => "x/y",
          "issue_number" => 1
        })
      end)

      runtime = Repo.get!(AgentRuntime, agent.runtime_id)

      :ok =
        Platform.Federation.AttentionDispatch.broadcast(
          runtime.runtime_id,
          %{
            message: %{author_type: "user", author_user_id: Ecto.UUID.generate(), content: "bug"}
          },
          space_id: help.id,
          agent_id: agent,
          source: :agent_responder
        )

      ctx = Platform.Federation.ToolCall.build_context(%{}, runtime)
      assert ctx.space_id == nil

      args = %{
        "category" => "bug",
        "title" => "Something",
        "expected_behavior" => "It works.",
        "observed_behavior" => "It does not."
      }

      assert {:error, %{code: :help_channel_reports_off}} =
               ToolArguments.dispatch("feedback_submit", args, ctx)

      refute_received :broker_called
      assert Repo.aggregate(Platform.Feedback.SubmissionRecord, :count) == 0
    end
  end

  defp admin_user! do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "help-#{n}@example.com",
        name: "Help owner #{n}",
        oidc_sub: "oidc-help-#{n}"
      })

    %Platform.Tenancy.OrgMembership{}
    |> Platform.Tenancy.OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.Tenancy.get_root_org().id,
      role: "admin"
    })
    |> Repo.insert!()

    user
  end
end
