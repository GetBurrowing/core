defmodule Platform.Designer.LoopTest do
  @moduledoc """
  The UX super agent loop (task 01a1f048): the deterministic triggers and
  scout budget (`Platform.Designer.Loop`), the three responsibilities
  (`design.reflect`, `design.scout`, `design.prototype_eval`), the
  cross-vendor evaluator, and the learning card store.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  import Platform.PrototypeFixtures,
    only: [scratch_storage!: 1, set_settings!: 1, agent_publisher: 1, bundle_files: 1]

  alias Platform.Agents.Agent
  alias Platform.Analytics.UsageEvent
  alias Platform.Chat
  alias Platform.Designer.Cards
  alias Platform.Designer.Evaluator
  alias Platform.Designer.Loop
  alias Platform.Org.Wiki
  alias Platform.Prototypes
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.DesignPrototypeEval
  alias Platform.Responsibilities.Handlers.DesignReflect
  alias Platform.Responsibilities.Handlers.DesignScout
  alias Platform.Responsibilities.Router
  alias Platform.Roles

  defmodule CaptureDispatcher do
    @moduledoc false
    def maybe_dispatch(signal) do
      pid = Application.get_env(:platform, :designer_loop_test_pid)
      if is_pid(pid), do: send(pid, {:signal, signal})
      :ok
    end
  end

  defmodule StubOpenAI do
    @moduledoc false
    def chat(_credentials, messages, _opts) do
      pid = Application.get_env(:platform, :designer_loop_test_pid)
      if is_pid(pid), do: send(pid, {:evaluator_saw, messages})

      {:ok,
       %{
         content:
           ~s({"scores": {"task_success": 4, "steps_to_goal": 3, "clarity": 5, ) <>
             ~s("consistency": 4, "accessibility": 2}, "top_issue": "Low contrast on the CTA", ) <>
             ~s("notes": "Clear flow."})
       }}
    end
  end

  setup do
    Application.put_env(:platform, :designer_loop_test_pid, self())

    Application.put_env(
      :platform,
      :responsibility_router_native_dispatcher,
      {CaptureDispatcher, :maybe_dispatch}
    )

    on_exit(fn ->
      Application.delete_env(:platform, :designer_loop_test_pid)
      Application.delete_env(:platform, :responsibility_router_native_dispatcher)
      Application.delete_env(:platform, :design_evaluator_model)
      Application.delete_env(:platform, :design_evaluator_provider)
    end)

    for handler <- [DesignReflect, DesignScout, DesignPrototypeEval],
        spec <- handler.register() do
      {:ok, _} = Responsibilities.upsert_by_key(spec)
    end

    home = space!()
    designer = agent!(%{Cards.home_key() => home.id})
    join!(home, designer)

    for key <- ~w(design.reflect design.scout design.prototype_eval) do
      {:ok, _} = Roles.set_override(key, designer.id)
    end

    %{designer: designer, home: home}
  end

  defp agent!(metadata \\ %{}) do
    %Agent{}
    |> Agent.changeset(%{
      slug: "loop-#{System.unique_integer([:positive])}",
      name: "UX",
      status: "active",
      kind: "native",
      runtime_type: "external",
      metadata: metadata
    })
    |> Repo.insert!()
  end

  defp space! do
    n = System.unique_integer([:positive])
    {:ok, space} = Chat.create_space(%{name: "home-#{n}", slug: "home-#{n}", kind: "channel"})
    space
  end

  defp join!(space, agent) do
    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        joined_at: DateTime.utc_now()
      })
  end

  defp usage!(agent, tokens, at) do
    %UsageEvent{}
    |> Ecto.Changeset.change(%{
      agent_id: agent.id,
      input_tokens: tokens,
      output_tokens: 0,
      inserted_at: at
    })
    |> Repo.insert!()
  end

  describe "triggers" do
    test "a design job finished by the designer fires design.reflect; anyone else's does not",
         %{designer: designer} do
      task_id = Ecto.UUID.generate()

      capture_log(fn ->
        Loop.observe(
          "task_attach_canvas",
          %{"task_id" => task_id},
          %{agent_id: designer.id},
          {:ok, %{}}
        )
      end)

      assert_receive {:signal, signal}, 2_000
      assert signal.metadata.responsibility_key == "design.reflect"
      assert signal.metadata.prompt =~ "Job: task_attach_canvas"
      assert signal.metadata.prompt =~ task_id

      stranger = agent!()

      Loop.observe("task_attach_canvas", %{}, %{agent_id: stranger.id}, {:ok, %{}})
      Loop.observe("task_get", %{}, %{agent_id: designer.id}, {:ok, %{}})
      Loop.observe("task_attach_canvas", %{}, %{agent_id: designer.id}, {:error, %{}})
      refute_receive {:signal, _}, 100
    end

    test "reflect does not move a card a human merely agreed with: only the server does" do
      {:ok, %{user: user}} = DesignReflect.build_prompt(%{job: "x", card_moves: []})
      assert user =~ "never raises a card"
      assert user =~ "up to 0.7"
      assert user =~ "used_in_tasks"
    end
  end

  describe "scout" do
    test "is cron'd twice a week" do
      assert DesignScout.cron_expression() == "0 9 * * 1,4"
    end

    test "budget is 2x the median weekly tokens, and a spent week skips the hand-off",
         %{designer: designer} do
      now = ~U[2026-11-18 12:00:00.000000Z]
      # Monday of `now`'s week is 2026-11-16; three complete weeks before it.
      usage!(designer, 100_000, ~U[2026-11-10 10:00:00.000000Z])
      usage!(designer, 300_000, ~U[2026-11-03 10:00:00.000000Z])
      usage!(designer, 200_000, ~U[2026-10-27 10:00:00.000000Z])

      budget = Loop.scout_budget(designer.id, now)
      assert budget.median_weekly == 200_000
      assert budget.weekly_cap == 400_000
      assert budget.allowance == 200_000

      usage!(designer, 390_000, ~U[2026-11-17 10:00:00.000000Z])
      spent = Loop.scout_budget(designer.id, now)
      assert spent.allowance == 10_000

      usage!(designer, 50_000, ~U[2026-11-17 11:00:00.000000Z])
      assert Loop.scout_budget(designer.id, now).allowance == 0

      assert {:error, {:no_measurement, :scout_budget_spent}} =
               DesignScout.build_prompt(%{budget: %{allowance: 0}})
    end

    test "with no history the configured default cap applies", %{designer: designer} do
      budget = Loop.scout_budget(designer.id)
      assert budget.weekly_cap == 400_000
      assert budget.weeks_of_history == 0
    end

    test "the prompt sends the scout to the web and writes untested cards", %{designer: designer} do
      {:ok, ctx} = DesignScout.gather_context(%Responsibilities.Responsibility{}, %{})
      {:ok, %{user: user}} = DesignScout.build_prompt(ctx)

      assert user =~ "WebSearch and WebFetch"
      assert user =~ "product sites, design galleries and release notes"
      assert user =~ "status: untested"
      assert user =~ "60%"
      assert user =~ Cards.prefix(designer)
    end
  end

  describe "prototype_eval" do
    setup %{designer: designer} do
      scratch_storage!("designer_loop_test")
      set_settings!(%{enabled: true, who_may_publish: "members", retention_days: 90})

      org_id =
        Platform.TenancyFixtures.tenant_org_id("loop-#{System.unique_integer([:positive])}")

      {:ok, %{prototype: proto, version: version}} =
        Prototypes.publish(
          agent_publisher(designer),
          %{org_id: org_id, name: "Checkout"},
          {:files, bundle_files("v1")}
        )

      %{proto: proto, version: version.version}
    end

    test "with no evaluator configured, the designer is dispatched a self-assessment",
         %{designer: designer, proto: proto, version: version} do
      capture_log(fn ->
        Loop.observe(
          "prototype_publish",
          %{},
          %{agent_id: designer.id},
          {:ok, %{prototype_id: proto.id, version: version}}
        )
      end)

      assert_receive {:signal, signal}, 2_000
      assert signal.metadata.responsibility_key == "design.prototype_eval"
      assert signal.metadata.prompt =~ "SELF-ASSESSMENT"
      refute_receive {:evaluator_saw, _}, 50
    end

    test "with the OpenAI evaluator, the server grades, saves the scorecard and reflects",
         %{designer: designer, proto: proto, version: version} do
      Application.put_env(:platform, :design_evaluator_model, %{provider: "openai", model: "m"})
      Application.put_env(:platform, :design_evaluator_provider, StubOpenAI)

      capture_log(fn ->
        assert {:ok, :handled} =
                 Router.fire("design.prototype_eval", %{
                   kind: :event_topic,
                   prototype_id: proto.id,
                   version: version
                 })
      end)

      assert_receive {:evaluator_saw, messages}
      assert Enum.any?(messages, &(&1.content =~ "v1"))

      # No prompt to grade itself; the reflection gets the scorecard.
      assert_receive {:signal, signal}, 2_000
      assert signal.metadata.responsibility_key == "design.reflect"
      assert signal.metadata.prompt =~ "Low contrast on the CTA"

      path =
        String.replace_suffix(Cards.prefix(designer), "patterns/", "evaluations/") <>
          "#{proto.id}-v#{version}.md"

      assert %{frontmatter: %{"overall" => 3.6}} = Wiki.get_page(path)
    end

    test "an unknown prototype is refused, not evaluated" do
      assert {:error, :prototype_not_found} =
               DesignPrototypeEval.gather_context(%Responsibilities.Responsibility{}, %{
                 prototype_id: Ecto.UUID.generate(),
                 version: 1
               })
    end
  end

  describe "evaluator" do
    test "is off by default and makes no call" do
      assert Evaluator.status() == {:off, :not_configured}
      assert Evaluator.grade("<html></html>", "x") == {:error, :not_configured}
      refute_receive {:evaluator_saw, _}, 20
    end

    test "only an OpenAI provider counts as configured" do
      Application.put_env(:platform, :design_evaluator_model, %{provider: "anthropic"})
      assert Evaluator.status() == {:off, :not_configured}
    end

    test "parse refuses a scorecard missing a criterion or out of range" do
      assert {:error, :unparseable} = Evaluator.parse(~s({"scores": {"clarity": 5}}))

      assert {:error, :unparseable} =
               Evaluator.parse(
                 ~s({"scores": {"task_success": 9, "steps_to_goal": 3, "clarity": 5, "consistency": 4, "accessibility": 2}})
               )
    end
  end

  describe "cards" do
    test "seed writes the starter set once, create-only", %{designer: designer} do
      assert {:ok, %{written: n, kept: 0}} = Cards.seed(designer)
      assert n >= 20

      [path | _] = Enum.map(Wiki.list_pages_under(Cards.prefix(designer)), & &1.file_key)
      {:ok, _} = Wiki.upsert_page(path, %{content: "operator edit"})

      assert {:ok, %{written: 0, kept: ^n}} = Cards.seed(designer)
      assert Wiki.get_page(path).content == "operator edit"

      for {_slug, content} <- Cards.seed_cards() do
        {fm, _} = Wiki.parse_frontmatter(content)
        assert fm["weight"] == 0.5
        assert fm["status"] == "seeded"
        assert is_binary(fm["provenance"])
        refute content =~ ~r/kobo/i
      end
    end

    test "seed refuses without a home space" do
      assert {:error, :no_home_space} = Cards.seed(agent!())
    end

    test "weight moves only on settled outcomes, once per task" do
      assert Cards.delta(0.5) == 0.1
      assert Cards.delta(0.1) == 0.0
      assert Cards.delta(0.0) == -0.1
      assert Cards.delta(-0.4) == -0.1
      assert Cards.delta(nil) == 0.0
    end

    test "reweigh leaves a card whose tasks have not shipped untouched", %{designer: designer} do
      path = Cards.prefix(designer) <> "x.md"

      content = """
      ---
      title: "X"
      status: untested
      weight: 0.4
      used_in_tasks: ["#{Ecto.UUID.generate()}"]
      weighed_tasks: []
      ---
      # X
      """

      {:ok, _} = Wiki.upsert_page(path, %{content: content})
      assert {:ok, []} = Cards.reweigh(designer)
      assert Wiki.get_page(path).content == content
    end
  end
end
