defmodule Platform.GameStream.ExtensionParityTest do
  @moduledoc """
  Play's side of the `Platform.Extensions` contract (ADR 0055, task 01a0ee08).
  These cases lived in apps/platform/test/platform/extensions_test.exs until
  stage 3 moved Play into its own Mix project; they need Play present, so they
  run where it is: this project's config registers
  `Platform.GameStream.Extension` alone.

    * PARITY: with Play registered, every registry reads as main's did, flag
      off and on. The snapshots were MEASURED on main (eb30c8593) by a probe
      run in the test env on moon, not copied from this branch.
    * Play's processes absent: a disconnect is `:ok` and a play frame is
      dropped, at boot (before `Platform.GameStream.Application` has started
      its tree) or at shutdown.
    * The configured list has no name clash, flag off and on.

  NOT async: cases write `:game_stream, :enabled` (global app env) and stop
  Play's supervisor, restoring both on exit.
  """

  use PlatformWeb.ChannelCase, async: false

  import ExUnit.CaptureLog

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

  @core_kinds ~w(stack row card text markdown heading badge image code mermaid embed form action_row checklist checklist_item table)

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
        allowed_bundles: []
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
    end
  end

  describe "parity with main (eb30c8593): the configured list is Play alone" do
    # Measured on main at eb30c8593 in the test env, flag unset.
    @main_tool_names_off [
      {"canvas.create", "canvas"},
      {"canvas.patch", "canvas"},
      {"canvas.describe", "canvas"},
      {"canvas.list_kinds", "canvas"},
      {"canvas.template", "canvas"},
      {"canvas.versions", "canvas"},
      {"canvas.restore", "canvas"},
      {"send_media", "messaging"},
      {"react", "messaging"},
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
      {"skill.list", "skill"},
      {"skill.get", "skill"},
      {"skill.upsert", "skill"},
      {"attachment.upload_inline", "attachment"},
      {"attachment.get_inline", "attachment"},
      {"attachment.upload_start", "attachment"},
      {"file_list", "files"},
      {"file_get_text", "files"},
      {"file_get_metadata", "files"},
      {"file_search", "files"},
      {"file_add", "files"},
      {"file_delete", "files"},
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
      {"suite_run", "code_mode"},
      {"suite_run_describe", "code_mode"}
    ]

    # sha256 of the canonical term of `tool_definitions/0` on main (see
    # `digest/1`), flag unset and set.
    #
    # Re-pinned by task 01a0fcfa: attachment.get_inline's `returns` and
    # `limitations` text now document the MCP image content block. That is
    # the only tool-definition change. The off digest equals the one
    # apps/platform/test/platform/extensions_test.exs already pins for the
    # same change; both values were measured by main CI at ccff9306b.
    #
    # Re-pinned by task 01a114a8 stage 1: `dispatch_metrics_list` joins the
    # `experiments` bundle. Both values measured on moon at the stage's
    # branch; the off digest equals the one extensions_test.exs pins.
    #
    # Re-pinned by task 01a114a8 stage 2: `suite_run` in the new `code_mode`
    # bundle. Both values measured on moon at the stage's branch; the off
    # digest equals the one extensions_test.exs pins.
    #
    # Re-pinned by task 01a114a8 stage 3: `suite_run_describe`, the
    # `returns_schema` key on 12 definitions, federation_status's filters and
    # the suite_run primer. Measured on moon; off equals extensions_test.exs.
    #
    # Re-pinned by task 01a114a8 stage 4: `code_mode_report` in `experiments`
    # and experiment_create doc text. Measured on moon; off equals
    # extensions_test.exs.
    #
    # Re-pinned by task 01a115b5 stage 2: suite_run_describe's `detail`
    # parameter and description text. Both values measured on moon at the
    # stage's branch; off equals extensions_test.exs.
    #
    # Re-pinned by task 01a116de stage 2: two description strings stop naming
    # one install's root org ("Use the root org id", "root-org admin"). Both
    # values measured on moon at the stage's branch; off equals
    # extensions_test.exs.
    #
    # Re-pinned by task 019fa1ac at the rebased tip (after the Fabrikam scrub
    # and Burrow rebrand landed on main): task_create/task_update expose the
    # kind taxonomy and task read/write docs name kind. Both values measured
    # by main CI at this branch head; off equals extensions_test.exs.
    #
    # Re-pinned at the stack/feedback-intake-boundary merge of origin/main
    # (PR #1226): the stack's kind, external-feedback provenance and
    # `janitor_hand_back` (task 019fa1ac-6685) on main's scrubbed copy. Both
    # values measured on moon at the merge; off equals extensions_test.exs.
    #
    # Re-pinned by task 01a131c5 (deploy fix-forward): `vault_fetch` and
    # `vault_list` in the `federation` bundle, after `federation_status`. Off
    # equals extensions_test.exs (stage 1's moon measurement); on measured by
    # main CI at this branch head.
    @main_tool_digest_off "42ab329bc2d2f2c65a8b8cf1d56664308e67e2f6de573c3c3f5897eb3b49382e"
    @main_tool_digest_on "09d229de4f1cd66cb0c22d39bf18c1304e90206b35d5f29d5080b94c3a74ce93"
    @main_kinds_summaries_digest_off "4c060fb7a6914985f94857aaac9effbb519dd2b2170c7a9c0013d4db15a73ea4"
    @main_kinds_summaries_digest_on "dbab62a1b3d154e23378f3a990b77deb17c5f50eb30adf0b055bc0df8ce6c1e3"
    @main_kinds_tool_schemas_digest_off "e454cd9e2aeb1d821a70b74fe433e81ba98b94f7ae9f2d59c55f8cf5bf509af8"
    @main_kinds_tool_schemas_digest_on "66a2afcec34a8e4b6275ab78f21f7bb124b671a12f690399556b2ad6f2b331ef"
    @main_metrics_catalog_digest "95805ed557855b482286544ea8d5ea6063b81e47ce1ee28268467a7df2848ee9"
    @main_bundles ~w(canvas messaging task plan review space context_read federation memory skill attachment files meetings mail experiments code_mode play)
    @main_valid_bundles ~w(federation space context_read messaging review canvas task plan memory skill attachment files meetings mail experiments code_mode play)
    @main_rail [
      :chat,
      :tasks,
      :inbox,
      :activity,
      :skills,
      :files,
      :context,
      :prompts,
      :experiments,
      :meetings,
      :admin
    ]
    @main_metrics ~w(cycle_time game_stream_input_to_photon game_stream_input_to_photon_worst_slot_p95 manual_gate_rejection_rate overscoped_gate_count plan_revision_count stages_per_plan time_in_phase validation_failure_rate)
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
    @main_surfaces ~w(dispatch.prompt mail.draft.generator planner.stage_budget chat.context_summary game_stream.encoder_preset game_stream.roster meetings.open_question_classifier game_stream.touch dispatch.product_docs_preamble dispatch.code_mode)
    @branch_surfaces ~w(dispatch.prompt mail.draft.generator planner.stage_budget chat.context_summary meetings.open_question_classifier dispatch.product_docs_preamble dispatch.code_mode game_stream.encoder_preset game_stream.roster game_stream.touch)

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

    test "flag off: tool_definitions/0 is main's, name for name and byte for byte" do
      defs = ToolSurface.tool_definitions()
      assert Enum.map(defs, &{&1.name, &1.bundle}) == @main_tool_names_off
      assert digest(defs) == @main_tool_digest_off
    end

    test "flag on: tool_definitions/0 is main's, byte for byte" do
      Application.put_env(:game_stream, :enabled, true)
      defs = ToolSurface.tool_definitions()

      assert Enum.map(defs, &{&1.name, &1.bundle}) ==
               @main_tool_names_off ++
                 [
                   {"play_session_start", "play"},
                   {"play_session_stop", "play"},
                   {"play_session_status", "play"}
                 ]

      assert digest(defs) == @main_tool_digest_on
    end

    test "bundles, kinds, metrics and rail are main's, flag off and on" do
      for flag <- [false, true] do
        Application.put_env(:game_stream, :enabled, flag)
        assert ToolSurface.all_bundles() == @main_bundles
        assert AgentRuntime.valid_bundles() == @main_valid_bundles
        assert Metrics.known_metrics() == @main_metrics
        assert digest(Metrics.catalog()) == @main_metrics_catalog_digest
        assert Enum.map(IconRail.destinations(root_user: true), & &1.key) == @main_rail
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
