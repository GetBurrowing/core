defmodule Platform.Federation.ReturnSchemas do
  @moduledoc """
  Typed return contracts (JSON Schema) for the tools a `burrow_run` script
  calls most (task 01a114a8 stage 3): the check-in triage path (`task_list`,
  `task_get`, `plan_get`, `stage_list`, `validation_list`,
  `execution_lease_list`, `runtime_event_list`, `federation_status`) and the
  Burrow meeting path (`space_get_messages`, `principal_search`,
  `intent_ack`, `meeting_say`), plus `burrow_run_describe` itself.

  A tool definition carries its schema under the optional `:returns_schema`
  key; `Platform.CodeMode.Docs` renders it as a TypeScript type and
  `test/platform/code_mode/return_contract_test.exs` validates each tool's
  REAL output against it, as the wire sees it (`Jsonable` + JSON round trip),
  at 0, 1 and many rows.

  ## What a schema here promises

    * The success data's shape, not the error's. Every refusal is the shared
      `error_envelope/0` (`%{error, code?, recoverable?, suggestion?, ...}`).
    * Objects are CLOSED (`additionalProperties: false`) wherever the handler
      builds the map, so a key added to a return without updating its schema
      fails the contract test. Free-form blobs the handler passes through
      verbatim (`payload`, `metadata`, `evidence`, `phase_assignees`) are
      open objects and say so.
    * A key listed under `required` is present for 0, 1 and many rows, with
      `null` (or `[]` / `{}`) when there is nothing to report.
    * Timestamps are ISO8601 strings (`format: date-time`) on the wire; ids
      are strings.

  String keys throughout, so a schema is valid input to a JSON Schema
  validator and encodes identically on both federation transports.
  """

  @uuid_pattern "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"

  @tools ~w(task_list task_get plan_get stage_list validation_list execution_lease_list
            runtime_event_list federation_status space_get_messages principal_search
            intent_ack meeting_say meeting_scribe_complete meeting_triage_file burrow_run_describe)

  @doc "Names of the tools that carry a `returns_schema`."
  @spec tools() :: [String.t()]
  def tools, do: @tools

  @doc "The return schema for `tool`, or nil."
  @spec for_tool(String.t()) :: map() | nil
  def for_tool("task_list") do
    envelope(
      %{
        "tasks" => array(task(:summary)),
        "total" => int(),
        "limit" => int(),
        "offset" => int(),
        "has_more" => bool(),
        "filters" =>
          described(
            open_object(),
            "the filters the query applied, string-keyed; {} when unfiltered"
          )
      },
      "The task envelope. `tasks` is ordered inserted_at desc, id."
    )
  end

  def for_tool("task_get"), do: task(:full)

  def for_tool("plan_get"), do: plan()

  def for_tool("stage_list") do
    envelope(
      %{
        "stages" => array(stage()),
        "total" => int(),
        "limit" => int(),
        "offset" => int(),
        "has_more" => bool()
      },
      "The plan's stages ordered by position, each with its validations."
    )
  end

  def for_tool("validation_list") do
    envelope(
      %{
        "validations" => array(validation()),
        "total" => int(),
        "has_more" => bool()
      },
      "Every validation on the stage, oldest first."
    )
  end

  def for_tool("execution_lease_list") do
    envelope(
      %{
        "task_id" => string(),
        "count" => int(),
        "limit" => int(),
        "status_filter" => nullable(string()),
        "total" => int(),
        "has_more" => bool(),
        "leases" => array(lease())
      },
      "The task's durable execution leases, newest first."
    )
  end

  def for_tool("runtime_event_list") do
    envelope(
      %{
        "task_id" => string(),
        "count" => int(),
        "limit" => int(),
        "total" => int(),
        "has_more" => bool(),
        "events" => array(runtime_event())
      },
      "The task's runtime events, newest first."
    )
  end

  def for_tool("federation_status") do
    envelope(
      %{"runtimes" => array(federation_runtime())},
      "One row per active runtime. With `fields`, each row carries `runtime_id` plus only the named fields."
    )
  end

  def for_tool("space_get_messages") do
    envelope(
      %{
        "messages" => array(message()),
        "total" => int(),
        "limit" => int(),
        "has_more" => bool()
      },
      "Top-level messages, newest first."
    )
  end

  def for_tool("principal_search") do
    envelope(
      %{"results" => array(%{"oneOf" => [principal_user(), principal_agent()]})},
      "Users first, then agents. Each row's `type` says which shape it has."
    )
  end

  def for_tool("intent_ack") do
    closed(%{
      "intent_id" => string(),
      "meeting_id" => string(),
      "status" =>
        enum(
          ~w(queued dispatched acked completed cancelled cancelled_late timed_out no_ack_spawn_failed dispatch_failed)
        ),
      "subagent_id" => nullable(string()),
      "acked_at" => nullable(datetime())
    })
  end

  def for_tool("meeting_scribe_complete") do
    closed(%{
      "meeting_id" => string(),
      "run_id" => string(),
      "status" => string(),
      "canvas_id" => nullable(string()),
      "task_ids" => array(string())
    })
  end

  def for_tool("meeting_triage_file") do
    closed(%{
      "meeting_id" => string(),
      "run_id" => string(),
      "status" => string(),
      "canvas_id" => nullable(string()),
      "task_ids" => array(string())
    })
  end

  def for_tool("meeting_say") do
    closed(%{
      "utterance_id" => string(),
      "status" =>
        string(
          "\"spoken\" | \"failed\" | \"no_ack\" (a worker's unrecognised status is relayed verbatim)"
        ),
      "duration_s" => nullable(number()),
      "error" => nullable(string()),
      "room_name" => string()
    })
  end

  def for_tool("burrow_run_describe") do
    closed(%{
      "docs" => string("TypeScript declarations for the requested tools"),
      "tools" => array(string()),
      "not_available" =>
        described(array(string()), "requested names this runtime cannot call (or unknown)"),
      "bundles" => array(string())
    })
  end

  def for_tool(_), do: nil

  @doc """
  The refusal envelope every tool's `{:error, map}` reaches a caller in
  (`Platform.Federation.Jsonable.error_envelope/1`). Open: handlers attach
  diagnostic keys (`unsatisfied_validations`, `pending`, ...).
  """
  @spec error_envelope() :: map()
  def error_envelope do
    %{
      "type" => "object",
      "required" => ["error"],
      "properties" => %{
        "error" => string(),
        "code" => string(),
        "recoverable" => bool(),
        "suggestion" => string()
      }
    }
  end

  # ── Row shapes ──────────────────────────────────────────────────────────

  defp task(detail) do
    base = %{
      "id" => uuid(),
      "title" => nullable(string()),
      "description" => nullable(string()),
      "status" => string(),
      "priority" => nullable(string()),
      "kind" => string(),
      "origin" => enum(~w(internal external_feedback)),
      "trust" => enum(~w(trusted quarantined)),
      "external_repository_identity" => nullable(string()),
      "external_issue_number" => nullable(int()),
      "project_id" => nullable(uuid()),
      "epic_id" => nullable(uuid()),
      "assignee_type" => nullable(string()),
      "assignee_id" => nullable(string()),
      "phase_assignees" => described(open_object(), "phase => %{assignee_id, assignee_type}"),
      "deploy_target" => nullable(string()),
      "sponsor" =>
        nullable(
          closed(%{
            "id" => uuid(),
            "name" => nullable(string()),
            "email" => nullable(string())
          })
        ),
      "auto_approve_plan" => nullable(bool()),
      "stack_id" => nullable(uuid()),
      "paused_reason" => nullable(open_object()),
      "blocked_reason" => nullable(string()),
      "blocked_reason_at" => nullable(string()),
      "stack_position" => nullable(int()),
      "stack" =>
        nullable(
          closed(%{
            "landed_at" => nullable(string()),
            "blocked_reason" => nullable(string()),
            "blocked_reason_at" => nullable(string())
          })
        ),
      "inserted_at" => datetime(),
      "updated_at" => datetime()
    }

    if detail == :summary,
      do: base |> closed() |> with_snippet("description"),
      else: closed(base)
  end

  defp plan do
    closed(%{
      "id" => uuid(),
      "task_id" => uuid(),
      "status" => string(),
      "version" => nullable(int()),
      "is_current" => bool(),
      "rejection_reason" => nullable(string()),
      "architecture_verdict" => nullable(open_object()),
      "approved_by" => nullable(string()),
      "approved_at" => nullable(datetime()),
      "auto_approved_at" => nullable(datetime()),
      "stages" => array(stage()),
      "inserted_at" => datetime(),
      "updated_at" => datetime()
    })
  end

  defp stage do
    %{
      "id" => uuid(),
      "plan_id" => uuid(),
      "name" => nullable(string()),
      "description" => nullable(string()),
      "position" => nullable(int()),
      "status" => string(),
      "expected_artifacts" => array(open_object()),
      "started_at" => nullable(datetime()),
      "completed_at" => nullable(datetime()),
      "inserted_at" => datetime(),
      "updated_at" => datetime(),
      "validations" => array(validation())
    }
    |> closed()
    |> with_snippet("description")
  end

  defp validation do
    base = %{
      "id" => uuid(),
      "stage_id" => uuid(),
      "kind" => string(),
      "status" => string(),
      "evidence" => nullable(open_object()),
      "evaluation_payload" => nullable(open_object()),
      "payload_amendments" => array(open_object()),
      "evaluated_by" => nullable(string()),
      "evaluated_at" => nullable(datetime()),
      "inserted_at" => datetime(),
      "updated_at" => datetime()
    }

    # Summary rows (stage_list's default) carry an `_omitted` flag and an
    # `_length` for each blob; every summary row has all six. The length is
    # the blob's encoded size when it was omitted and null when it was
    # returned whole. Full rows (plan_get, validation_list, detail "full")
    # have none of them, so they are declared but not required.
    ~w(evidence evaluation_payload payload_amendments)
    |> Enum.reduce(closed(base), fn key, acc ->
      acc
      |> optional(key <> "_omitted", bool())
      |> optional(key <> "_length", nullable(int()))
    end)
  end

  defp lease do
    closed(%{
      "id" => uuid(),
      "stage_id" => nullable(uuid()),
      "phase" => nullable(string()),
      "runtime_id" => nullable(string()),
      "status" => string(),
      "started_at" => nullable(datetime()),
      "last_heartbeat_at" => nullable(datetime()),
      "last_progress_at" => nullable(datetime()),
      "expires_at" => nullable(datetime()),
      "block_reason" => nullable(string()),
      "metadata" => nullable(open_object())
    })
  end

  defp runtime_event do
    closed(%{
      "event_type" => string(),
      "payload" =>
        described(nullable(open_object()), "verbatim; payload.stage_id attributes a stage"),
      "runtime_id" => nullable(string()),
      "phase" => nullable(string()),
      "lease_id" => nullable(uuid()),
      "occurred_at" => nullable(datetime())
    })
  end

  @doc false
  # Every key a federation_status row can carry. `fields` selects from these.
  def federation_runtime_fields do
    ~w(runtime_id agent_name agent_slug online connected_at last_seen_at last_connected_at
       client_build client_build_status client_build_error process_started_at proven
       declared_features)
  end

  defp federation_runtime do
    props = %{
      "runtime_id" => string(),
      "agent_name" => nullable(string()),
      "agent_slug" => nullable(string()),
      "online" => bool(),
      "connected_at" => nullable(datetime()),
      "last_seen_at" => nullable(datetime()),
      "last_connected_at" => nullable(datetime()),
      "client_build" => string("a commit sha, or the literal \"unknown\""),
      "client_build_status" => enum(~w(reported unresolved not_reported no_client_info)),
      "client_build_error" => nullable(string()),
      "process_started_at" => nullable(datetime()),
      "proven" =>
        described(
          %{"type" => "object", "additionalProperties" => string()},
          "capability => ISO8601 timestamp or \"never\""
        ),
      "declared_features" => array(string())
    }

    # Only runtime_id is always present: a `fields` projection drops the rest.
    %{
      "type" => "object",
      "properties" => props,
      "required" => ["runtime_id"],
      "additionalProperties" => false
    }
  end

  defp message do
    closed(%{
      "id" => uuid(),
      "participant_id" => nullable(uuid()),
      "content_type" => nullable(string()),
      "content" => string(),
      "content_truncated" => bool(),
      "thread_id" => nullable(uuid()),
      "inserted_at" => datetime(),
      "attachments" =>
        array(
          closed(%{
            "url" => string(),
            "content_type" => nullable(string()),
            "byte_size" => nullable(int()),
            "filename" => nullable(string())
          })
        )
    })
  end

  defp principal_user do
    closed(%{
      "type" => enum(["user"]),
      "id" => uuid(),
      "display_name" => nullable(string()),
      "email" => nullable(string()),
      "avatar_url" => nullable(string())
    })
  end

  defp principal_agent do
    closed(%{
      "type" => enum(["agent"]),
      "id" => uuid(),
      "display_name" => nullable(string()),
      "slug" => nullable(string()),
      "kind" => nullable(string()),
      "classification" => string()
    })
  end

  # ── Builders ────────────────────────────────────────────────────────────

  # A snippeted record: in summary detail `<field>_truncated` and
  # `<field>_length` are present on EVERY row (`_length` is null when the
  # field is null); "full" detail has neither. Declared, not required.
  defp with_snippet(schema, field) do
    schema
    |> optional(field <> "_truncated", bool())
    |> optional(field <> "_length", nullable(int()))
  end

  defp optional(schema, key, sub), do: put_in(schema, ["properties", key], sub)

  defp envelope(props, description), do: props |> closed() |> described(description)

  defp closed(props) do
    %{
      "type" => "object",
      "properties" => props,
      "required" => props |> Map.keys() |> Enum.sort(),
      "additionalProperties" => false
    }
  end

  defp described(schema, text), do: Map.put(schema, "description", text)

  defp string, do: %{"type" => "string"}
  defp string(description), do: described(string(), description)
  defp uuid, do: %{"type" => "string", "pattern" => @uuid_pattern}
  defp datetime, do: %{"type" => "string", "format" => "date-time"}
  defp int, do: %{"type" => "integer"}
  defp number, do: %{"type" => "number"}
  defp bool, do: %{"type" => "boolean"}
  defp open_object, do: %{"type" => "object"}
  defp array(items), do: %{"type" => "array", "items" => items}
  defp enum(values), do: %{"type" => "string", "enum" => values}

  defp nullable(%{"type" => type} = schema) when is_binary(type),
    do: Map.put(schema, "type", [type, "null"])

  defp nullable(schema), do: %{"oneOf" => [schema, %{"type" => "null"}]}
end
