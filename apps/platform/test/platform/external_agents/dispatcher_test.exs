defmodule Platform.ExternalAgents.DispatcherTest do
  @moduledoc """
  Tests for `Platform.ExternalAgents.Dispatcher` (ADR-0041 M6 stage 5).

  Exercises both endpoint kinds (openai_compat + ollama_native), the
  output contract validator wiring, the error path, and the telemetry
  surface. Mirrors the Req.Test stub pattern from
  `Platform.ExternalAgentsTest`'s probe describe-block — register a
  named stub, point the dispatcher's injected Req client at it via
  `Application.put_env/3`, clear the env on exit.

  ## Why this file is a `DataCase` (task 019fba51 stage 1)

  It used to be `use ExUnit.Case, async: false` — no Ecto sandbox
  checkout at all. That was harmless while the dispatcher never touched
  the database, and becomes a silent trap the moment it does:
  `PromptTemplates.render_template/2`
  (lib/platform/orchestration/prompt_templates.ex:88) wraps its Repo
  call in a bare `rescue _ -> {:error, :not_found}`, so a checkout-less
  caller does not blow up — it gets told the row does not exist.

  Measured in this exact file, before the conversion:

      [PROBE] get_template_by_slug/1 -> {:rescued, DBConnection.OwnershipError}
      [PROBE] render_template/2      -> {:error, :not_found}

  and after it:

      [PROBE] get_template_by_slug/1 -> {:raised, %Platform.Orchestration.PromptTemplate{...}}
      [PROBE] render_template/2      -> {:ok, "You are the Triage Officer's ..."}

  Without the conversion every template-aware test added here would
  resolve the missing-row branch and pass while exercising nothing.
  """
  use Platform.DataCase, async: false

  alias Platform.ExternalAgents.{ContractValidator, Dispatcher, EphemeralCredentials}
  alias Platform.Orchestration.{PromptTemplate, PromptTemplates}
  alias Platform.Responsibilities.BuiltIns
  alias Platform.Responsibilities.Responsibility

  @telemetry_called [:platform, :external_agent, :called]
  @telemetry_error [:platform, :external_agent, :error]

  # ── task 019fba51 stage 1 — the builder-less inventory ──────────────────
  #
  # A responsibility key reaches `Dispatcher.legacy_messages/2` when its
  # FEATURE provider yields `:legacy` from
  # `Router.build_prompt_via_provider/2` (router.ex:1339).
  # `Providers.Memory` and `Providers.Tasks` export no `build_prompt/1` at
  # all; `Providers.Meetings` / `Design` / `Architecture` delegate per key
  # and only six HANDLERS export one (MeetingSummarize, MeetingActionItems,
  # DesignTaskDirection, ArchitectureCronSweep, ArchitectureReviewPlan,
  # ArchitectureAuditDiff). Everything else takes the legacy render.
  #
  # Pinned as an EXPLICIT list, and cross-checked below against the live
  # registry, so a twelfth builder-less key is a deliberate edit here
  # rather than a silent addition. Re-measured against c44a6663 — the
  # ticket's table says ten and omits `memory.daily_summary`.
  @builder_less_keys [
    "design.brand_check",
    "design.critique",
    "design.spec_writer",
    "meetings.attendance_followup",
    "meetings.intent_classify",
    "memory.daily_summary",
    "memory.dreaming",
    "memory.propose_long_term",
    "tasks.triage",
    "tasks.unblock",
    "tasks.weekly_review"
  ]

  # The roster slug with NO `prompt_templates` row — not in
  # `PromptTemplates.default_templates/0`, no inserting migration, still
  # carried on `@unseeded_roster_slugs` in
  # test/platform/responsibilities/closed_roster_template_coverage_test.exs.
  #
  # This USED to be `memory.daily_summary.v1`, which task `01a0a74d`
  # stage 2 seeded. It was repointed rather than deleted: the value of this
  # constant is that it names a slug that is really in this state on a real
  # install, not a fixture, and `meetings.summarize.v1` is now the only one
  # left. It is NOT builder-less — hence the rename — so it reaches the
  # template render only on the branch below, which is exactly as latent as
  # the old one was.
  @unseeded_roster_slug "meetings.summarize.v1"

  setup do
    {:ok, _} = Application.ensure_all_started(:req)

    Application.put_env(
      :platform,
      :external_agents_dispatcher_req_client,
      Req.new(plug: {Req.Test, :external_agents_dispatcher_test})
    )

    on_exit(fn ->
      Application.delete_env(:platform, :external_agents_dispatcher_req_client)
    end)

    :ok
  end

  defp attach_telemetry(events) do
    handler_id = "dispatcher-telemetry-#{System.unique_integer([:positive, :monotonic])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp build_agent(endpoint_kind, overrides \\ %{}) do
    %{
      id: Ecto.UUID.generate(),
      slug: "ext-test-#{System.unique_integer([:positive])}",
      kind: "external",
      endpoint_kind: endpoint_kind,
      base_url: "https://api.example.test",
      model: "test-model",
      vault_key: nil,
      metadata: %{}
    }
    |> Map.merge(overrides)
  end

  defp build_responsibility(overrides \\ %{}) do
    # `default_prompt_template` is a SLUG resolved against the
    # `prompt_templates` table (task 019fba51 stage 2), so a fixture that
    # wants the legacy render exercised has to put its body where the
    # dispatcher now looks for it. Fixtures that override the key with a
    # real seeded slug (the builder-less inventory block) or that never
    # reach the legacy render at all (the `messages:` / `prompt:` opts
    # blocks) are left alone by `put_new_lazy/3`.
    overrides =
      Map.put_new_lazy(overrides, :default_prompt_template, fn ->
        seed_template("summarise: {topic}")
      end)

    %Responsibility{
      key: "test.dispatch",
      feature: "test",
      trigger_kind: "cron",
      trigger_config: %{"expression" => "0 * * * *"},
      scope: "global",
      context_provided: [],
      output_contract: nil,
      default_prompt_template: nil,
      cost_profile: "low_freq_capable",
      enabled: true,
      metadata: %{}
    }
    |> Map.merge(overrides)
  end

  # Insert a real `prompt_templates` row carrying `content` and return its
  # slug. Unique per call so two fixtures in the same test cannot collide
  # on the slug unique index.
  defp seed_template(content) do
    slug = "dispatcher-test.#{System.unique_integer([:positive])}.v1"

    {:ok, _} =
      PromptTemplates.create_template(%{
        slug: slug,
        name: "dispatcher_test.exs fixture #{slug}",
        description: "Seeded by Platform.ExternalAgents.DispatcherTest",
        variables: [],
        content: content
      })

    slug
  end

  describe "openai_compat" do
    test "200 returns parsed content, hits /chat/completions with Bearer header, fires :called telemetry" do
      attach_telemetry([@telemetry_called, @telemetry_error])
      test_pid = self()

      Req.Test.stub(:external_agents_dispatcher_test, fn conn ->
        send(test_pid, {:dispatch_req, conn})

        Req.Test.json(conn, %{
          "id" => "chatcmpl_test",
          "model" => "test-model",
          "choices" => [
            %{
              "index" => 0,
              "finish_reason" => "stop",
              "message" => %{"role" => "assistant", "content" => "openai answer"}
            }
          ]
        })
      end)

      agent = build_agent("openai_compat")
      :ok = EphemeralCredentials.put(agent.id, "sk-test-token")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      responsibility = build_responsibility()

      assert {:ok, "openai answer"} =
               Dispatcher.dispatch(responsibility, agent, %{topic: "monthly metrics"})

      assert_receive {:dispatch_req, conn}
      assert conn.request_path == "/chat/completions"

      headers = Map.new(conn.req_headers)
      assert headers["authorization"] == "Bearer sk-test-token"
      assert headers["content-type"] == "application/json"

      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["model"] == "test-model"
      assert decoded["stream"] == false
      assert is_list(decoded["messages"])
      assert hd(decoded["messages"])["role"] == "user"
      # Verify {topic} got substituted into the prompt
      assert hd(decoded["messages"])["content"] =~ "monthly metrics"

      assert_receive {:telemetry, @telemetry_called, %{duration_ms: _}, meta}
      assert meta.endpoint_kind == "openai_compat"
      assert meta.agent_slug == agent.slug
      assert meta.responsibility_key == "test.dispatch"
    end
  end

  describe "ollama_native" do
    test "200 returns parsed content, hits /api/chat with NO auth header, fires :called telemetry" do
      attach_telemetry([@telemetry_called, @telemetry_error])
      test_pid = self()

      Req.Test.stub(:external_agents_dispatcher_test, fn conn ->
        send(test_pid, {:dispatch_req, conn})

        Req.Test.json(conn, %{
          "model" => "llama3",
          "message" => %{"role" => "assistant", "content" => "ollama answer"},
          "done" => true
        })
      end)

      agent =
        build_agent("ollama_native", %{
          base_url: "http://localhost:11434",
          model: "llama3"
        })

      responsibility = build_responsibility()

      assert {:ok, "ollama answer"} =
               Dispatcher.dispatch(responsibility, agent, %{topic: "weekly"})

      assert_receive {:dispatch_req, conn}
      assert conn.request_path == "/api/chat"

      refute Enum.any?(conn.req_headers, fn
               {"authorization", _} -> true
               _ -> false
             end)

      assert_receive {:telemetry, @telemetry_called, %{duration_ms: _}, meta}
      assert meta.endpoint_kind == "ollama_native"
    end
  end

  describe "error paths" do
    test "500 returns {:error, {:http_error, 500, body}} and fires :error telemetry" do
      attach_telemetry([@telemetry_called, @telemetry_error])

      Req.Test.stub(:external_agents_dispatcher_test, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, ~s({"error":"boom"}))
      end)

      agent = build_agent("openai_compat")
      :ok = EphemeralCredentials.put(agent.id, "sk-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      responsibility = build_responsibility()

      assert {:error, {:http_error, 500, _body}} =
               Dispatcher.dispatch(responsibility, agent, %{topic: "x"})

      assert_receive {:telemetry, @telemetry_error, %{duration_ms: _}, meta}
      assert meta.endpoint_kind == "openai_compat"
      assert meta.reason =~ "http_error"
    end

    test "transport error surfaces without crashing" do
      Req.Test.stub(:external_agents_dispatcher_test, fn conn ->
        Req.Test.transport_error(conn, :nxdomain)
      end)

      agent =
        build_agent("ollama_native", %{
          base_url: "http://nowhere.test",
          model: "llama3"
        })

      responsibility = build_responsibility()

      assert {:error, %Req.TransportError{reason: :nxdomain}} =
               Dispatcher.dispatch(responsibility, agent, %{})
    end
  end

  describe "ContractValidator" do
    test ":freeform / nil contract passes the raw string through" do
      assert {:ok, "hello"} = ContractValidator.validate("hello", nil)
      assert {:ok, "hello"} = ContractValidator.validate("hello", :freeform)
      assert {:ok, "hello"} = ContractValidator.validate("hello", %{})
      assert {:ok, "hello"} = ContractValidator.validate("hello", %{"type" => "freeform"})
    end

    test ":json contract — valid JSON → decoded map" do
      assert {:ok, %{"answer" => 42}} =
               ContractValidator.validate(~s({"answer": 42}), :json)

      assert {:ok, %{"answer" => 42}} =
               ContractValidator.validate(~s({"answer": 42}), %{"type" => "object"})

      assert {:ok, %{"answer" => 42}} =
               ContractValidator.validate(~s({"answer": 42}), %{"type" => "json"})
    end

    test ":json contract — invalid JSON → {:error, {:contract_violation, :invalid_json}}" do
      assert {:error, {:contract_violation, :invalid_json}} =
               ContractValidator.validate("not json at all", :json)

      assert {:error, {:contract_violation, :invalid_json}} =
               ContractValidator.validate("{broken", %{"type" => "object"})
    end

    test "non-string input is a contract violation" do
      assert {:error, {:contract_violation, :invalid_payload}} =
               ContractValidator.validate(123, :freeform)
    end
  end

  describe "contract integration with dispatch/3" do
    setup do
      test_pid = self()

      Req.Test.stub(:external_agents_dispatcher_test, fn conn ->
        send(test_pid, {:dispatch_req, conn})

        Req.Test.json(conn, %{
          "choices" => [
            %{
              "message" => %{"role" => "assistant", "content" => ~s({"verdict": "ship"})}
            }
          ]
        })
      end)

      :ok
    end

    test ":json contract on responsibility decodes the assistant content" do
      agent = build_agent("openai_compat")
      :ok = EphemeralCredentials.put(agent.id, "sk-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      responsibility = build_responsibility(%{output_contract: %{"type" => "object"}})

      assert {:ok, %{"verdict" => "ship"}} =
               Dispatcher.dispatch(responsibility, agent, %{topic: "ship-it"})
    end

    test ":freeform contract returns the raw assistant content" do
      agent = build_agent("openai_compat")
      :ok = EphemeralCredentials.put(agent.id, "sk-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      # Default output_contract is nil → freeform
      responsibility = build_responsibility()

      assert {:ok, ~s({"verdict": "ship"})} =
               Dispatcher.dispatch(responsibility, agent, %{topic: "ship-it"})
    end
  end

  # ── task 019f2570 stage 1 — pre-built messages / prompt overrides ──────
  describe "dispatch/4 opts overrides (task 019f2570)" do
    setup do
      test_pid = self()

      Req.Test.stub(:external_agents_dispatcher_test, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:dispatch_body, conn, body})

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]
        })
      end)

      :ok
    end

    test "explicit messages: [...] bypasses default_prompt_template render" do
      agent = build_agent("openai_compat")
      :ok = EphemeralCredentials.put(agent.id, "sk-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      # Bogus, un-seeded template string — must NOT reach the request body.
      responsibility = build_responsibility(%{default_prompt_template: "meetings.summarize.v1"})

      messages = [
        %{role: "system", content: "grounded system"},
        %{role: "user", content: "here is the transcript: hi"}
      ]

      assert {:ok, "ok"} =
               Dispatcher.dispatch(responsibility, agent, %{}, messages: messages)

      assert_receive {:dispatch_body, _conn, raw_body}
      decoded = Jason.decode!(raw_body)

      assert decoded["messages"] == [
               %{"role" => "system", "content" => "grounded system"},
               %{"role" => "user", "content" => "here is the transcript: hi"}
             ]

      refute Enum.any?(decoded["messages"], &(&1["content"] =~ "meetings.summarize.v1"))
    end

    test "prompt: %{system, user} is converted to a two-turn messages list" do
      agent = build_agent("openai_compat")
      :ok = EphemeralCredentials.put(agent.id, "sk-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      responsibility = build_responsibility(%{default_prompt_template: "junk"})

      assert {:ok, _} =
               Dispatcher.dispatch(responsibility, agent, %{},
                 prompt: %{system: "sys text", user: "user text"}
               )

      assert_receive {:dispatch_body, _conn, raw_body}
      decoded = Jason.decode!(raw_body)

      roles = Enum.map(decoded["messages"], & &1["role"])
      assert roles == ["system", "user"]
      assert Enum.at(decoded["messages"], 0)["content"] == "sys text"
      assert Enum.at(decoded["messages"], 1)["content"] == "user text"
    end

    test "prompt: %{system: \"\", user: user} emits a single-turn user message" do
      agent = build_agent("openai_compat")
      :ok = EphemeralCredentials.put(agent.id, "sk-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      responsibility = build_responsibility()

      assert {:ok, _} =
               Dispatcher.dispatch(responsibility, agent, %{},
                 prompt: %{system: "", user: "just a user turn"}
               )

      assert_receive {:dispatch_body, _conn, raw_body}
      decoded = Jason.decode!(raw_body)
      assert decoded["messages"] == [%{"role" => "user", "content" => "just a user turn"}]
    end

    test "dispatch/3 remains backward-compatible with the legacy template render" do
      agent = build_agent("openai_compat")
      :ok = EphemeralCredentials.put(agent.id, "sk-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      # Standard {key} substitution — pre-019f2570 contract, now applied to
      # the resolved template BODY rather than to the slug.
      responsibility =
        build_responsibility(%{default_prompt_template: seed_template("cover: {topic}")})

      assert {:ok, _} = Dispatcher.dispatch(responsibility, agent, %{topic: "quarterly"})

      assert_receive {:dispatch_body, _conn, raw_body}
      decoded = Jason.decode!(raw_body)
      user = Enum.find(decoded["messages"], &(&1["role"] == "user"))
      assert user["content"] =~ "quarterly"
    end

    # ── task 019fba51 stage 2 — the assign-normalisation guard ────────────
    #
    # `PromptTemplates.interpolate/2` calls `to_string/1` on every matched
    # assign, and `render_template/2` wraps the whole render in
    # `rescue -> {:error, :not_found}`. So a context value that does not
    # implement `String.Chars` — a nested map, which is what
    # `Handlers.Dreaming.gather_context/2` returns for `org_identity` —
    # would be reported as a MISSING TEMPLATE for a row that plainly
    # exists, and the dispatch would abort.
    #
    # This is the assertion that makes `template_assigns/1` +
    # `printable_assign/1` (mirrored from router.ex:2058-2068) load-bearing
    # rather than defensive. Drop the `inspect/1` fallback clause and this
    # test fails with `{:error, {:template_missing, ...}}`.
    test "a nested context value renders instead of masquerading as a missing template" do
      agent = build_agent("openai_compat")
      :ok = EphemeralCredentials.put(agent.id, "sk-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      slug = seed_template("identity: {{org_identity}}")
      responsibility = build_responsibility(%{default_prompt_template: slug})

      assert {:ok, _} =
               Dispatcher.dispatch(responsibility, agent, %{org_identity: %{missing?: true}})

      assert_receive {:dispatch_body, _conn, raw_body}
      decoded = Jason.decode!(raw_body)
      user = Enum.find(decoded["messages"], &(&1["role"] == "user"))

      # `inspect/1` of the map, computed here rather than read back from
      # the dispatcher, and asserted whole so a bare "identity: " cannot
      # pass.
      assert user["content"] == "identity: " <> inspect(%{missing?: true})
    end

    # ── task 019fba51 stage 2 — the split_prompt/1 guard ──────────────────
    #
    # A FINDING, TURNED INTO A CONTROL. The eleven-key block's
    # `length(messages) == 1` assertion was supposed to keep
    # `split_prompt/1` in the resolved-body pipeline, and it does not:
    # bypassing the call entirely (`|> then(&{nil, &1})`) leaves all 55
    # tests in dispatcher_test.exs + prompt_outcome_test.exs GREEN, because
    # not one of the ten seeded bodies opens with a `<system>` block
    # (measured against the live rows). A guard that cannot detonate is
    # not a guard.
    #
    # This is the control that does exercise the branch, and it is the
    # behaviour the stage contract names explicitly: a seeded body whose
    # head is a `<system>...</system>` block must still become a two-turn
    # messages list. Bypass `split_prompt/1` and this test fails with a
    # single user turn carrying the raw `<system>` markup.
    test "a seeded body opening with <system> still splits into two turns" do
      agent = build_agent("openai_compat")
      :ok = EphemeralCredentials.put(agent.id, "sk-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      slug = seed_template("<system>You are terse.</system>\nSummarise {topic}.")
      responsibility = build_responsibility(%{default_prompt_template: slug})

      assert {:ok, _} = Dispatcher.dispatch(responsibility, agent, %{topic: "the backlog"})

      assert_receive {:dispatch_body, _conn, raw_body}
      decoded = Jason.decode!(raw_body)

      assert decoded["messages"] == [
               %{"role" => "system", "content" => "You are terse."},
               %{"role" => "user", "content" => "Summarise the backlog."}
             ]
    end
  end

  # ── task 019f2570 stage 2 — max_tokens plumbing (bug 2) ────────────────
  describe "max_tokens plumbing (task 019f2570 bug 2)" do
    setup do
      test_pid = self()

      Req.Test.stub(:external_agents_dispatcher_test, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:dispatch_body, conn, body})

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]
        })
      end)

      :ok
    end

    test "responsibility metadata['max_tokens'] rides on the POST body" do
      agent = build_agent("openai_compat")
      :ok = EphemeralCredentials.put(agent.id, "sk-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      responsibility =
        build_responsibility(%{metadata: %{"max_tokens" => 2500, "owner" => "platform.meetings"}})

      assert {:ok, _} = Dispatcher.dispatch(responsibility, agent, %{topic: "quarterly"})

      assert_receive {:dispatch_body, _conn, raw_body}
      decoded = Jason.decode!(raw_body)
      assert decoded["max_tokens"] == 2500
      assert decoded["stream"] == false
      assert decoded["model"] == "test-model"
    end

    test "absent metadata max_tokens hint falls back to module default (2500)" do
      agent = build_agent("openai_compat")
      :ok = EphemeralCredentials.put(agent.id, "sk-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      responsibility = build_responsibility(%{metadata: %{}})

      assert {:ok, _} = Dispatcher.dispatch(responsibility, agent, %{topic: "quarterly"})

      assert_receive {:dispatch_body, _conn, raw_body}
      decoded = Jason.decode!(raw_body)
      assert decoded["max_tokens"] == 2500
    end

    test "metadata hint wins over the module default (contrived 800 override)" do
      agent = build_agent("openai_compat")
      :ok = EphemeralCredentials.put(agent.id, "sk-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      responsibility = build_responsibility(%{metadata: %{"max_tokens" => 800}})

      assert {:ok, _} = Dispatcher.dispatch(responsibility, agent, %{topic: "quarterly"})

      assert_receive {:dispatch_body, _conn, raw_body}
      decoded = Jason.decode!(raw_body)
      assert decoded["max_tokens"] == 800
    end

    test "non-integer / non-positive metadata hints fall through to the default" do
      agent = build_agent("openai_compat")
      :ok = EphemeralCredentials.put(agent.id, "sk-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      for bogus <- ["nonsense", 0, -50, nil, 3.14] do
        responsibility = build_responsibility(%{metadata: %{"max_tokens" => bogus}})

        assert {:ok, _} = Dispatcher.dispatch(responsibility, agent, %{topic: "x"})

        assert_receive {:dispatch_body, _conn, raw_body}
        decoded = Jason.decode!(raw_body)
        assert decoded["max_tokens"] == 2500, "bogus=#{inspect(bogus)} should fall through"
      end
    end

    test "atom-keyed metadata hint is also honoured" do
      agent = build_agent("openai_compat")
      :ok = EphemeralCredentials.put(agent.id, "sk-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      responsibility = build_responsibility(%{metadata: %{max_tokens: 1500}})

      assert {:ok, _} = Dispatcher.dispatch(responsibility, agent, %{topic: "x"})

      assert_receive {:dispatch_body, _conn, raw_body}
      decoded = Jason.decode!(raw_body)
      assert decoded["max_tokens"] == 1500
    end

    test "max_tokens is present on ollama_native dispatches too" do
      test_pid = self()

      # Override the describe-block stub — ollama_native's parse_response
      # expects `%{"message" => %{"content" => ...}}`, not `"choices"`.
      Req.Test.stub(:external_agents_dispatcher_test, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:dispatch_body, conn, body})

        Req.Test.json(conn, %{
          "model" => "llama3",
          "message" => %{"role" => "assistant", "content" => "ok"},
          "done" => true
        })
      end)

      agent =
        build_agent("ollama_native", %{
          base_url: "http://localhost:11434",
          model: "llama3"
        })

      responsibility = build_responsibility(%{metadata: %{"max_tokens" => 2500}})

      assert {:ok, _} = Dispatcher.dispatch(responsibility, agent, %{topic: "x"})

      assert_receive {:dispatch_body, _conn, raw_body}
      decoded = Jason.decode!(raw_body)
      assert decoded["max_tokens"] == 2500
    end
  end

  # ── task 019f2566 stage 3 — agent-kind context merge ────────────────────
  describe "agent-kind context merge (task 019f2566 stage 3)" do
    setup do
      test_pid = self()

      Req.Test.stub(:external_agents_dispatcher_test, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:dispatch_body, conn, body})

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]
        })
      end)

      :ok
    end

    test "external-kind agent → context.agent_kind := :ext_single_responsibility during legacy render" do
      # Template that references {agent_kind} so we can observe the
      # merged value landed on context BEFORE render_prompt/2 ran.
      responsibility =
        build_responsibility(%{
          default_prompt_template: seed_template("kind={agent_kind} topic={topic}")
        })

      agent = build_agent("openai_compat")
      :ok = EphemeralCredentials.put(agent.id, "sk-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      assert {:ok, _} = Dispatcher.dispatch(responsibility, agent, %{topic: "x"})

      assert_receive {:dispatch_body, _conn, raw_body}
      decoded = Jason.decode!(raw_body)

      user = Enum.find(decoded["messages"], &(&1["role"] == "user"))
      assert user["content"] =~ "kind=ext_single_responsibility"
      assert user["content"] =~ "topic=x"
    end

    test "caller-supplied :agent_kind on context is respected (no override)" do
      # If the router's provider gather_context already stamped an
      # agent_kind onto the map, the dispatcher must NOT clobber it.
      responsibility =
        build_responsibility(%{default_prompt_template: seed_template("kind={agent_kind}")})

      # Provide an ext agent, but a context claiming fed_conversational
      # — the caller-supplied value wins.
      agent = build_agent("openai_compat")
      :ok = EphemeralCredentials.put(agent.id, "sk-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      assert {:ok, _} =
               Dispatcher.dispatch(responsibility, agent, %{agent_kind: :fed_conversational})

      assert_receive {:dispatch_body, _conn, raw_body}
      decoded = Jason.decode!(raw_body)

      user = Enum.find(decoded["messages"], &(&1["role"] == "user"))
      assert user["content"] =~ "kind=fed_conversational"
    end

    test "missing agent_kind on context → backfilled from agent shape (belt+braces)" do
      # Federated-shape agent (native + runtime_type=external, but
      # external-endpoint metadata for dispatch to actually go
      # through — the test is about the classify result, not the
      # network hop).
      responsibility =
        build_responsibility(%{default_prompt_template: seed_template("kind={agent_kind}")})

      agent =
        build_agent("openai_compat", %{
          kind: "native",
          runtime_type: "external"
        })

      :ok = EphemeralCredentials.put(agent.id, "sk-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      assert {:ok, _} = Dispatcher.dispatch(responsibility, agent, %{})

      assert_receive {:dispatch_body, _conn, raw_body}
      decoded = Jason.decode!(raw_body)

      user = Enum.find(decoded["messages"], &(&1["role"] == "user"))
      assert user["content"] =~ "kind=fed_conversational"
    end
  end

  # ── task 019fba51 stage 2 — the inverted characterisation ───────────────
  #
  # Stage 1 pinned the defect here: `legacy_messages/2` handed
  # `responsibility.default_prompt_template` — a template SLUG — straight
  # to a render that EEx-evaluated it, `{var}`-substituted it, and shipped
  # it, so the model received the 15-to-30 character string
  # `tasks.triage.v1` where the seeded 478-character body was intended.
  #
  # This block is that block with its assertions flipped. `legacy_messages/2`
  # now resolves the slug through `PromptTemplates.render_template/2` and
  # feeds the ROW'S BODY through the same `substitute_placeholders/2` +
  # `split_prompt/1` pipeline.
  #
  # The four assertions per seeded key are load-bearing together:
  #   * `length(messages) == 1` — none of the ten seeded bodies opens with a
  #     `<system>` block (measured against the live rows), so the resolved
  #     body must still arrive as a single user turn. If `split_prompt/1`
  #     were dropped from the pipeline a future `<system>`-headed body would
  #     silently stop splitting; this is the assertion that keeps the call
  #     in place.
  #   * `content == expected_template_body(row)` — byte equality against a
  #     value the TEST computes (see `expected_template_body/1`), not
  #     against `PromptTemplates.render_template/2`'s return, which is the
  #     collaborator the dispatcher itself calls.
  #   * `content != slug` — asserted alongside the equality because
  #     `content != slug` alone passes on the empty string, which is a
  #     DIFFERENT defect (a paid round-trip carrying nothing).
  #   * the unseeded member must NOT reach the network at all — it aborts
  #     with `{:error, {:template_missing, slug}}` before `post/3`.
  describe "the external legacy render resolves every builder-less key's slug to its body" do
    setup do
      test_pid = self()

      Req.Test.stub(:external_agents_dispatcher_test, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:dispatch_body, conn, body})

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]
        })
      end)

      :ok
    end

    test "the pinned inventory still matches the live registry" do
      registry = registered_slugs()

      # A zero-length or short sweep would make every per-key test below
      # vacuous, so the count is asserted before anything uses it.
      assert length(@builder_less_keys) == 11

      Enum.each(@builder_less_keys, fn key ->
        assert Map.has_key?(registry, key),
               "#{key} is no longer registered by any BuiltIns provider — the tree moved; " <>
                 "re-derive the builder-less set rather than editing this list to match"

        assert Map.fetch!(registry, key) == key <> ".v1",
               "#{key} no longer names #{key}.v1 as its default_prompt_template"
      end)
    end

    for key <- @builder_less_keys do
      test "#{key} reaches the model as its template body, never its slug" do
        key = unquote(key)
        slug = Map.fetch!(registered_slugs(), key)

        agent = build_agent("openai_compat")
        :ok = EphemeralCredentials.put(agent.id, "sk-test")
        on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

        responsibility =
          build_responsibility(%{
            key: key,
            feature: hd(String.split(key, ".")),
            default_prompt_template: slug
          })

        case PromptTemplates.get_template_by_slug(slug) do
          nil ->
            # The missing-row member. Stage 3 owns the final taxonomy and
            # the abort plumbing; what stage 2 pins is that a slug naming
            # no row does NOT become a paid round-trip carrying the slug.
            assert slug == @unseeded_roster_slug,
                   "#{key}: has no prompt_templates row but is not the pinned unseeded slug " <>
                     "(#{@unseeded_roster_slug}) — the seeding gap moved"

            assert {:error, {:template_missing, ^slug}} =
                     Dispatcher.dispatch(responsibility, agent, %{})

            refute_receive {:dispatch_body, _conn, _raw}, 200

          template ->
            refute String.trim(template.content) == "",
                   "#{key}: row exists but is blank — this test would compare against nothing"

            expected = expected_template_body(template.content)

            refute String.trim(expected) == "",
                   "#{key}: row renders to nothing once its placeholders are stripped"

            assert {:ok, "ok"} = Dispatcher.dispatch(responsibility, agent, %{})

            assert_receive {:dispatch_body, _conn, raw_body}
            messages = Jason.decode!(raw_body)["messages"]

            assert length(messages) == 1,
                   "#{key}: expected a single user turn, got #{inspect(messages)}"

            assert hd(messages)["role"] == "user", "#{key}: the only turn must be a user turn"

            assert hd(messages)["content"] == expected,
                   "#{key}: the seeded body is expected to reach the model verbatim"

            # Asserted ALONGSIDE the equality, not instead of it: on its own
            # this passes for an empty payload, which is a different defect.
            assert hd(messages)["content"] != slug,
                   "#{key}: the bare slug must never reach the model"
        end
      end
    end
  end

  # ── task 019fba51 stage 3 — abort before the HTTP call ──────────────────
  #
  # The stage-2 block above proves a slug that HAS a row reaches the model as
  # its body. This block owns the other half: when the named prompt cannot be
  # produced, the dispatch must abort BEFORE `post/2` — not emit the slug
  # (the model gets the NAME of its prompt), and not emit an empty user turn
  # either (a paid round-trip that can only return garbage).
  #
  # EVERY TEST HERE ASSERTS THE ABSENCE OF THE HTTP CALL, not just the return
  # value. `{:error, ...}` from `dispatch/4` is compatible with a request
  # having been sent and its response discarded; `refute_receive
  # {:dispatch_body, ...}` is what pins "before". That refute is only worth
  # anything if the stub would genuinely have fired, so the first test in the
  # block is the positive control for it: same setup, same stub, same agent,
  # only the slug differs, and it DOES receive.
  #
  # A FINDING, RECORDED (same class as stage 2's M4). Neither mutation the
  # stage prescribed actually exercises the no-HTTP assertions. Making the
  # missing-row branch fall back to the slug, and making it return `{:ok,
  # ""}`, both go red — 4 tests each — but they go red on the RETURN-VALUE
  # assertion, which runs first and ends the test before
  # `drain_dispatch_bodies/1` is ever called. A mutation that broke only the
  # ordering would have sailed through both.
  #
  # The control that isolates it: fire `post/2` speculatively BEFORE
  # `resolve_messages/3` in `dispatch/4` and discard its result. Every return
  # value is then unchanged, so every return-value assertion stays green, and
  # exactly the emptiness assertions detonate —
  #
  #     assert drain_dispatch_bodies() == []
  #     left:  ["{\"messages\":[{\"role\":\"user\",\"content\":\"speculative\"}],...}"]
  #     right: []
  #
  # 32 red across the file, 8 of them in this block on that line alone. That
  # is the run which proves "before" is pinned by something; the two
  # prescribed mutations only prove the return values are.
  describe "a prompt that cannot be produced aborts before the HTTP call (task 019fba51 stage 3)" do
    setup do
      test_pid = self()

      Req.Test.stub(:external_agents_dispatcher_test, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:dispatch_body, conn, body})

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]
        })
      end)

      agent = build_agent("openai_compat")
      :ok = EphemeralCredentials.put(agent.id, "sk-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      %{agent: agent}
    end

    # THE POSITIVE CONTROL. Nothing below this test means anything without
    # it: a `refute_receive` against a stub that never fires for any input
    # would pass on a dispatcher that had been deleted.
    test "control — the stub every refute below relies on does fire on a resolvable slug",
         %{agent: agent} do
      responsibility =
        build_responsibility(%{default_prompt_template: seed_template("body: {topic}")})

      assert {:ok, "ok"} = Dispatcher.dispatch(responsibility, agent, %{topic: "x"})

      assert_receive {:dispatch_body, _conn, raw_body}

      assert Jason.decode!(raw_body)["messages"] == [
               %{"role" => "user", "content" => "body: x"}
             ]
    end

    test "a slug naming no row aborts with {:template_missing, slug}", %{agent: agent} do
      slug = "dispatcher-test.absent.#{System.unique_integer([:positive])}.v1"
      refute PromptTemplates.get_template_by_slug(slug), "fixture slug must name no row"

      responsibility = build_responsibility(%{default_prompt_template: slug})

      assert {:error, {:template_missing, ^slug}} =
               Dispatcher.dispatch(responsibility, agent, %{topic: "x"})

      bodies = drain_dispatch_bodies()

      assert bodies == [],
             "the abort must not reach the wire at all, got #{inspect(bodies)}"

      # Subsumed by the assertion above — stated separately because it names
      # the specific defect stage 2 fixed (the bare slug arriving as the
      # prompt), so a future weakening of the emptiness check still leaves
      # this one standing.
      refute Enum.any?(bodies, &(&1 =~ slug)),
             "the slug must never appear in a request payload"
    end

    # The live instance, not a synthetic one. `meetings.summarize.v1` has
    # no row in `default_templates/0`, no inserting migration, and no row in
    # production; it is carried on `@unseeded_roster_slugs` in
    # closed_roster_template_coverage_test.exs. This branch is latent — the
    # key has a builder, so the render path is reached only when the builder
    # declines. Seeding a body nobody authored to make this go away is the
    # thing 019fb8ed stage 2 explicitly decided against, and that decision
    # still stands for THIS key: it is event-triggered rather than cron, and
    # it carries a legacy fallback MFA, so a gap degrades to the legacy
    # summariser rather than to an empty prompt on the wire.
    test "the real unseeded roster slug aborts rather than reaching a model", %{agent: agent} do
      refute PromptTemplates.get_template_by_slug(@unseeded_roster_slug),
             "#{@unseeded_roster_slug} acquired a row — this test's premise moved; " <>
               "re-derive the unseeded set rather than editing this assertion away"

      responsibility =
        build_responsibility(%{
          key: "meetings.summarize",
          feature: "meetings",
          default_prompt_template: @unseeded_roster_slug
        })

      assert {:error, {:template_missing, @unseeded_roster_slug}} =
               Dispatcher.dispatch(responsibility, agent, %{})

      assert drain_dispatch_bodies() == []
    end

    # A row that IS there and renders to nothing. Reachable through the
    # ordinary editor: a body that is only `{{placeholders}}` resolves to ""
    # when no assign matches, because `PromptTemplates.interpolate/2` falls
    # back to `Map.get(assigns, key) || ""`.
    test "a row that renders to nothing aborts with {:template_blank, slug}", %{agent: agent} do
      slug = seed_template("{{absent_assign}}")

      # The premise, measured rather than assumed: the row exists, and the
      # collaborator renders it to an empty string.
      assert %PromptTemplate{} = PromptTemplates.get_template_by_slug(slug)
      assert {:ok, ""} = PromptTemplates.render_template(slug, %{})

      responsibility = build_responsibility(%{default_prompt_template: slug})

      assert {:error, {:template_blank, ^slug}} =
               Dispatcher.dispatch(responsibility, agent, %{topic: "x"})

      assert drain_dispatch_bodies() == []
    end

    # The stored-whitespace variant. `PromptTemplate.changeset/2` runs
    # `validate_required([:content])`, whose default `:trim` rejects "   "
    # outright — so this row cannot be created through `create_template/1`
    # and has to be forced past the changeset, the way a hand-written
    # migration or a direct SQL edit would.
    test "a row whose stored content is whitespace aborts with {:template_blank, slug}",
         %{agent: agent} do
      slug = seed_template("real content, replaced below")

      assert match?(
               {:error, %Ecto.Changeset{}},
               PromptTemplates.create_template(%{
                 slug: slug <> ".blank",
                 name: "blank",
                 content: "   "
               })
             ),
             "if the changeset started accepting whitespace content, forcing the row " <>
               "through `update_all` no longer models anything and this test should " <>
               "use the ordinary path"

      {1, _} =
        Repo.update_all(from(t in PromptTemplate, where: t.slug == ^slug),
          set: [content: "   "]
        )

      responsibility = build_responsibility(%{default_prompt_template: slug})

      assert {:error, {:template_blank, ^slug}} =
               Dispatcher.dispatch(responsibility, agent, %{topic: "x"})

      assert drain_dispatch_bodies() == []
    end

    # `:no_prompt_template`, not `{:template_missing, nil}`. The key was
    # never wired to a prompt — there is no row to seed, so naming one would
    # send the operator looking for something that was never promised.
    test "a nil default_prompt_template aborts with :no_prompt_template", %{agent: agent} do
      responsibility = build_responsibility(%{default_prompt_template: nil})

      assert {:error, :no_prompt_template} =
               Dispatcher.dispatch(responsibility, agent, %{topic: "x"})

      assert drain_dispatch_bodies() == []
    end

    test "a whitespace-only default_prompt_template aborts with :no_prompt_template",
         %{agent: agent} do
      responsibility = build_responsibility(%{default_prompt_template: "   "})

      assert {:error, :no_prompt_template} =
               Dispatcher.dispatch(responsibility, agent, %{topic: "x"})

      assert drain_dispatch_bodies() == []
    end

    test "a non-binary default_prompt_template aborts with :no_prompt_template",
         %{agent: agent} do
      responsibility = build_responsibility(%{default_prompt_template: %{slug: "nope"}})

      assert {:error, :no_prompt_template} =
               Dispatcher.dispatch(responsibility, agent, %{topic: "x"})

      assert drain_dispatch_bodies() == []
    end

    # The abort lands in the stream operators already watch, with the slug in
    # the reason so the reader is told WHICH row to go seed.
    test "the abort fires :error telemetry whose reason names the cause and the slug",
         %{agent: agent} do
      attach_telemetry([@telemetry_called, @telemetry_error])

      slug = "dispatcher-test.absent.#{System.unique_integer([:positive])}.v1"
      responsibility = build_responsibility(%{default_prompt_template: slug})

      assert {:error, {:template_missing, ^slug}} =
               Dispatcher.dispatch(responsibility, agent, %{})

      assert_receive {:telemetry, @telemetry_error, %{duration_ms: _}, meta}
      assert meta.reason =~ "template_missing"
      assert meta.reason =~ slug
      assert meta.endpoint_kind == "openai_compat"
      assert meta.agent_slug == agent.slug
      assert meta.responsibility_key == "test.dispatch"

      # A dispatch that aborted is not a dispatch that succeeded.
      refute_receive {:telemetry, @telemetry_called, _, _}, 100
      assert drain_dispatch_bodies() == []
    end

    test ":no_prompt_template also reaches the same telemetry site", %{agent: agent} do
      attach_telemetry([@telemetry_called, @telemetry_error])

      responsibility = build_responsibility(%{default_prompt_template: nil})

      assert {:error, :no_prompt_template} = Dispatcher.dispatch(responsibility, agent, %{})

      assert_receive {:telemetry, @telemetry_error, %{duration_ms: _}, meta}
      assert meta.reason == ":no_prompt_template"
      assert meta.responsibility_key == "test.dispatch"
    end

    # PRECEDENCE IS UNCHANGED. A caller that already holds a prompt must
    # never be aborted by a `default_prompt_template` it is not using.
    test "explicit messages: dispatch even when default_prompt_template names no row",
         %{agent: agent} do
      slug = "dispatcher-test.absent.#{System.unique_integer([:positive])}.v1"
      responsibility = build_responsibility(%{default_prompt_template: slug})

      messages = [%{role: "user", content: "an explicit turn"}]

      assert {:ok, "ok"} = Dispatcher.dispatch(responsibility, agent, %{}, messages: messages)

      assert_receive {:dispatch_body, _conn, raw_body}
      decoded = Jason.decode!(raw_body)
      assert decoded["messages"] == [%{"role" => "user", "content" => "an explicit turn"}]
      refute raw_body =~ slug
    end

    test "explicit prompt: dispatches even when default_prompt_template is nil", %{agent: agent} do
      responsibility = build_responsibility(%{default_prompt_template: nil})

      assert {:ok, "ok"} =
               Dispatcher.dispatch(responsibility, agent, %{},
                 prompt: %{system: "sys", user: "user"}
               )

      assert_receive {:dispatch_body, _conn, raw_body}

      assert Jason.decode!(raw_body)["messages"] == [
               %{"role" => "system", "content" => "sys"},
               %{"role" => "user", "content" => "user"}
             ]
    end
  end

  # Every `{:dispatch_body, _, _}` currently in the mailbox, in arrival
  # order. Used instead of a bare `refute_receive` where the assertion is
  # about what was sent rather than merely that something was: an empty list
  # is the same claim, and a non-empty one prints the payload that broke it.
  defp drain_dispatch_bodies(acc \\ []) do
    receive do
      {:dispatch_body, _conn, raw} -> drain_dispatch_bodies([raw | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  # What the dispatcher's resolved body is EXPECTED to look like, computed
  # by this test rather than by calling the collaborator under exercise
  # (`PromptTemplates.render_template/2`). These fixtures pass an empty
  # context, so every `{{placeholder}}` in a seeded body renders to the
  # empty string — mirroring `PromptTemplates.interpolate/2`'s
  # `Map.get(assigns, key) || ""` fallback. Two of the eleven rows carry
  # placeholders (`meetings.intent_classify.v1`, `memory.dreaming.v1`);
  # the other eight seeded rows are placeholder-free and pass through
  # unchanged.
  defp expected_template_body(content), do: Regex.replace(~r/\{\{(\w+)\}\}/, content, "")

  # Slug per responsibility key, read out of the providers' own
  # `register/0` descriptors rather than transcribed. A slug rename in a
  # handler surfaces here as a failed inventory assertion instead of as a
  # quietly-passing test that pins a string nobody uses.
  defp registered_slugs do
    BuiltIns.providers()
    |> Enum.flat_map(& &1.register())
    |> Map.new(&{&1.key, &1[:default_prompt_template]})
  end
end
