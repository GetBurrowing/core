defmodule Platform.Roles.MeetingProducerTest do
  @moduledoc """
  End-to-end integration test for the Meeting Producer role wiring
  (task `019f2451-6728` stage 4).

  Stages 1-3 landed four independently-tested layers:

    * Stage 1 — schema enum + DB CHECK admit `meeting_producer` as a
      valid role key (`Platform.Roles.Role.valid_keys/0`).
    * Stage 2 — seed row + re-seed migration insert the role into the
      closed roster with the `["meetings.intent_classify"]` bundle.
    * Stage 3 — `Platform.Responsibilities.Handlers.IntentClassify` is
      a registered built-in Provider (with the placeholder log level
      pinned to `Logger.warning` — see the handler's moduledoc) AND the
      per-feature shim `Platform.Responsibilities.Providers.Meetings`
      grew a `handler_for/1` dispatch table.

  This file is the seam between all four. If any of them drifts
  (schema enum forgets a key, migration lands but seed data doesn't,
  built-ins list is missing the handler, provider dispatch table
  doesn't map the new key) the failure trips exactly one place —
  here.

  ## Cost-profile note

  The plan called for `cost_profile: "high_freq_capable"`. That value
  is NOT in the schema enum (`Platform.Responsibilities.Responsibility.cost_profiles/0`
  returns only `["high_freq_low_cost", "low_freq_capable"]`). Stage 3
  shipped with `high_freq_low_cost` — the cheap tier — because the
  classifier fires per transcript chunk and the schema wouldn't accept
  the planner's speculative label. Test 4 asserts the ACTUAL shipped
  value, not the plan's.

  ## Router / provider resolution

  `Platform.Responsibilities.Router.provider_module_for/1` is
  intentionally private — the resolution convention (camelcase the
  feature, prepend `Platform.Responsibilities.Providers.`) is
  documented in the module and mirrored here via `Module.concat/1` so
  a convention drift in the Router would surface as a test failure
  without reaching into the private API. Test 5 then confirms the
  concrete `Providers.Meetings.handler_for/1` dispatch table lands on
  `Handlers.IntentClassify` for our key.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.BuiltIns
  alias Platform.Responsibilities.Handlers
  alias Platform.Responsibilities.Providers.Meetings, as: MeetingsProvider
  alias Platform.Responsibilities.Registry
  alias Platform.Responsibilities.Responsibility
  alias Platform.Roles
  alias Platform.Roles.Role

  @role_key "meeting_producer"
  @responsibility_key "meetings.intent_classify"
  @feature "meetings"

  # Insert a fresh native agent — mirrors `role_assignment_test.exs`
  # and `coverage_test.exs`'s helper so we round-trip through the
  # canonical changeset (not raw SQL) and the FK from
  # `role_assignments.agent_id` to `agents.id` stays honest.
  defp insert_agent!(overrides \\ %{}) do
    suffix = System.unique_integer([:positive])

    attrs =
      %{
        slug: "producer-#{suffix}",
        name: "Producer Agent #{suffix}",
        status: "active",
        kind: "native",
        workspace_id: nil
      }
      |> Map.merge(overrides)

    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert!()
  end

  # Per-case Registry — mirrors the pattern in `registry_test.exs` and
  # `built_ins_test.exs`. `:start_responsibilities_registry` is `false`
  # in `config/test.exs` so this instance is the sole owner of the
  # responsibilities table under the DataCase sandbox.
  defp start_registry(providers) do
    name = :"#{__MODULE__}.Reg#{System.unique_integer([:positive])}"
    pid = start_supervised!({Registry, name: name, providers: providers})
    {pid, name}
  end

  describe "role → bundle wiring" do
    test "Platform.Roles.list_roles/0 includes meeting_producer" do
      # The stage-2 re-seed migration
      # (`20260702200500_seed_meeting_producer_role.exs`) runs on the
      # test DB during `mix ecto.migrate`, so the row is already there.
      # Test asserts observable via the context module, not the seed
      # module directly — this is the surface the UI (agent picker,
      # rolodex) reads through.
      keys = Roles.list_roles() |> Enum.map(& &1.key)

      assert @role_key in keys,
             """
             #{@role_key} missing from Roles.list_roles/0. Either the
             seed migration didn't run or the schema enum in
             Platform.Roles.Role rejects the key.
             Seen keys: #{inspect(keys)}
             """

      # The role must also be admitted by the schema enum — otherwise
      # any assignment insertion would fail at the changeset layer even
      # if the row exists.
      assert @role_key in Role.valid_keys(),
             "#{@role_key} missing from Role.valid_keys/0 — schema enum drifted from seed"
    end

    test "Platform.Roles.bundle_for/1 returns the meetings.intent_classify bundle" do
      # Stage-2's seed defined this exact bundle. The order is stable
      # (alphabetical per `bundle_for/1`'s query), and this bundle has
      # exactly one element so ordering is a non-issue today — a
      # future addition of a second key SHOULD break this test until
      # the assertion is updated deliberately.
      assert Roles.bundle_for(@role_key) == [@responsibility_key]
    end
  end

  describe "assignment → resolver wiring" do
    test "assign_role/2 + assignee_for/1 route meetings.intent_classify to the holder" do
      # Full role → bundle → holder path through the resolver. If any
      # of the joins in `Roles.assignee_for/1`'s
      # `lookup_role_assigned_agent/1` query drift (role_assignments →
      # role_responsibilities → agents) this test surfaces it.
      agent = insert_agent!()

      assert {:ok, _assignment} = Roles.assign_role(@role_key, agent.id)

      resolved = Roles.assignee_for(@responsibility_key)

      assert %Agent{id: id} = resolved,
             "assignee_for/1 must return an %Agent{} once the role is filled; got #{inspect(resolved)}"

      assert id == agent.id,
             "resolver returned agent #{inspect(id)} but role holder is #{inspect(agent.id)}"
    end
  end

  describe "responsibility registry row" do
    test "Registry boot with BuiltIns.providers/0 upserts meetings.intent_classify with the shipped spec" do
      {_pid, _name} = start_registry(BuiltIns.providers())

      row = Responsibilities.get_by_key(@responsibility_key)

      assert %Responsibility{} = row,
             "Registry boot with BuiltIns.providers/0 must upsert #{@responsibility_key}"

      # Pin the exact spec fields the runtime code path reads at
      # dispatch time. Names + shapes MUST match
      # `Platform.Responsibilities.Handlers.IntentClassify.register/0`.
      assert row.key == @responsibility_key
      assert row.feature == @feature
      assert row.trigger_kind == "event_topic"
      assert row.scope == "per_meeting"
      assert row.context_provided == ["meeting_transcript_chunk"]

      assert row.trigger_config == %{
               "topic" => "meeting:transcript_chunk",
               "event_match" => "transcript_chunk"
             }

      # NOTE: the plan document specified `cost_profile:
      # "high_freq_capable"` but that value is not in the schema enum
      # (`Responsibility.cost_profiles/0` == ["high_freq_low_cost",
      # "low_freq_capable"]). Stage 3 shipped with
      # `high_freq_low_cost` — the cheap tier — which is what the
      # placeholder classifier actually is. If a future stage changes
      # the enum to add `high_freq_capable`, THAT is the moment to
      # revisit this assertion, not before.
      assert row.cost_profile == "high_freq_low_cost"

      # Placeholder marker so an operator grep for
      # `metadata->>'status' = 'placeholder'` catches the row until
      # the runtime ticket (`019f2452-0210`) replaces it.
      assert row.metadata["status"] == "placeholder"
      assert row.metadata["runtime_task"] == "019f2452-0210"
      assert row.metadata["owner"] == "platform.meetings"
      assert row.enabled == true
    end
  end

  describe "provider resolution (Router convention + Meetings shim)" do
    test "Router's provider-resolution convention resolves meetings → Providers.Meetings" do
      # `Platform.Responsibilities.Router.provider_module_for/1` is
      # private on purpose. Its convention — camelcase the feature and
      # prepend `Platform.Responsibilities.Providers.` — is documented
      # in the Router module and mirrored here. If the convention
      # changes (e.g. a namespace refactor) this test breaks alongside
      # the Router's own tests, giving one loud signal instead of a
      # silent runtime `no output handler for <key>` log.
      resolved =
        Module.concat([
          Platform.Responsibilities.Providers,
          Macro.camelize(@feature)
        ])

      assert resolved == Platform.Responsibilities.Providers.Meetings

      # The module must be loadable — a stale alias would resolve at
      # compile time but blow up at dispatch.
      assert Code.ensure_loaded?(resolved)

      # The Router calls `handle_output/3` on the provider. Behaviour
      # compliance is asserted in built_ins_test.exs but this is the
      # only spot that ties the resolution convention TO the arity
      # dispatch surface.
      assert function_exported?(resolved, :handle_output, 3)
    end

    test "Providers.Meetings.handler_for/1 dispatches the responsibility struct to IntentClassify" do
      # Round-trip a real DB row through the dispatch table — proves
      # the pattern-match on `%Responsibility{key: key}` works, not
      # just the string clause.
      {_pid, _name} = start_registry(BuiltIns.providers())
      row = Responsibilities.get_by_key(@responsibility_key)

      assert %Responsibility{} = row
      assert MeetingsProvider.handler_for(row) == Handlers.IntentClassify

      # And the raw-string clause for callers that only have the key
      # in hand (e.g. an operator nudge from iex).
      assert MeetingsProvider.handler_for(@responsibility_key) == Handlers.IntentClassify
    end
  end
end
