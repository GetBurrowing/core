defmodule Platform.CodeMode.ReturnContractTest do
  @moduledoc """
  Task 01a114a8 stage 3: each tool that declares a `returns_schema` returns
  data that conforms to it, as the wire sees it (`Jsonable` + a JSON round
  trip, the projection `/mcp` and `suite_run` both apply), for 0, 1 and many
  rows, and every refusal is the shared error envelope.

  Two properties are checked beside the schema, because a schema with
  optional keys cannot see them: within one list every row has the SAME key
  set, and the envelope's keys do not change with the row count.

  Every call goes through `ToolArguments.dispatch/3`, the door both
  federation transports use. Expected values are literals.
  """

  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Federation.Jsonable
  alias Platform.Federation.ReturnSchemas
  alias Platform.Federation.RuntimePresence
  alias Platform.Federation.ToolArguments
  alias Platform.Federation.ToolSurface
  alias Platform.Meetings
  alias Platform.Meetings.IntentQueue
  alias Platform.Orchestration.ExecutionLease
  alias Platform.Orchestration.RuntimeEvent
  alias Platform.Tasks
  alias Platform.Tasks.Plan

  defp u, do: System.unique_integer([:positive])

  # ── Harness ──────────────────────────────────────────────────────────────

  defp wire(term), do: term |> Jsonable.encodable() |> Jason.encode!() |> Jason.decode!()

  # Calls `tool`, asserts success, validates against its schema, returns the
  # wire JSON.
  defp conform!(tool, args, context \\ %{}) do
    assert {:ok, data} = ToolArguments.dispatch(tool, args, context)
    json = wire(data)
    assert_valid!(ReturnSchemas.for_tool(tool), json, tool)
    json
  end

  # Calls `tool`, asserts a refusal, validates it as the error envelope.
  defp refuse!(tool, args, context \\ %{}) do
    assert {:error, reason} = ToolArguments.dispatch(tool, args, context)
    json = reason |> Jsonable.error_envelope() |> wire()
    assert_valid!(ReturnSchemas.error_envelope(), json, "#{tool} refusal")
    json
  end

  defp assert_valid!(schema, json, label) do
    case ExJsonSchema.Validator.validate(ExJsonSchema.Schema.resolve(schema), json) do
      :ok -> :ok
      {:error, errors} -> flunk("#{label} does not conform to its schema: #{inspect(errors)}")
    end
  end

  # Every row of a list carries the same keys.
  defp same_keys!(rows, label) do
    key_sets = rows |> Enum.map(&(&1 |> Map.keys() |> Enum.sort())) |> Enum.uniq()

    assert length(key_sets) <= 1,
           "#{label}: rows carry different key sets: #{inspect(key_sets)}"
  end

  # The envelope's own keys are the same at 0, 1 and many rows.
  defp same_envelope!(envelopes, label) do
    key_sets = envelopes |> Enum.map(&(&1 |> Map.keys() |> Enum.sort())) |> Enum.uniq()

    assert length(key_sets) == 1,
           "#{label}: envelope keys vary with row count: #{inspect(key_sets)}"
  end

  defp project! do
    {:ok, project} = Tasks.create_project(%{name: "Contract #{u()}"})
    project
  end

  defp task!(project, attrs \\ %{}) do
    {:ok, task} = Tasks.create_task(Map.merge(%{project_id: project.id, title: "T#{u()}"}, attrs))
    task
  end

  defp user! do
    Repo.insert!(%User{
      email: "contract-#{u()}@example.com",
      name: "Contract User #{u()}",
      oidc_sub: "oidc-contract-#{u()}"
    })
  end

  defp agent!(attrs \\ %{}) do
    %Agent{}
    |> Agent.changeset(
      Map.merge(%{slug: "contract-agent-#{u()}", name: "Contract Agent", status: "active"}, attrs)
    )
    |> Repo.insert!()
  end

  # ── The schemas themselves ───────────────────────────────────────────────

  describe "the declared schemas" do
    test "every listed tool resolves as a JSON Schema and is attached to its definition" do
      defs = Map.new(ToolSurface.tool_definitions(), &{&1.name, &1})

      for tool <- ReturnSchemas.tools() do
        schema = ReturnSchemas.for_tool(tool)
        assert %ExJsonSchema.Schema.Root{} = ExJsonSchema.Schema.resolve(schema)
        assert Map.fetch!(defs, tool).returns_schema == schema, tool
      end
    end

    test "exactly the listed tools carry returns_schema" do
      carrying =
        ToolSurface.tool_definitions()
        |> Enum.filter(&Map.has_key?(&1, :returns_schema))
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert carrying ==
               Enum.sort(~w(task_list task_get plan_get stage_list validation_list
                            execution_lease_list runtime_event_list federation_status
                            space_get_messages principal_search intent_ack meeting_say
                            suite_run_describe))
    end

    test "POSITIVE CONTROL: the validator rejects a stray key and a wrong type" do
      schema = ExJsonSchema.Schema.resolve(ReturnSchemas.for_tool("meeting_say"))

      good = %{
        "utterance_id" => "u",
        "status" => "no_ack",
        "duration_s" => nil,
        "error" => nil,
        "room_name" => "r"
      }

      assert :ok = ExJsonSchema.Validator.validate(schema, good)
      assert {:error, _} = ExJsonSchema.Validator.validate(schema, Map.put(good, "extra", 1))

      assert {:error, _} =
               ExJsonSchema.Validator.validate(schema, Map.put(good, "duration_s", "1"))

      assert {:error, _} = ExJsonSchema.Validator.validate(schema, Map.delete(good, "room_name"))
    end
  end

  # ── Check-in triage path ─────────────────────────────────────────────────

  describe "task_list" do
    test "0, 1 and many rows conform; a NULL description keeps the snippet markers" do
      project = project!()

      zero = conform!("task_list", %{"project_id" => project.id})
      assert zero["tasks"] == []

      _ = task!(project, %{description: nil})
      one = conform!("task_list", %{"project_id" => project.id})
      assert [row] = one["tasks"]
      assert row["description"] == nil
      assert row["description_truncated"] == false
      assert row["description_length"] == nil

      _ = task!(project, %{description: String.duplicate("d", 900)})
      _ = task!(project, %{description: "short"})
      many = conform!("task_list", %{"project_id" => project.id})
      assert length(many["tasks"]) == 3
      same_keys!(many["tasks"], "task_list")
      same_envelope!([zero, one, many], "task_list")

      full = conform!("task_list", %{"project_id" => project.id, "detail" => "full"})
      same_keys!(full["tasks"], "task_list full")
    end

    test "a refusal is the error envelope" do
      json = refuse!("task_list", %{"assignee_id" => "not-a-uuid"})
      assert json["code"] == "invalid_assignee_id"
    end
  end

  describe "task_get" do
    test "a task conforms, sponsor and phase_assignees included" do
      sponsor = user!()
      task = task!(project!(), %{sponsor_user_id: sponsor.id})

      json = conform!("task_get", %{"task_id" => task.id})
      assert json["id"] == task.id
      assert json["sponsor"]["id"] == sponsor.id
    end

    test "a missing task and a MALFORMED id are both the not-found envelope" do
      missing = refuse!("task_get", %{"task_id" => Ecto.UUID.generate()})
      assert missing["recoverable"] == false

      # Raised Ecto.Query.CastError before 01a114a8 stage 3.
      malformed = refuse!("task_get", %{"task_id" => "not-a-uuid"})
      assert malformed["error"] == "Task not found: not-a-uuid"
    end
  end

  defp plan!(task, n_stages, opts) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    for i <- 1..n_stages//1 do
      {:ok, stage} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: i,
          name: "S#{i}",
          description: if(rem(i, 2) == 0, do: nil, else: "stage #{i}")
        })

      for j <- 1..Keyword.get(opts, :validations, 0)//1 do
        {:ok, v} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

        # Alternate a populated and an empty evidence blob, so a summary row
        # that omits its blob sits next to one that does not.
        if rem(j, 2) == 1 do
          {:ok, _} = v |> Ecto.Changeset.change(evidence: %{"result" => "ok"}) |> Repo.update()
        end
      end
    end

    plan
  end

  defp approve!(plan) do
    Repo.update_all(from(p in Plan, where: p.id == ^plan.id), set: [status: "approved"])
    plan
  end

  describe "plan_get" do
    test "0, 1 and many stages conform" do
      project = project!()

      for n <- [0, 1, 3] do
        task = task!(project)
        task |> plan!(n, validations: 2) |> approve!()
        json = conform!("plan_get", %{"task_id" => task.id})
        assert length(json["stages"]) == n
        same_keys!(json["stages"], "plan_get stages")
        same_keys!(Enum.flat_map(json["stages"], & &1["validations"]), "plan_get validations")
      end
    end

    test "no plan is the error envelope" do
      json = refuse!("plan_get", %{"task_id" => task!(project!()).id})
      assert json["error"] == "No approved plan for task"
    end
  end

  describe "stage_list" do
    test "0, 1 and many stages conform; summary rows keep one key set" do
      project = project!()

      envelopes =
        for n <- [0, 1, 3] do
          plan = plan!(task!(project), n, validations: 2)
          json = conform!("stage_list", %{"plan_id" => plan.id})
          assert length(json["stages"]) == n
          same_keys!(json["stages"], "stage_list stages")

          validations = Enum.flat_map(json["stages"], & &1["validations"])
          same_keys!(validations, "stage_list validations")

          for v <- validations do
            # Before 01a114a8 stage 3 `_length` existed only on omitted blobs.
            assert Map.has_key?(v, "evidence_length")
            assert Map.has_key?(v, "evaluation_payload_length")
            assert Map.has_key?(v, "payload_amendments_length")
          end

          full = conform!("stage_list", %{"plan_id" => plan.id, "detail" => "full"})
          same_keys!(full["stages"], "stage_list full")
          json
        end

      same_envelope!(envelopes, "stage_list")
    end

    test "omitted evidence reports its encoded length; returned evidence reports null" do
      plan = plan!(task!(project!()), 1, validations: 2)

      %{"stages" => [%{"validations" => validations}]} =
        conform!("stage_list", %{"plan_id" => plan.id})

      omitted = Enum.find(validations, & &1["evidence_omitted"])
      whole = Enum.find(validations, &(!&1["evidence_omitted"]))

      assert omitted["evidence_omitted"] == true
      assert omitted["evidence_length"] == byte_size(~s({"result":"ok"}))
      assert whole["evidence_omitted"] == false
      assert whole["evidence_length"] == nil
    end

    test "a refusal is the error envelope" do
      json = refuse!("stage_list", %{})
      assert json["code"] == "missing_plan_reference"
    end
  end

  describe "validation_list" do
    test "0, 1 and many validations conform" do
      project = project!()

      envelopes =
        for n <- [0, 1, 3] do
          plan = plan!(task!(project), 1, validations: n)
          [stage] = Tasks.list_stages(plan.id)
          json = conform!("validation_list", %{"stage_id" => stage.id})
          assert length(json["validations"]) == n
          same_keys!(json["validations"], "validation_list")
          json
        end

      same_envelope!(envelopes, "validation_list")
    end

    test "a MALFORMED stage_id is refused in the envelope" do
      # Raised Ecto.Query.CastError before 01a114a8 stage 3.
      json = refuse!("validation_list", %{"stage_id" => "not-a-uuid"})
      assert json["code"] == "invalid_stage_id"
      assert json["recoverable"] == true
    end
  end

  defp leases!(task, n) do
    now = DateTime.utc_now()

    rows =
      for i <- 1..n//1 do
        %{
          id: Platform.Types.UUIDv7.generate(),
          task_id: task.id,
          stage_id: if(i == 1, do: nil, else: Ecto.UUID.generate()),
          phase: "execution",
          runtime_id: "contract-rt-#{i}",
          status: if(i == 2, do: "blocked", else: "active"),
          started_at: DateTime.add(now, i, :second),
          expires_at: DateTime.add(now, 1800, :second),
          block_reason: if(i == 2, do: "needs a human", else: nil),
          metadata: %{"k" => i},
          owner_attribution_status: "legacy_pre_migration",
          inserted_at: now,
          updated_at: now
        }
      end

    {^n, _} = Repo.insert_all(ExecutionLease, rows)
  end

  describe "execution_lease_list" do
    test "0, 1 and many leases conform" do
      project = project!()

      envelopes =
        for n <- [0, 1, 3] do
          task = task!(project)
          leases!(task, n)
          json = conform!("execution_lease_list", %{"task_id" => task.id})
          assert length(json["leases"]) == n
          same_keys!(json["leases"], "execution_lease_list")
          json
        end

      same_envelope!(envelopes, "execution_lease_list")
    end

    test "a refusal is the error envelope" do
      json =
        refuse!("execution_lease_list", %{"task_id" => task!(project!()).id, "status" => "nope"})

      assert json["recoverable"] == true
    end
  end

  defp events!(task, n) do
    for i <- 1..n//1 do
      {:ok, _} =
        %RuntimeEvent{}
        |> RuntimeEvent.changeset(%{
          task_id: task.id,
          phase: "execution",
          runtime_id: "contract-rt",
          event_type: "execution.heartbeat",
          occurred_at: DateTime.add(DateTime.utc_now(), -i, :second),
          idempotency_key: "contract-#{i}-#{u()}",
          payload: if(i == 1, do: %{}, else: %{"stage_id" => Ecto.UUID.generate()})
        })
        |> Repo.insert()
    end
  end

  describe "runtime_event_list" do
    test "0, 1 and many events conform" do
      project = project!()

      envelopes =
        for n <- [0, 1, 3] do
          task = task!(project)
          events!(task, n)
          json = conform!("runtime_event_list", %{"task_id" => task.id})
          assert length(json["events"]) == n
          same_keys!(json["events"], "runtime_event_list")
          json
        end

      same_envelope!(envelopes, "runtime_event_list")
    end

    test "a refusal is the error envelope" do
      json = refuse!("runtime_event_list", %{})
      assert json["code"] == "missing_task_id"
    end
  end

  # ── federation_status ────────────────────────────────────────────────────

  @alpha "contract-rt-alpha"
  @beta "contract-rt-beta"
  @gamma "contract-rt-gamma"

  defp runtime!(runtime_id, agent, owner \\ nil) do
    runtime = %AgentRuntime{}
    |> AgentRuntime.changeset(%{
      runtime_id: runtime_id,
      owner_user_id: (owner || user!()).id,
      agent_id: agent.id,
      auth_token_hash: AgentRuntime.hash_token(AgentRuntime.generate_token()),
      status: "active"
    })
    |> Repo.insert!()

    {:ok, _profile} =
      Platform.Access.RuntimeProfiles.create_for_runtime(
        runtime,
        AgentRuntime.default_tool_profile(),
        Platform.Access.RuntimeProfiles.translated_permissions(AgentRuntime.default_tool_profile())
      )

    runtime
  end

  # The 13 keys every default row has carried since task 01a0b2ff; the
  # default output must not change.
  @default_row_keys ~w(agent_name agent_slug client_build client_build_error client_build_status
                       connected_at declared_features last_connected_at last_seen_at online
                       process_started_at proven runtime_id)

  describe "federation_status" do
    setup do
      agent = agent!()
      for id <- [@alpha, @beta, @gamma], do: runtime!(id, agent)
      RuntimePresence.track(@alpha)
      on_exit(fn -> RuntimePresence.untrack(@alpha) end)
      :ok
    end

    defp ids(json), do: json["runtimes"] |> Enum.map(& &1["runtime_id"]) |> Enum.sort()

    test "0, 1 and many rows conform" do
      zero = conform!("federation_status", %{"runtime_ids" => ["contract-rt-none"]})
      assert zero["runtimes"] == []

      one = conform!("federation_status", %{"runtime_ids" => [@alpha]})
      assert ids(one) == [@alpha]

      many = conform!("federation_status", %{"runtime_ids" => [@alpha, @beta, @gamma]})
      assert ids(many) == [@alpha, @beta, @gamma]
      same_keys!(many["runtimes"], "federation_status")
      same_envelope!([zero, one, many], "federation_status")

      default = conform!("federation_status", %{})
      same_keys!(default["runtimes"], "federation_status default")
    end

    test "with no filter, every row has exactly the 13 historical keys" do
      json = conform!("federation_status", %{})
      assert Enum.all?([@alpha, @beta, @gamma], &(&1 in ids(json)))

      for row <- json["runtimes"] do
        assert row |> Map.keys() |> Enum.sort() == Enum.sort(@default_row_keys)
      end
    end

    test "online, runtime_ids and fields narrow the rows to literal ids" do
      scoped = %{"runtime_ids" => [@alpha, @beta, @gamma]}

      assert ids(conform!("federation_status", Map.put(scoped, "online", true))) == [@alpha]

      assert ids(conform!("federation_status", Map.put(scoped, "online", false))) ==
               [@beta, @gamma]

      projected =
        conform!("federation_status", Map.merge(scoped, %{"fields" => ["online", "agent_slug"]}))

      for row <- projected["runtimes"] do
        assert row |> Map.keys() |> Enum.sort() == ["agent_slug", "online", "runtime_id"]
      end

      assert Enum.find(projected["runtimes"], &(&1["runtime_id"] == @alpha))["online"] == true
    end

    test "a filter never changes a value it keeps" do
      scoped = %{"runtime_ids" => [@alpha]}
      [whole] = conform!("federation_status", scoped)["runtimes"]

      [narrow] =
        conform!("federation_status", Map.put(scoped, "fields", ["proven", "client_build"]))[
          "runtimes"
        ]

      assert narrow == Map.take(whole, ["runtime_id", "proven", "client_build"])
    end

    test "malformed filters are refused, not ignored" do
      assert refuse!("federation_status", %{"fields" => ["onlnie"]})["code"] == "unknown_field"
      assert refuse!("federation_status", %{"online" => "yes"})["code"] == "invalid_online"

      assert refuse!("federation_status", %{"runtime_ids" => "x"})["code"] ==
               "invalid_runtime_ids"

      assert refuse!("federation_status", %{"fields" => [1]})["code"] == "invalid_fields"
    end

    # Measured for the PR: the two-line question "which runtimes are online,
    # and whose are they" over 30 runtimes.
    test "SIZE: online-only, two fields vs the default over 30 runtimes" do
      agent = agent!()
      ids = for i <- 1..27, do: "contract-rt-size-#{i}"
      for id <- ids, do: runtime!(id, agent)
      RuntimePresence.track(hd(ids))
      on_exit(fn -> RuntimePresence.untrack(hd(ids)) end)

      scope = [@alpha, @beta, @gamma | ids]
      default = conform!("federation_status", %{"runtime_ids" => scope})
      assert length(default["runtimes"]) == 30

      narrow =
        conform!("federation_status", %{
          "runtime_ids" => scope,
          "online" => true,
          "fields" => ["agent_slug", "online"]
        })

      assert length(narrow["runtimes"]) == 2

      default_bytes = byte_size(Jason.encode!(default))
      narrow_bytes = byte_size(Jason.encode!(narrow))

      IO.puts(
        "\n[01a114a8] federation_status bytes, 30 runtimes: default=#{default_bytes} online+2 fields=#{narrow_bytes}"
      )

      assert narrow_bytes * 20 < default_bytes
    end
  end

  # ── Burrow meeting path ──────────────────────────────────────────────────

  describe "space_get_messages" do
    setup do
      agent = agent!()
      org = Platform.Tenancy.get_org_by_slug!("sxi")

      {:ok, space} =
        Chat.create_space(%{
          name: "Contract #{u()}",
          slug: "contract-#{u()}",
          kind: "channel",
          org_id: org.id
        })

      {:ok, participant} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: agent.id,
          display_name: agent.name,
          role: "member",
          joined_at: DateTime.utc_now()
        })

      owner = user!()
      Platform.ExternalUserFixtures.plain_member!(owner, org)

      {:ok, _owner_participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: owner.id,
          display_name: owner.name,
          role: "member",
          joined_at: DateTime.utc_now()
        })

      runtime = runtime!("contract-message-#{u()}", agent, owner)

      %{
        space: space,
        participant: participant,
        ctx: %{agent_id: agent.id, runtime_id: runtime.runtime_id}
      }
    end

    test "0, 1 and many messages conform", %{space: space, participant: p, ctx: ctx} do
      post = fn content ->
        {:ok, m} =
          Chat.post_message(%{
            space_id: space.id,
            participant_id: p.id,
            content_type: "text",
            content: content
          })

        m
      end

      zero = conform!("space_get_messages", %{"space_id" => space.id}, ctx)
      assert zero["messages"] == []

      post.("one")
      one = conform!("space_get_messages", %{"space_id" => space.id}, ctx)
      assert length(one["messages"]) == 1

      post.("two")
      post.("three")
      many = conform!("space_get_messages", %{"space_id" => space.id}, ctx)
      assert length(many["messages"]) == 3
      same_keys!(many["messages"], "space_get_messages")
      same_envelope!([zero, one, many], "space_get_messages")
    end

    test "a non-participant is refused in the envelope", %{space: space} do
      json = refuse!("space_get_messages", %{"space_id" => space.id}, %{agent_id: agent!().id})
      assert is_binary(json["error"])
    end
  end

  describe "principal_search" do
    test "0, 1 and many rows conform; user and agent rows each keep one shape" do
      token = "zqx#{u()}"

      zero = conform!("principal_search", %{"query" => token})
      assert zero["results"] == []

      Repo.insert!(%User{
        email: "#{token}-1@example.com",
        name: "#{token} One",
        oidc_sub: "o-#{u()}"
      })

      one = conform!("principal_search", %{"query" => token})
      assert [%{"type" => "user"}] = one["results"]

      Repo.insert!(%User{
        email: "#{token}-2@example.com",
        name: "#{token} Two",
        oidc_sub: "o-#{u()}"
      })

      agent!(%{slug: "#{token}-a", name: "#{token} Agent A"})
      agent!(%{slug: "#{token}-b", name: "#{token} Agent B"})

      many = conform!("principal_search", %{"query" => token})
      assert Enum.map(many["results"], & &1["type"]) == ~w(user user agent agent)

      for type <- ~w(user agent) do
        many["results"] |> Enum.filter(&(&1["type"] == type)) |> same_keys!("principal #{type}")
      end

      short = conform!("principal_search", %{"query" => "z"})
      assert short["results"] == []
      same_envelope!([zero, one, many, short], "principal_search")
    end

    test "a refusal is the error envelope" do
      json = refuse!("principal_search", %{"query" => "abc", "type" => "robot"})
      assert json["recoverable"] == true
    end
  end

  describe "intent_ack" do
    setup do
      meeting_id = Platform.Types.UUIDv7.generate()
      {:ok, _pid} = IntentQueue.ensure_started(meeting_id, ack_timeout_ms: 60_000)
      on_exit(fn -> IntentQueue.stop(meeting_id) end)

      {:ok, row} =
        IntentQueue.enqueue(meeting_id, %{
          room_id: "room-#{u()}",
          dedupe_key: "dk-#{u()}",
          classified_intent: "book_followup",
          target_role: "designer",
          confidence: 0.9,
          chunk_excerpt: "book it"
        })

      {:ok, ^row} = IntentQueue.claim_next(meeting_id)
      {:ok, _} = IntentQueue.transition(meeting_id, row.id, :dispatched)
      %{intent_id: row.id}
    end

    test "working and completed acks conform", %{intent_id: id} do
      args = %{"intent_id" => id, "subagent_id" => "contract-sub"}

      working = conform!("intent_ack", Map.put(args, "status", "working"))
      assert working["status"] == "acked"

      completed = conform!("intent_ack", Map.put(args, "status", "completed"))
      assert completed["status"] == "completed"
      same_keys!([working, completed], "intent_ack")
    end

    test "refusals are the error envelope", %{intent_id: id} do
      refuse!("intent_ack", %{
        "intent_id" => Ecto.UUID.generate(),
        "subagent_id" => "s",
        "status" => "working"
      })

      refuse!("intent_ack", %{"intent_id" => id, "subagent_id" => "   ", "status" => "working"})
      refuse!("intent_ack", %{"intent_id" => id, "subagent_id" => "s", "status" => "nope"})
    end
  end

  describe "meeting_say" do
    setup do
      original_livekit = Application.get_env(:platform, :livekit, [])
      original_timeout = Application.get_env(:platform, :meeting_say_ack_timeout_ms)

      Application.put_env(:platform, :livekit,
        api_key: "test-livekit-key",
        api_secret: "test-livekit-secret-0123456789abcdef",
        url: "wss://livekit.test"
      )

      Application.put_env(:platform, :meeting_say_ack_timeout_ms, 200)

      on_exit(fn ->
        Application.put_env(:platform, :livekit, original_livekit)

        case original_timeout do
          nil -> Application.delete_env(:platform, :meeting_say_ack_timeout_ms)
          v -> Application.put_env(:platform, :meeting_say_ack_timeout_ms, v)
        end
      end)

      owner = user!()
      agent = agent!()
      {:ok, runtime} = Federation.register_runtime(owner.id, %{runtime_id: "contract-say-#{u()}"})
      {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
      {:ok, agent} = Federation.link_agent(activated, agent)
      :ok = PlatformWeb.Endpoint.subscribe("runtime:#{activated.runtime_id}")

      {:ok, space} =
        Chat.create_space(%{name: "Say #{u()}", slug: "say-#{u()}", kind: "channel"})

      {:ok, room} = Meetings.ensure_room(space.id)
      {:ok, room} = Meetings.activate_room(room)
      %{agent: agent, room: room}
    end

    test "no_ack and spoken both conform", %{agent: agent, room: room} do
      {:ok, _} =
        Meetings.participant_joined(room, %{display_name: agent.name, agent_id: agent.id})

      args = %{"room_name" => room.livekit_room_name, "text" => "hello"}
      no_ack = conform!("meeting_say", args, %{agent: agent})
      assert no_ack["status"] == "no_ack"
      assert_receive %Phoenix.Socket.Broadcast{event: "meeting_say"}, 1_000

      Application.put_env(:platform, :meeting_say_ack_timeout_ms, 2_000)
      task = Task.async(fn -> ToolArguments.dispatch("meeting_say", args, %{agent: agent}) end)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "meeting_say",
                       payload: %{utterance_id: id}
                     },
                     1_000

      Meetings.record_agent_say_ack(agent.id, %{
        "utterance_id" => id,
        "room_name" => room.livekit_room_name,
        "status" => "spoken",
        "duration_s" => 0.8
      })

      assert {:ok, data} = Task.await(task)
      spoken = wire(data)
      assert_valid!(ReturnSchemas.for_tool("meeting_say"), spoken, "meeting_say spoken")
      assert spoken["duration_s"] == 0.8
      same_keys!([no_ack, spoken], "meeting_say")
    end

    test "a speaker not in the room is refused in the envelope", %{agent: agent, room: room} do
      refuse!("meeting_say", %{"room_name" => room.livekit_room_name, "text" => "hi"}, %{
        agent: agent
      })
    end
  end
end
