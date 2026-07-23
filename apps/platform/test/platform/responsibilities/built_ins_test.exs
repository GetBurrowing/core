defmodule Platform.Responsibilities.BuiltInsTest do
  @moduledoc """
  Confirms `Platform.Responsibilities.BuiltIns.providers/0` ships the
  M8 stage 2 memory responsibilities AND that booting the Registry
  with that list upserts canonical rows with the correct
  trigger_kind / scope / context_provided (ADR-0041 M8 stage 2).

  Uses a per-case Registry instance under the DataCase sandbox — the
  app-supervisor's Registry is disabled in `config/test.exs` so no
  second copy can race us.
  """
  use Platform.DataCase, async: false

  alias Platform.Responsibilities
  alias Platform.Responsibilities.BuiltIns
  alias Platform.Responsibilities.Handlers
  alias Platform.Responsibilities.Registry

  defp start_registry(providers) do
    name = :"#{__MODULE__}.Reg#{System.unique_integer([:positive])}"
    pid = start_supervised!({Registry, name: name, providers: providers})
    {pid, name}
  end

  describe "providers/0" do
    test "lists DailySummary, Dreaming, MeetingSummarize, and IntentClassify handlers" do
      providers = BuiltIns.providers()

      assert Handlers.DailySummary in providers
      assert Handlers.Dreaming in providers
      assert Handlers.MeetingSummarize in providers
      assert Handlers.IntentClassify in providers

      # No duplicates — the registry's upsert is idempotent on collision
      # but a duplicate listing here would be a bug.
      assert providers == Enum.uniq(providers)
    end

    test "lists the four Security Guard placeholder handlers (task 019f3e8e stage 1)" do
      providers = BuiltIns.providers()

      assert Handlers.SecurityCveScan in providers
      assert Handlers.SecurityCodeAudit in providers
      assert Handlers.SecurityDeployAudit in providers
      assert Handlers.SecuritySecretLeak in providers
    end

    test "every listed module implements the Provider behaviour and exports register/0" do
      Enum.each(BuiltIns.providers(), fn mod ->
        assert Code.ensure_loaded?(mod), "#{inspect(mod)} should be loadable"
        assert function_exported?(mod, :register, 0), "#{inspect(mod)} should export register/0"

        assert function_exported?(mod, :gather_context, 2),
               "#{inspect(mod)} should export gather_context/2"

        # Either arity-2 or arity-3 handle_output is acceptable per the
        # Provider behaviour's @optional_callbacks.
        assert function_exported?(mod, :handle_output, 3) or
                 function_exported?(mod, :handle_output, 2),
               "#{inspect(mod)} should export handle_output/{2,3}"
      end)
    end
  end

  describe "Registry boot with BuiltIns.providers/0" do
    test "upserts memory.daily_summary with the expected spec" do
      {_pid, name} = start_registry(BuiltIns.providers())

      assert %{ok: rows, errors: []} = Registry.status(name)
      keys = rows |> Enum.map(& &1.key) |> Enum.sort()
      assert "memory.daily_summary" in keys
      assert "memory.dreaming" in keys

      row = Responsibilities.get_by_key("memory.daily_summary")
      assert row
      assert row.feature == "memory"
      assert row.trigger_kind == "cron"
      assert row.scope == "per_org"
      # context_provided round-trips as a list of strings (the schema's
      # array-of-string field).
      assert Enum.sort(row.context_provided) == ["org_identity", "recent_journal"]
      assert row.trigger_config["expression"] == "0 23 * * *"
      assert row.enabled == true
      assert row.cost_profile == "low_freq_capable"
    end

    test "upserts memory.dreaming with the expected spec" do
      {_pid, _name} = start_registry(BuiltIns.providers())

      row = Responsibilities.get_by_key("memory.dreaming")
      assert row
      assert row.feature == "memory"
      assert row.trigger_kind == "cron"
      assert row.scope == "per_org"
      assert Enum.sort(row.context_provided) == ["org_identity", "recent_journal"]
      # Task 019f905e: dreaming cron moved 03:00 → 05:00 America/Chicago.
      assert row.trigger_config["expression"] == "0 5 * * *"
      assert row.trigger_config["timezone"] == "America/Chicago"

      # Task 019f70e9 stage 7: dreaming writes to today's journal
      # (`org/journal/YYYY-MM-DD.md`), no longer directly to a static
      # page. Metadata advertises the target kind + prefix so operators
      # can reason about the write destination without loading the code.
      assert row.metadata["target_kind"] == "journal"
      assert row.metadata["target_prefix"] == "org/journal/"
      refute Map.has_key?(row.metadata, "target_file_key")
    end

    test "upserts meetings.summarize with the expected event_topic spec" do
      {_pid, name} = start_registry(BuiltIns.providers())

      assert %{ok: rows, errors: []} = Registry.status(name)
      keys = Enum.map(rows, & &1.key)
      assert "meetings.summarize" in keys

      row = Responsibilities.get_by_key("meetings.summarize")
      assert row
      assert row.feature == "meetings"
      assert row.trigger_kind == "event_topic"
      assert row.scope == "per_meeting"

      assert Enum.sort(row.context_provided) ==
               ["meeting_transcript", "org_identity", "recent_journal"]

      # The router subscribes to the canonical topic (PubSub has no
      # wildcard match — the broadcast helper fans out per-room AND
      # canonical so this single subscription suffices).
      assert row.trigger_config["topic"] == "meeting:finished"
      assert row.trigger_config["topic_pattern"] == "meeting:finished:*"
      assert row.trigger_config["event_match"] == "meeting_finished"

      # Fallback declared at registration time so M6's router knows
      # what to do when no agent holds the Meeting Scribe role.
      assert row.metadata["fallback_kind"] == "legacy"

      assert row.metadata["fallback"] ==
               "Elixir.Platform.Meetings.Summarizer:run_summary:1"

      assert row.cost_profile == "low_freq_capable"
      assert row.enabled == true
    end

    test "upserts meetings.intent_classify with the expected placeholder spec" do
      {_pid, name} = start_registry(BuiltIns.providers())

      assert %{ok: rows, errors: []} = Registry.status(name)
      keys = Enum.map(rows, & &1.key)
      assert "meetings.intent_classify" in keys

      row = Responsibilities.get_by_key("meetings.intent_classify")
      assert row
      assert row.feature == "meetings"
      assert row.trigger_kind == "event_topic"
      assert row.scope == "per_meeting"
      assert row.context_provided == ["meeting_transcript_chunk"]
      assert row.trigger_config["topic"] == "meeting:transcript_chunk"
      assert row.trigger_config["event_match"] == "transcript_chunk"

      # Placeholder marker + runtime-task pointer so an operator grep
      # for `status: "placeholder"` catches this row.
      assert row.metadata["status"] == "placeholder"
      assert row.metadata["runtime_task"] == "019f2452-0210"
      assert row.metadata["owner"] == "platform.meetings"

      # Classifier is a high-frequency call (every transcript chunk),
      # not once-per-meeting like summarize; `high_freq_low_cost` is
      # the schema's cheap tier per `Responsibility.cost_profiles/0`.
      assert row.cost_profile == "high_freq_low_cost"
      assert row.enabled == true
    end

    test "upserts security.cve_scan with the expected null-topic spec (task 019f3e8e)" do
      {_pid, name} = start_registry(BuiltIns.providers())

      assert %{ok: rows, errors: []} = Registry.status(name)
      keys = Enum.map(rows, & &1.key)
      assert "security.cve_scan" in keys
      assert "security.code_audit" in keys
      assert "security.deploy_audit" in keys
      assert "security.secret_leak" in keys

      row = Responsibilities.get_by_key("security.cve_scan")
      assert row
      assert row.feature == "security"
      assert row.trigger_kind == "event_topic"
      assert row.scope == "per_org"
      assert row.context_provided == []

      # The load-bearing design decision — see ADR-0043. The Router
      # subscribes to this topic but no publisher ever broadcasts.
      # Sweeper (stage 2+) is the actual runtime.
      assert row.trigger_config["topic"] == "platform.security.sweeper_only"

      # Metadata pins the placeholder marker + Sweeper hooks so the
      # runtime (stage 2+) can look up cadence + executor without
      # hard-coding module names against keys.
      assert row.metadata["status"] == "placeholder"
      assert row.metadata["executor"] == "platform.security.sweeper"
      assert row.metadata["cadence"] == "0 3 * * 1"
      assert row.metadata["role"] == "security_guard"

      assert row.cost_profile == "low_freq_capable"
      assert row.enabled == true
    end

    test "upserts security.secret_leak with the daily cadence" do
      {_pid, _name} = start_registry(BuiltIns.providers())

      row = Responsibilities.get_by_key("security.secret_leak")
      assert row
      # Secret-leak scans run daily, not weekly — every push is a
      # potential leak. Pin this because a future edit conflating the
      # scans' cadences would silently reduce coverage.
      assert row.metadata["cadence"] == "0 4 * * *"
    end

    test "reload/0 is idempotent — keys + ids stable across boots" do
      {_pid, name} = start_registry(BuiltIns.providers())

      first_rows = Registry.status(name).ok |> Enum.sort_by(& &1.key)
      reloaded = Registry.reload(name)
      second_rows = reloaded.ok |> Enum.sort_by(& &1.key)

      assert Enum.map(first_rows, & &1.key) == Enum.map(second_rows, & &1.key)
      assert Enum.map(first_rows, & &1.id) == Enum.map(second_rows, & &1.id)
      assert reloaded.errors == []
    end
  end

  describe "handler key accessors" do
    test "Handlers.DailySummary.key/0 matches the registered key" do
      assert Handlers.DailySummary.key() == "memory.daily_summary"
    end

    test "Handlers.Dreaming.key/0 matches the registered key" do
      assert Handlers.Dreaming.key() == "memory.dreaming"

      # Task 019f70e9 stage 7: dreaming no longer writes to
      # `org/page/memory.md`. `handle_output/3` writes only to today's
      # journal path so the proposal-review pipeline gates page mutations.
      journal_key = Handlers.Dreaming.journal_file_key(~D[2026-07-19])
      assert journal_key == "org/journal/2026-07-19.md"
    end

    test "Handlers.MeetingSummarize.key/0 + topic/0 match the registered values" do
      assert Handlers.MeetingSummarize.key() == "meetings.summarize"
      assert Handlers.MeetingSummarize.topic() == "meeting:finished"
    end

    test "Handlers.IntentClassify.key/0 matches the registered key" do
      assert Handlers.IntentClassify.key() == "meetings.intent_classify"
    end
  end

  describe "config sync" do
    # The Registry reads `Application.get_env(:platform, Platform.Responsibilities)[:providers]`
    # at boot. `config/config.exs` mirrors `BuiltIns.providers/0` as a
    # literal list (module-function calls aren't allowed at compile-config
    # time). This test catches the drift if a future provider is added to
    # `BuiltIns` but not to `config.exs` (or vice-versa).
    test "config :platform, Platform.Responsibilities[:providers] equals BuiltIns.providers/0" do
      config_providers =
        Application.get_env(:platform, Platform.Responsibilities, [])
        |> Keyword.get(:providers, [])

      assert Enum.sort(config_providers) == Enum.sort(BuiltIns.providers()),
             "config :platform, Platform.Responsibilities[:providers] must match " <>
               "Platform.Responsibilities.BuiltIns.providers/0. Add new built-ins to BOTH."
    end
  end
end
