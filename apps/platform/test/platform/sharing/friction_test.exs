defmodule Platform.Sharing.FrictionTest do
  @moduledoc """
  Task 01a1b678 stage 3: agent friction reports. Repeated friction files ONE
  report through `Platform.Feedback.Submission` (the `feedback_submit` path)
  against the `Req.Test` broker stub; later occurrences dedupe; the window,
  the per-install weekly cap and the off switch hold.

  async: false: flips `:feedback_policy`, `:feedback_rate_limits` and
  `:friction_reports`.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Agents.Agent
  alias Platform.Chat.Message
  alias Platform.Federation.ToolArguments
  alias Platform.Repo
  alias Platform.Sharing
  alias Platform.Sharing.{Friction, FrictionEvent, FrictionReport}

  @broker Platform.Feedback.GithubPublisher.Broker

  setup do
    saved =
      for key <- [:feedback_policy, :feedback_rate_limits, :friction_reports],
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

    Application.put_env(:platform, :friction_reports,
      threshold: 3,
      window_days: 7,
      max_reports_per_install_per_week: 2
    )

    {:ok, _} = Sharing.set(:friction_reports, true, :system)

    test_pid = self()
    counter = :counters.new(1, [])

    Req.Test.stub(@broker, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:broker, conn.method, raw})
      :counters.add(counter, 1, 1)

      Req.Test.json(Plug.Conn.put_status(conn, 201), %{
        "repository" => "GetBurrowing/core",
        "issue_number" => 2000 + :counters.get(counter, 1)
      })
    end)

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "friction-#{System.unique_integer([:positive])}",
        name: "Friction agent",
        status: "active"
      })
      |> Repo.insert!()

    %{agent: agent, ctx: %{agent: agent}}
  end

  defp posts do
    receive do
      {:broker, "POST", raw} -> [Jason.decode!(raw) | posts()]
    after
      0 -> []
    end
  end

  defp fail(ctx, tool \\ "task_get", error \\ %{code: :not_found}, opts \\ []) do
    {:ok, outcome} = Friction.record_tool_failure(tool, error, ctx, opts)
    outcome
  end

  defp event_count, do: Repo.aggregate(FrictionEvent, :count)

  describe "threshold and dedupe" do
    test "3 identical failures file exactly one report; the 4th and 5th dedupe", %{ctx: ctx} do
      assert fail(ctx) == :below_threshold
      assert fail(ctx) == :below_threshold
      assert posts() == []

      assert fail(ctx) == :filed
      assert [body] = posts()
      assert inspect(body) =~ "task_get"
      assert inspect(body) =~ "not_found"

      assert fail(ctx) == :deduped
      assert fail(ctx) == :deduped
      assert posts() == []

      assert %{filed: 1, deduped: 2, rate_limited: 0, refused: 0} = Friction.counts()
    end

    test "a different error code on the same tool is a different fingerprint", %{ctx: ctx} do
      for _ <- 1..2, do: fail(ctx)
      assert fail(ctx, "task_get", %{code: :forbidden}) == :below_threshold
      assert posts() == []
    end

    test "free-text errors are reduced to a bounded code, never their text", %{ctx: ctx} do
      for _ <- 1..3, do: fail(ctx, "task_get", "secret text a@example.com")
      assert [body] = posts()
      refute inspect(body) =~ "secret text"
      refute inspect(body) =~ "example.com"
      assert Friction.error_code(%{code: "Has Spaces and more"}) == "error"
      assert Friction.error_code(:not_found) == "not_found"
    end
  end

  describe "the window" do
    test "occurrences older than window_days do not count; one just inside does", %{ctx: ctx} do
      now = DateTime.utc_now()
      at_edge = DateTime.add(now, -7 * 86_400, :second)
      inside = DateTime.add(at_edge, 1, :second)

      fail_at = fn at -> fail(ctx, "space_get_context", %{code: :timeout}, now: at) end

      assert fail_at.(at_edge) == :below_threshold
      assert fail_at.(inside) == :below_threshold
      # Seen from `now`, the one at exactly the window's start is outside it:
      # two in the window, not three.
      assert fail_at.(now) == :below_threshold
      assert posts() == []

      assert fail_at.(now) == :filed
      assert [_] = posts()
    end
  end

  describe "the per-install weekly cap" do
    test "a third new problem in a week is held back; an already-filed one still dedupes",
         %{ctx: ctx} do
      for tool <- ~w(tool_a tool_b), _ <- 1..2, do: fail(ctx, tool)
      assert fail(ctx, "tool_a") == :filed
      assert fail(ctx, "tool_b") == :filed
      assert length(posts()) == 2

      for _ <- 1..2, do: fail(ctx, "tool_c")
      assert fail(ctx, "tool_c") == :rate_limited
      assert fail(ctx, "tool_a") == :deduped
      assert posts() == []

      assert %{filed: 2, deduped: 1, rate_limited: 1} = Friction.counts()
    end
  end

  describe "the off switch" do
    test "the owner's switch off files and records nothing", %{ctx: ctx} do
      {:ok, _} = Sharing.set(:friction_reports, false, :system)

      for _ <- 1..5, do: assert(fail(ctx) == :disabled)
      assert posts() == []
      assert event_count() == 0
      assert Repo.aggregate(FrictionReport, :count) == 0
    end

    test "the feedback policy off files and records nothing", %{ctx: ctx} do
      Application.put_env(:platform, :feedback_policy, "disabled")

      for _ <- 1..5, do: assert(fail(ctx) == :disabled)
      assert posts() == []
      assert event_count() == 0
    end
  end

  describe "questions" do
    setup %{agent: agent} do
      {:ok, space} =
        Platform.Chat.create_space(%{
          name: "Questions",
          slug: "friction-q-#{System.unique_integer([:positive])}",
          kind: "channel",
          org_id: Platform.TenancyFixtures.acme_org_id()
        })

      {:ok, person} =
        Platform.Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Person",
          joined_at: DateTime.utc_now()
        })

      {:ok, bot} =
        Platform.Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: agent.id,
          display_name: agent.name,
          joined_at: DateTime.utc_now()
        })

      %{person: person, bot: bot}
    end

    test "the same question three times, however punctuated, files one report without its text",
         %{agent: agent, person: person} do
      ask = fn text ->
        {:ok, outcome} =
          Friction.record_question(agent, %Message{content: text, participant_id: person.id})

        outcome
      end

      assert ask.("@[Friction agent] How do I invite my team?") == :below_threshold
      assert ask.("how do I invite my team??") == :below_threshold
      assert ask.("How do  I invite my TEAM ?") == :filed
      assert [body] = posts()
      refute inspect(body) =~ "invite"
      assert ask.("how do i invite my team?") == :deduped
    end

    test "statements, short texts and agent-authored questions are not counted",
         %{agent: agent, person: person, bot: bot} do
      assert {:ok, :ignored} =
               Friction.record_question(agent, %Message{
                 content: "thanks",
                 participant_id: person.id
               })

      assert {:ok, :ignored} =
               Friction.record_question(agent, %Message{
                 content: "why?",
                 participant_id: person.id
               })

      for _ <- 1..3 do
        assert {:ok, :ignored} =
                 Friction.record_question(agent, %Message{
                   content: "can you check the build?",
                   participant_id: bot.id
                 })
      end

      assert event_count() == 0
    end
  end

  describe "the dispatch hook" do
    test "a tool call failing through ToolArguments.dispatch/3 is an occurrence", %{ctx: ctx} do
      args = %{"task_id" => Ecto.UUID.generate()}

      for _ <- 1..3, do: assert({:error, _} = ToolArguments.dispatch("task_get", args, ctx))

      assert [_] = posts()

      assert [%{kind: "tool_failure", subject: "task_get:" <> _}] =
               Repo.all(
                 from(r in FrictionEvent,
                   distinct: true,
                   select: %{kind: r.kind, subject: r.subject}
                 )
               )
    end
  end
end
