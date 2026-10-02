defmodule Platform.GameStream.ModuleInventoryTest do
  @moduledoc """
  The assertions core's own suite made about Play, moved where Play is
  present (ADR 0055, task 01a0ee08 stage 3). Core's copies now state core's
  lists alone; each case below states the same list WITH Play, as a literal,
  exactly as core's did before the move, so nothing was weakened by moving:

    * `experiments/guardrails_test.exs`: the default allowed surfaces;
    * `responsibilities/experiments_scientist_test.exs`: the surfaces the
      scientist's context carries;
    * `regression/pubsub_topic_inventory_audit_test.exs`: the topics Play's
      lib constructs, classified here with the same scanner;
    * `repo_lookup_boundary_test.exs`: the `Repo.get`-family sites in Play's
      lib, classified here with the same scanner and the same reasons.
  """

  use Platform.DataCase, async: false

  alias Platform.Experiments.Guardrails
  alias Platform.Responsibilities.Handlers.ExperimentsScientist
  alias Platform.Test.PubSubTopicScan
  alias Platform.Support.RepoLookupScan

  @lib_root Path.expand("../../../lib", __DIR__)

  # Core's copy also lists `mail.test.generator` and `test.budget`, which
  # that file's own setup registers; this list is core's registered surfaces
  # plus Play's three (task 01a0fe45 added game_stream.touch), and nothing else.
  test "the default allowed surfaces include Play's three" do
    rails = Guardrails.for_org(nil)

    assert Enum.sort(rails.allowed_surfaces) ==
             [
               "chat.context_summary",
               "dispatch.prompt",
               "game_stream.encoder_preset",
               "game_stream.roster",
               "game_stream.touch",
               "mail.draft.generator",
               "meetings.open_question_classifier",
               "planner.stage_budget"
             ]

    assert Guardrails.default_allowed_surfaces() == rails.allowed_surfaces
  end

  test "the scientist's context carries Play's three surfaces" do
    context = ExperimentsScientist.gather_context(%{})

    assert Enum.map(context.surfaces, & &1.key) |> Enum.sort() ==
             [
               "chat.context_summary",
               "dispatch.prompt",
               "game_stream.encoder_preset",
               "game_stream.roster",
               "game_stream.touch",
               "mail.draft.generator",
               "meetings.open_question_classifier",
               "planner.stage_budget"
             ]
  end

  # {normalised shape, scope class}, the vocabulary core's inventory uses.
  @topics [
    # Task 01a0db5f: one play session's status and WebRTC signalling, keyed
    # by the session id. A session builds exactly one task's review build and
    # its canvas lives in that task's execution space; stage 4's hook
    # subscribes only for a session_id carried by a canvas the viewer can
    # read. Only published while GAME_STREAM_ENABLED is set.
    {"game_stream:<id>", :task},
    # Core's topic, classified `:runtime` in core's inventory too: Play pushes
    # a session's instructions to its play host's runtime channel.
    {"runtime:<id>", :runtime}
  ]

  test "every PubSub topic shape Play's lib constructs is classified, and nothing else" do
    discovered = PubSubTopicScan.topic_shapes(@lib_root) |> Enum.map(&elem(&1, 0))
    # Non-vacuity: the scan sees the topic helper it is known to find.
    assert "game_stream:<id>" in discovered
    assert Enum.sort(discovered) == Enum.sort(Enum.map(@topics, &elem(&1, 0)))
  end

  # {path under apps/game_stream/lib, call kind, schema alias, count, class, reason}
  @inventory [
    {"platform/game_stream/review_build.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "fetch_task/1's predicate. `task_id` is the play_session_start MCP argument; the guard folds a malformed id into {:error, :task_not_found} before Tasks.get_task_record/1 runs"},
    {"platform/game_stream/review_build.ex", :get, "Platform.Tasks.Project", 1, :safe_internal,
     "project_repo/1 keys it by `task.project_id` off a `%Task{}` just loaded from the DB — an FK column Postgres typed as uuid, never caller input"},
    {"platform/game_stream/seed.ex", :get_by, "User", 1, :safe_internal,
     "keyed `email:`, a plain string column; a miss is {:error, :unknown_owner}. Called only from a Mix task or `bin/platform rpc`"}
  ]

  test "every Repo.get-family site in Play's lib is classified, with the recorded count" do
    scanned = RepoLookupScan.call_sites_under(@lib_root)
    recorded = Map.new(@inventory, fn {p, k, s, c, _class, _reason} -> {{p, k, s}, c} end)
    assert scanned == recorded

    for {_p, _k, _s, _c, class, reason} <- @inventory do
      assert class == :safe_internal
      assert String.length(reason) > 40
    end
  end
end
