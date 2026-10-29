defmodule Platform.GameStream.ExtensionParityTest do
  @moduledoc """
  Play's side of the `Platform.Extensions` contract (ADR 0055, task 01a0ee08).
  These cases lived in apps/platform/test/platform/extensions_test.exs until
  stage 3 moved Play into its own Mix project; they need Play present, so they
  run where it is: this project's config registers
  `Platform.GameStream.Extension` alone.

    * PARITY: with Play registered, every registry reads as main's did, flag
      off and on. The snapshots were MEASURED on main (eb30c8593) by a probe
      run in the test env on test-host, not copied from this branch.
    * Play's processes absent: a disconnect is `:ok` and a play frame is
      dropped, at boot (before `Platform.GameStream.Application` has started
      its tree) or at shutdown.
    * The configured list has no name clash, flag off and on.

  NOT async: cases write `:game_stream, :enabled` (global app env) and stop
  Play's supervisor, restoring both on exit.
  """

  use PlatformWeb.ChannelCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Access.RuntimeProfiles
  alias Platform.Accounts.User
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat.Canvas.Kinds
  alias Platform.Experiments.Metrics
  alias Platform.Experiments.Surfaces
  alias Platform.Extensions
  alias Platform.Federation
  alias Platform.Federation.ToolAuthorization
  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias PlatformWeb.Components.IconRail

  @core_kinds ~w(stack row card text markdown heading badge image code mermaid embed form action_row checklist checklist_item table prototype)

  setup do
    previous_flag = Application.fetch_env(:game_stream, :enabled)
    Application.delete_env(:game_stream, :enabled)

    on_exit(fn ->
      case previous_flag do
        {:ok, value} -> Application.put_env(:game_stream, :enabled, value)
        :error -> Application.delete_env(:game_stream, :enabled)
      end
    end)

    :ok
  end

  defp unique, do: System.unique_integer([:positive])

  defp join_runtime do
    user =
      Repo.insert!(%User{
        email: "ext-#{unique()}@example.com",
        name: "Extensions User",
        oidc_sub: "ext-#{unique()}"
      })

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "ext-rt-#{unique()}",
        tool_profile: []
      })

    {:ok, runtime, token} = Federation.activate_runtime(runtime)

    {:ok, socket} =
      connect(PlatformWeb.RuntimeSocket, %{"runtime_id" => runtime.runtime_id, "token" => token})

    {:ok, _reply, socket} = subscribe_and_join(socket, "runtime:#{runtime.runtime_id}", %{})
    {runtime, socket}
  end

  # Pushes frames, then a round trip, so every frame above has been handled.
  defp push_and_settle(socket, frames) do
    for {event, payload} <- frames, do: push(socket, event, payload)
    ref = push(socket, "pong", %{})
    assert is_reference(ref)
    :sys.get_state(socket.channel_pid)
  end

  describe "Play's processes absent" do
    test "Play: with its Registry stopped, disconnect is :ok and a play frame is dropped, at boot or at shutdown" do
      Application.put_env(:game_stream, :enabled, true)
      app_sup = Platform.GameStream.Application.Supervisor
      :ok = Supervisor.terminate_child(app_sup, Platform.GameStream.Supervisor)

      on_exit(fn ->
        {:ok, _} = Supervisor.restart_child(app_sup, Platform.GameStream.Supervisor)
      end)

      assert Process.whereis(Platform.GameStream.Supervisor.registry()) == nil
      assert Platform.GameStream.Extension.runtime_disconnected("host-1") == :ok
      assert Extensions.runtime_disconnected("host-1") == :ok

      assert Platform.GameStream.Extension.handle_runtime_event(
               "play_signal",
               "host-1",
               %{"session_id" => "x", "kind" => "offer", "data" => %{}}
             ) == {:error, :not_running}

      {_runtime, socket} = join_runtime()

      capture_log(fn ->
        push_and_settle(socket, [
          {"play_signal", %{"session_id" => "x", "kind" => "offer", "data" => %{}}},
          {"play_session_status", %{"session_id" => "x", "state" => "live"}},
          {"play_slot_activity", %{"session_id" => "x", "slots" => [0]}}
        ])
      end)

      assert Process.alive?(socket.channel_pid)
    end
  end

  describe "name clashes" do
    test "the configured list (Play), flag off and on, has no clash" do
      assert Extensions.list() == [Platform.GameStream.Extension]
      assert Extensions.validate() == :ok
      Application.put_env(:game_stream, :enabled, true)
      assert Extensions.validate() == :ok

      # Task 01a14a7f stage 3: with Play listed, no tool name carries a dot
      # and none repeats once separators are normalised.
      names = Enum.map(ToolSurface.tool_definitions(), & &1.name)
      assert Enum.any?(names, &String.starts_with?(&1, "play_"))
      assert Enum.filter(names, &String.contains?(&1, ".")) == []
      normalised = Enum.map(names, &Extensions.normalise_tool_name/1)
      assert length(Enum.uniq(normalised)) == length(names)
    end
  end

  describe "parity with main (eb30c8593): the configured list is Play alone" do
    # Measured on main at eb30c8593 in the test env, flag unset.
    @main_tool_names_off [
      {"canvas_create", "canvas"},
      {"canvas_patch", "canvas"},
      {"canvas_describe", "canvas"},
      {"canvas_list_kinds", "canvas"},
      {"canvas_template", "canvas"},
      {"canvas_versions", "canvas"},
      {"canvas_restore", "canvas"},
      {"send_media", "messaging"},
      {"react", "messaging"},
      {"blocker_recheck", "task"},
      {"blocker_verify", "task"},
      {"project_list", "task"},
      {"org_list_descendants", "task"},
      {"project_update", "task"},
      {"epic_list", "task"},
      {"epic_update", "task"},
      {"epic_create", "task"},
      {"task_create", "task"},
      {"task_get", "task"},
      {"task_transition_list", "task"},
      {"runtime_event_list", "task"},
      {"execution_lease_list", "task"},
      {"task_list", "task"},
      {"task_complete", "task"},
      {"task_close_as_delivered", "task"},
      {"task_delivery_candidate_list", "task"},
      {"task_update", "task"},
      {"task_start", "task"},
      {"task_ack", "task"},
      {"alarm_silence", "task"},
      {"task_dependencies", "task"},
      {"task_attach_canvas", "task"},
      {"task_design_decline", "task"},
      {"task_detach_canvas", "task"},
      {"task_list_canvases", "task"},
      {"stack_create", "task"},
      {"stack_update", "task"},
      {"stack_get", "task"},
      {"stack_list", "task"},
      {"stack_add", "task"},
      {"stack_add_dependency", "task"},
      {"stack_remove_dependency", "task"},
      {"stack_eject", "task"},
      {"stack_abandon", "task"},
      {"stack_complete", "task"},
      {"stack_start", "task"},
      {"stack_retry_member_merge", "task"},
      {"stack_start_planning", "task"},
      {"stack_assign_agents", "task"},
      {"stack_attach_canvas", "task"},
      {"stack_detach_canvas", "task"},
      {"janitor_hand_back", "task"},
      {"plan_create", "plan"},
      {"plan_update", "plan"},
      {"plan_get", "plan"},
      {"plan_submit", "plan"},
      {"plan_approve", "plan"},
      {"plan_reject", "plan"},
      {"validation_payload_amend", "plan"},
      {"plan_architecture_verdict", "plan"},
      {"stage_architecture_audit", "plan"},
      {"stage_start", "plan"},
      {"stage_list", "plan"},
      {"validation_evaluate", "plan"},
      {"validation_pass", "plan"},
      {"stage_complete", "plan"},
      {"report_blocker", "plan"},
      {"validation_list", "plan"},
      {"prompt_template_list", "plan"},
      {"prompt_template_update", "plan"},
      {"review_request_create", "review"},
      {"review_request_get", "review"},
      {"review_item_list", "review"},
      {"design_critique_request", "review"},
      {"space_create", "space"},
      {"space_list", "space"},
      {"space_list_agents", "space"},
      {"space_leave", "space"},
      {"dm_create", "space"},
      {"space_get_context", "context_read"},
      {"space_search_messages", "context_read"},
      {"space_get_messages", "context_read"},
      {"canvas_list", "context_read"},
      {"canvas_get", "context_read"},
      {"principal_search", "context_read"},
      {"federation_status", "federation"},
      {"vault_fetch", "federation"},
      {"vault_list", "federation"},
      {"memory_view", "memory"},
      {"memory_create", "memory"},
      {"memory_str_replace", "memory"},
      {"memory_insert", "memory"},
      {"memory_delete", "memory"},
      {"memory_rename", "memory"},
      {"memory_search", "memory"},
      {"org_memory_recently_edited", "memory"},
      {"org_memory_recently_deleted", "memory"},
      {"org_memory_feedback_at_path", "memory"},
      {"skill_list", "skill"},
      {"skill_get", "skill"},
      {"skill_upsert", "skill"},
      {"attachment_upload_inline", "attachment"},
      {"attachment_get_inline", "attachment"},
      {"attachment_upload_start", "attachment"},
      {"file_list", "files"},
      {"file_get_text", "files"},
      {"file_get_metadata", "files"},
      {"file_search", "files"},
      {"file_add", "files"},
      {"file_delete", "files"},
      {"meeting_scribe_complete", "meetings"},
      {"meeting_triage_file", "meetings"},
      {"meeting_create", "meetings"},
      {"meeting_say", "meetings"},
      {"meeting_activity_push", "meetings"},
      {"intent_ack", "meetings"},
      {"experiment_surface_list", "experiments"},
      {"experiment_list", "experiments"},
      {"experiment_get", "experiments"},
      {"experiment_create", "experiments"},
      {"experiment_variant_add", "experiments"},
      {"experiment_start", "experiments"},
      {"experiment_stop", "experiments"},
      {"experiment_conclude", "experiments"},
      {"experiment_results", "experiments"},
      {"experiment_signals_list", "experiments"},
      {"experiment_exclude", "experiments"},
      {"experiment_goal_set", "experiments"},
      {"experiment_goal_list", "experiments"},
      {"experiment_promote", "experiments"},
      {"dispatch_metrics_list", "experiments"},
      {"code_mode_report", "experiments"},
      {"burrow_run", "code_mode"},
      {"burrow_run_describe", "code_mode"},
      {"prototype_publish", "prototype"},
      {"prototype_versions", "prototype"},
      {"prototype_rollback", "prototype"},
      {"access_explain", "access"},
      {"access_propose", "access"},
      {"access_apply", "access"},
      {"access_undo", "access"}
    ]

    # sha256 of the canonical term of `tool_definitions/0` on main (see
    # `digest/1`), flag unset and set.
    #
    # Re-pinned by task 01a0fcfa: attachment_get_inline's `returns` and
    # `limitations` text now document the MCP image content block. That is
    # the only tool-definition change. The off digest equals the one
    # apps/platform/test/platform/extensions_test.exs already pins for the
    # same change; both values were measured by main CI at ccff9306b.
    #
    # Re-pinned by task 01a114a8 stage 1: `dispatch_metrics_list` joins the
    # `experiments` bundle. Both values measured on test-host at the stage's
    # branch; the off digest equals the one extensions_test.exs pins.
    #
    # Re-pinned by task 01a114a8 stage 2: `suite_run` in the new `code_mode`
    # bundle. Both values measured on test-host at the stage's branch; the off
    # digest equals the one extensions_test.exs pins.
    #
    # Re-pinned by task 01a114a8 stage 3: `suite_run_describe`, the
    # `returns_schema` key on 12 definitions, federation_status's filters and
    # the suite_run primer. Measured on test-host; off equals extensions_test.exs.
    #
    # Re-pinned by task 01a114a8 stage 4: `code_mode_report` in `experiments`
    # and experiment_create doc text. Measured on test-host; off equals
    # extensions_test.exs.
    #
    # Re-pinned by task 01a115b5 stage 2: suite_run_describe's `detail`
    # parameter and description text. Both values measured on test-host at the
    # stage's branch; off equals extensions_test.exs.
    #
    # Re-pinned by task 01a116de stage 2: two description strings stop naming
    # one install's root org ("Use the root org id", "root-org admin"). Both
    # values measured on test-host at the stage's branch; off equals
    # extensions_test.exs.
    #
    # Re-pinned by task 019fa1ac at the rebased tip (after the Legacy scrub
    # and Burrow rebrand landed on main): task_create/task_update expose the
    # kind taxonomy and task read/write docs name kind. Both values measured
    # by main CI at this branch head; off equals extensions_test.exs.
    #
    # Re-pinned at the stack/feedback-intake-boundary merge of origin/main
    # (PR #1226): the stack's kind, external-feedback provenance and
    # `janitor_hand_back` (task 019fa1ac-6685) on main's scrubbed copy. Both
    # values measured on test-host at the merge; off equals extensions_test.exs.
    #
    # Re-pinned by task 01a1316b-4e46 stage 1: the `prototype` bundle's three
    # tools, after core's others. Both values measured on test-host at the stage's
    # branch; off equals extensions_test.exs.
    #
    # Re-pinned by task 01a1316b-4e46 stage 2: the `prototype` canvas kind,
    # last in core's registry, which also enters canvas_create/patch's
    # document schema. All six values measured on test-host at the stage's branch;
    # off equals extensions_test.exs.
    #
    # Re-pinned by task 01a1316b-677a stage 1: the `embed` kind's `scripts`
    # and `prototype_ref` props and its srcdoc / list_kinds text, which also
    # enter canvas_create/patch's document schema. All six values measured on
    # test-host at the stage's branch; off equals extensions_test.exs. The metrics
    # catalog digest is unchanged.
    #
    # Re-pinned by task 01a1316b-aab0 stage 2: canvas_patch's operation
    # description names the new `set_binding` op. Both values measured on
    # test-host at the stage's branch; off equals extensions_test.exs. The kinds
    # and metrics digests are unchanged.
    #
    # Re-pinned by task 01a131c5 (deploy fix-forward): `vault_fetch` and
    # `vault_list` in the `federation` bundle, after `federation_status`. Off
    # equals extensions_test.exs (stage 1's test-host measurement); on measured by
    # main CI at this branch head.
    #
    # Re-pinned by the stack prototype-runtime rollup merge (#1235): both of the
    # above. All six values measured on test-host at the merge commit; off equals
    # extensions_test.exs.
    # RBAC v2 adds four Access tools, text principal_id/action disabled canvas
    # properties, the Agents rail destination and agents.tool_profile surface.
    # Re-measured whole definitions/kinds on Test-Host at 3d831a04, flag off/on;
    # literal names and whole-payload digests remain strict independent pins.
    # Re-pinned by task 01a14a7f stage 3: the 17 dotted tool names became
    # underscores, in names and in every description and schema text that
    # cites one (the image kind's `src` text moves the kinds tool-schemas
    # digests; the summaries digests do not move). Measured on test-host at the
    # stage's branch.
    # Re-pinned by task 01a14b9e-50a4 (Burrow rename A2, deploy fix-forward):
    # stage 1 renamed suite_run / suite_run_describe to burrow_run /
    # burrow_run_describe and stages 1-2 changed "Suite" to "Burrow" in tool
    # descriptions, canvas kind descriptions and the embed kind's schema text,
    # so all six digests move. The metrics catalog digest is unchanged. All six
    # measured on test-host (elixir:1.20.4-otp-28-slim, CI's image) at the merge of
    # main into the branch; the kinds-summaries off value equals what main CI
    # printed for the unpinned branch. These are NOT equal to
    # apps/platform/test/platform/extensions_test.exs's off pins, and were not
    # on main either (c48e9187 here vs 26c07041 there).
    #
    # Re-pinned by task 01a14b9e-c802 stage 3: tool descriptions name neutral
    # examples instead of one install's people and hosts (`alex-coder`,
    # `agent-1.host-a`, `infra` (test rig, ...), "a human picks option A or
    # B", "a human editor"), so the two tool-definition digests move. The
    # summaries, schemas and metrics digests are unchanged. Measured on the
    # test rig at the A3 branch after merging main (fb3332ff).
    #
    # Re-pinned by task 01a1559a stage 1: the `limitations` prose of
    # task_attach_canvas, task_detach_canvas and task_list_canvases names the
    # new gate (`tasks.write` / `tasks.read` in the task's org), so both
    # tool-definition digests move. Names, bundles, summaries, schemas and
    # metrics are unchanged. Measured on the test rig at the stage's branch
    # (81a96d91).
    #
    # Re-pinned by task 01a1559a stage 2: `stack_attach_canvas` and
    # `stack_detach_canvas` in the `task` bundle after `stack_assign_agents`
    # (the name list above carries them), so both tool-definition digests
    # move. Summaries, schemas and metrics are unchanged. Measured on the test rig at
    # the stage's branch (d8f4696c).
    #
    # Re-pinned by task 01a1655c stage 2: `send_media` gains the optional
    # `attachment_ids` property and the prose describing it, so both
    # tool-definition digests move. Names and bundles are unchanged. Measured
    # by CI on the task branch (c7c3379ce), PR #1320.
    # Re-pinned by task 01a1830b stage 4: meeting triage action_items prose
    # now requires accepted candidate_ids and stable provenance on replay.
    # Tool names, parameter shapes and kind digests are unchanged. The full
    # Play rig measured these at 9b254a93a; main 1f0f4486b retained old pins.
    # Task 01a18305: add blocker_recheck/blocker_verify before project_list,
    # and the typed dependency fields on report_blocker. Measured at 5a289a564;
    # removing just those additions recovers both previous digests exactly.
    @main_tool_digest_off "7aca2e98981962a2c77f4967f5fa429fa995c4baceb0d30ded53e9ce335645fe"
    @main_tool_digest_on "c5fa92a1117a86778d813e4da43fc88e836ed61381c9f73bea5755a4ab732850"
    @main_kinds_summaries_digest_off "1b337c131bca3720e1158e67d9fa1374ce4b08c60987f9d5f0ff10e5ffc6104a"
    @main_kinds_summaries_digest_on "e99a61e52a6858f0e97255683ebdc33d58c0fd56b4ada613946dc6a99ab2004e"
    @main_kinds_tool_schemas_digest_off "61843c26d260fdb0ca751f9106a1b4d1f7c0a68cbfca79425c6f03e02bcc96a8"
    @main_kinds_tool_schemas_digest_on "d5525de283443869efe51122adc1649e78e95da27bab2b2adc1deee59855878d"
    # Task 01a13867 adds the core metric insight_acceptance_rate to the catalog.
    @main_metrics_catalog_digest "3a5e4c9bd2a90f895185dea9a79084f151e73f9cb4eebd9ec42a2cb8500a260a"
    @main_bundles ~w(canvas messaging task plan review space context_read federation memory skill attachment files meetings mail experiments code_mode prototype access admin voice_ask play)
    @main_valid_bundles ~w(federation space context_read messaging review canvas task plan memory skill attachment files meetings mail experiments code_mode prototype access admin voice_ask play)
    # Activity left the rail with its page (task 01a1557a-7a71 stage 4).
    # Canvases joined it as the More sheet's row into the Files browser
    # (task 01a1557a-b5f9 stage 3).
    @main_rail [
      :chat,
      # The Voice tab (task 01a1557a-eab7 stage 2).
      :voice,
      :tasks,
      :inbox,
      :agents,
      :skills,
      :files,
      :canvases,
      :context,
      :prompts,
      :experiments,
      # Native Calendar destination, task 01a16991 stage 2.
      :calendar,
      :meetings,
      # The More-sheet-only Changelog (task 01a1557a-807f stage 2, `:sheet`).
      :changelog,
      :admin
    ]
    @main_metrics ~w(cycle_time game_stream_input_to_photon game_stream_input_to_photon_worst_slot_p95 insight_acceptance_rate manual_gate_rejection_rate overscoped_gate_count plan_revision_count stages_per_plan time_in_phase validation_failure_rate)
    # main's ORDER: dispatch.prompt, mail.draft.generator, planner.stage_budget,
    # chat.context_summary, game_stream.encoder_preset, game_stream.roster,
    # meetings.open_question_classifier. The stage appends extension surfaces
    # after core's, so the two Play keys move behind the classifier: the SET
    # is main's, the order is not (recorded in the stage summary).
    # Task 01a0fe45 adds game_stream.touch, the third Play surface, appended
    # after the roster in extension.ex. It is new, so it is in neither of
    # main's pre-extraction lists; both pins gain it at the end.
    # Task 01a10a44 adds dispatch.product_docs_preamble, a core surface appended
    # after the classifier in core's list, so it precedes the Play keys. It is
    # new, so both pins gain it the same way game_stream.touch was added.
    # Task 01a114a8 stage 4 adds dispatch.code_mode, a core surface appended
    # after dispatch.product_docs_preamble, so it too precedes the Play keys.
    # Task 01a13867 adds memory.insight_synthesis, a core surface appended
    # after agents.tool_profile, so it precedes the Play keys as well; it also
    # adds the core metric insight_acceptance_rate.
    @main_surfaces ~w(dispatch.prompt mail.draft.generator planner.stage_budget chat.context_summary game_stream.encoder_preset game_stream.roster meetings.open_question_classifier game_stream.touch dispatch.product_docs_preamble dispatch.code_mode agents.tool_profile memory.insight_synthesis)
    @branch_surfaces ~w(dispatch.prompt mail.draft.generator planner.stage_budget chat.context_summary meetings.open_question_classifier dispatch.product_docs_preamble dispatch.code_mode agents.tool_profile memory.insight_synthesis game_stream.encoder_preset game_stream.roster game_stream.touch)

    defp canon(%_{} = s), do: canon(Map.from_struct(s))

    defp canon(m) when is_map(m),
      do: {:map, m |> Enum.map(fn {k, v} -> {canon(k), canon(v)} end) |> Enum.sort()}

    defp canon(l) when is_list(l), do: Enum.map(l, &canon/1)

    defp canon(t) when is_tuple(t),
      do: t |> Tuple.to_list() |> Enum.map(&canon/1) |> List.to_tuple()

    defp canon(f) when is_function(f), do: {:fun, inspect(f)}
    defp canon(x), do: x

    defp digest(term),
      do:
        :crypto.hash(:sha256, :erlang.term_to_binary(canon(term))) |> Base.encode16(case: :lower)

    setup do
      assert Extensions.list() == [Platform.GameStream.Extension]
      :ok
    end

    # Calendar task 01a16991 is additive to both Play flag states. The frozen
    # oracle below still checks every earlier definition byte for byte.
    defp pre_calendar_tool_definitions do
      {calendar, prior} =
        Enum.split_with(
          ToolSurface.tool_definitions(),
          &(&1.name in ["calendar_list", "calendar_propose"])
        )

      assert Enum.map(calendar, &{&1.name, &1.bundle}) == [
               {"calendar_list", "context_read"},
               {"calendar_propose", "context_read"}
             ]

      prior
    end

    test "flag off: tool_definitions/0 is main's, name for name and byte for byte" do
      # Task 01a17b10 stages 3 and 4: the `admin` and `voice_ask` bundles are
      # additive to main's list, set aside here (and asserted by name in the
      # core extensions_test).
      defs = Enum.reject(pre_calendar_tool_definitions(), &(&1.bundle in ["admin", "voice_ask"]))
      assert Enum.map(defs, &{&1.name, &1.bundle}) == @main_tool_names_off
      assert digest(defs) == @main_tool_digest_off
    end

    test "flag on: tool_definitions/0 is main's, byte for byte" do
      Application.put_env(:game_stream, :enabled, true)
      defs = Enum.reject(pre_calendar_tool_definitions(), &(&1.bundle in ["admin", "voice_ask"]))

      assert Enum.map(defs, &{&1.name, &1.bundle}) ==
               @main_tool_names_off ++
                 [
                   {"play_session_start", "play"},
                   {"play_session_stop", "play"},
                   {"play_session_status", "play"}
                 ]

      assert digest(defs) == @main_tool_digest_on
    end

    # The one rail change since main (task 01a1557a-efdd stage 1): More >
    # Games, after Canvases, exists only while the game_stream kind is
    # registered, i.e. with the flag on.
    defp rail_for(false), do: @main_rail

    defp rail_for(true) do
      {before, after_canvases} = Enum.split_while(@main_rail, &(&1 != :canvases))
      before ++ [:canvases, :games] ++ tl(after_canvases)
    end

    test "bundles, kinds, metrics and rail are main's, flag off and on" do
      for flag <- [false, true] do
        Application.put_env(:game_stream, :enabled, flag)
        assert ToolSurface.all_bundles() == @main_bundles
        assert RuntimeProfiles.valid_modules() == @main_valid_bundles
        assert Metrics.known_metrics() == @main_metrics
        assert digest(Metrics.catalog()) == @main_metrics_catalog_digest
        assert Enum.map(IconRail.destinations(root_user: true), & &1.key) == rail_for(flag)
      end

      Application.delete_env(:game_stream, :enabled)
      assert Kinds.names() == @core_kinds
      assert digest(Kinds.summaries()) == @main_kinds_summaries_digest_off
      assert digest(Kinds.tool_schemas()) == @main_kinds_tool_schemas_digest_off

      Application.put_env(:game_stream, :enabled, true)
      assert Kinds.names() == @core_kinds ++ ["game_stream"]
      assert digest(Kinds.summaries()) == @main_kinds_summaries_digest_on
      assert digest(Kinds.tool_schemas()) == @main_kinds_tool_schemas_digest_on
    end

    test "surfaces: main's set plus game_stream.touch; the Play keys follow core's" do
      keys = Enum.map(Surfaces.list(), & &1.key())
      assert Enum.sort(keys) == Enum.sort(@main_surfaces)
      assert keys == @branch_surfaces
    end

    test "flag off: a play tool call still gets the game_stream_disabled refusal" do
      assert {:error, %{code: :game_stream_disabled}} =
               ToolSurface.execute("play_session_start", %{}, %{})

      assert ToolAuthorization.deny_message("play_session_start") ==
               Platform.Federation.PlayTools.disabled_error().error
    end
  end
end
