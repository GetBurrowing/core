defmodule Platform.Responsibilities.NativeDispatchSpaceTest do
  @moduledoc """
  The Router half of the meeting-intent invite fix (2026-08-01, Rowan's DM
  — no task behind it).

  ## What is under test

  `Router.put_dispatch_space/2`: a provider that names `:dispatch_space_id`
  in its gathered context gets that space onto the native signal's
  `metadata.space_id`, which is what `AgentResponder.broadcast_system_event/3`
  hands the funnel as the `space_id:` OPTION, which is the only input
  `DispatchMembership.ensure_writable/3` has.

  ## Why the negative cases carry the weight

  The invite is deliberately OPT-IN. Two ways to get this wrong produce
  the same green on a test that only checks the positive case:

    * lifting the space from `trigger_meta` instead of the provider's
      context, which would make every event_topic fire whose payload
      mentions a space start inviting its agent into it;
    * keying on a plain `:space_id` context slot, which would sweep in
      any provider that happens to gather one.

  So a cron fire whose provider names NO space is asserted to leave the
  key ABSENT — not nil, absent — and a fire whose trigger_meta names a
  space while its provider does not is asserted the same way.

  ## The invariant, asserted here as well as at the funnel

  Top-level `signal.space_id` must stay out of the SYSTEM_EVENT WIRE
  envelope (`AgentResponder.@correlation_id_keys`). The signal captured
  here is the Router→AgentResponder signal, one seam earlier, and it has
  always carried a top-level `:space_id` when `trigger_meta` had one —
  `build_native_signal/5` still does that and this change does not touch
  it. What matters at THIS seam is that the dispatch space arrives in
  `metadata` and does not become a second top-level claim; the wire half
  is pinned in `agent_responder_attention_funnel_test.exs`.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.BuiltIns
  alias Platform.Responsibilities.Handlers.MeetingActionItems
  alias Platform.Responsibilities.Registry
  alias Platform.Responsibilities.Router
  alias Platform.Roles
  alias Platform.Roles.Role

  @capture_key :native_dispatch_space_capture_pid

  defmodule CaptureDispatcher do
    @moduledoc false
    def maybe_dispatch(signal) do
      pid = Application.get_env(:platform, :native_dispatch_space_capture_pid)
      if is_pid(pid), do: send(pid, {:captured_signal, signal})
      :ok
    end
  end

  defmodule SpaceNamingProvider do
    @moduledoc false
    @behaviour Platform.Responsibilities.Provider

    @impl true
    def register, do: []

    @impl true
    def gather_context(_r, _meta) do
      {:ok,
       %{
         dispatch_space_id: Application.get_env(:platform, :native_dispatch_space_value),
         some_slot: "body"
       }}
    end

    @impl true
    def build_prompt(_ctx), do: {:ok, %{system: "SYS", user: "USR"}}

    @impl true
    def handle_output(_r, _o), do: :ok
  end

  defmodule SpacelessProvider do
    @moduledoc false
    @behaviour Platform.Responsibilities.Provider

    @impl true
    def register, do: []

    @impl true
    # Names a space in a slot that is NOT the opt-in key. A Router that
    # keyed on any `:space_id`-ish context value would pick this up.
    def gather_context(_r, _meta), do: {:ok, %{space_id: "not-the-optin-key", some_slot: "body"}}

    @impl true
    def build_prompt(_ctx), do: {:ok, %{system: "SYS", user: "USR"}}

    @impl true
    def handle_output(_r, _o), do: :ok
  end

  setup do
    Application.put_env(:platform, @capture_key, self())

    Application.put_env(
      :platform,
      :responsibility_router_native_dispatcher,
      {CaptureDispatcher, :maybe_dispatch}
    )

    on_exit(fn ->
      Application.delete_env(:platform, @capture_key)
      Application.delete_env(:platform, :native_dispatch_space_value)
      Application.delete_env(:platform, :responsibility_router_native_dispatcher)
    end)

    :ok
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp put_provider_override(feature, module) do
    current = Application.get_env(:platform, :responsibility_provider_overrides, %{})

    Application.put_env(
      :platform,
      :responsibility_provider_overrides,
      Map.put(current, feature, module)
    )

    on_exit(fn ->
      remaining = Application.get_env(:platform, :responsibility_provider_overrides, %{})

      Application.put_env(
        :platform,
        :responsibility_provider_overrides,
        Map.delete(remaining, feature)
      )
    end)
  end

  defp row_with_provider(module) do
    feature = "dispatchspace_#{System.unique_integer([:positive])}"
    put_provider_override(feature, module)

    {:ok, row} =
      Responsibilities.create_responsibility(%{
        key: "#{feature}.fire",
        feature: feature,
        trigger_kind: "cron",
        trigger_config: %{"expression" => "*/5 * * * *"},
        scope: "global",
        cost_profile: "low_freq_capable"
      })

    row
  end

  defp wire_native_assignee(responsibility_key) do
    role_key = "historian"

    Repo.insert!(
      %Role{key: role_key, name: "Historian", description: "test", icon: "hero-star"},
      on_conflict: :nothing,
      conflict_target: :key
    )

    Repo.insert!(
      %Platform.Roles.RoleResponsibility{
        role_key: role_key,
        responsibility_key: responsibility_key
      },
      on_conflict: :nothing,
      conflict_target: [:role_key, :responsibility_key]
    )

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "dispatch-space-native-#{System.unique_integer([:positive])}",
        name: "Dispatch Space Assignee",
        status: "active",
        kind: "native",
        workspace_id: nil
      })
      |> Repo.insert!()

    {:ok, _} = Roles.assign_role(role_key, agent.id)
    agent
  end

  defp fire!(row, trigger_meta) do
    capture_log(fn -> Router.fire_trigger(row, trigger_meta, %{}) end)

    assert_receive {:captured_signal, signal}, 2_000
    signal
  end

  defp cron_meta, do: %{kind: :cron, fired_at: DateTime.utc_now()}

  # ── the opt-in ────────────────────────────────────────────────────────────

  describe "a provider that names :dispatch_space_id" do
    test "the space reaches metadata.space_id, and stays out of the top level" do
      space_id = Ecto.UUID.generate()
      Application.put_env(:platform, :native_dispatch_space_value, space_id)

      row = row_with_provider(SpaceNamingProvider)
      _agent = wire_native_assignee(row.key)

      signal = fire!(row, cron_meta())

      # THE FIX. Without it `AgentResponder.dispatch_space_id/1` reads nil
      # and the funnel takes the `:no_space_named` skip — no invite, and a
      # recipient told to write into a space it is not a member of.
      assert signal.metadata.space_id == space_id

      # The carrier is metadata and ONLY metadata. `build_native_signal/5`
      # lifts a top-level `:space_id` from `trigger_meta`, which a cron
      # fire has none of; a change that promoted the dispatch space to the
      # top level here would put it one `lift_correlation_ids/2` away from
      # the client slot that pins permission prompts.
      refute Map.has_key?(signal, :space_id)
    end

    test "a blank space id is dropped rather than carried as an empty string" do
      Application.put_env(:platform, :native_dispatch_space_value, "")

      row = row_with_provider(SpaceNamingProvider)
      _agent = wire_native_assignee(row.key)

      signal = fire!(row, cron_meta())

      # `""` would reach the funnel as `:invalid_space_id` — a resolution
      # failure reported as a malformed input, which is the reason
      # collapse DispatchMembership's eight refusal atoms exist to stop.
      refute Map.has_key?(signal.metadata, :space_id)
    end

    test "a non-binary space id is dropped" do
      Application.put_env(:platform, :native_dispatch_space_value, %{id: "nope"})

      row = row_with_provider(SpaceNamingProvider)
      _agent = wire_native_assignee(row.key)

      assert refute_key(fire!(row, cron_meta()))
    end
  end

  # ── the opt-out, which is most fires ──────────────────────────────────────

  describe "a fire whose provider names no dispatch space" do
    test "a cron fire carries NO metadata.space_id — absent, not nil" do
      row = row_with_provider(SpacelessProvider)
      _agent = wire_native_assignee(row.key)

      signal = fire!(row, cron_meta())

      # Absence is the assertion. `Map.get(metadata, :space_id) == nil`
      # would also pass on a key present with a nil value, which
      # `DeadLetters.record/1` would then persist and the funnel would
      # still skip — a difference nobody could see in a row dump.
      refute Map.has_key?(signal.metadata, :space_id)
    end

    test "a context slot that merely SPELLS space_id does not opt in" do
      row = row_with_provider(SpacelessProvider)
      _agent = wire_native_assignee(row.key)

      signal = fire!(row, cron_meta())

      # The provider above returns `space_id: "not-the-optin-key"`. This
      # is the mutation-proof for "why is the key not just `:space_id`":
      # every cron sweep and webhook fire whose gatherer touches a space
      # would otherwise start inviting its agent into it.
      refute Map.has_key?(signal.metadata, :space_id)
      refute signal.metadata[:space_id] == "not-the-optin-key"
    end

    test "a space in the TRIGGER payload does not opt in either" do
      row = row_with_provider(SpacelessProvider)
      _agent = wire_native_assignee(row.key)

      signal =
        fire!(row, %{
          kind: :event_topic,
          topic: "some:topic",
          payload: %{space_id: Ecto.UUID.generate()}
        })

      # The invite must come from the provider saying "this dispatch
      # writes here", never from a payload field that happens to be
      # named `space_id`.
      refute Map.has_key?(signal.metadata, :space_id)
    end
  end

  # ── the real path ─────────────────────────────────────────────────────────

  describe "a live meeting-intent fire" do
    test "meetings.action_items carries the meeting's chat space in metadata" do
      _registry =
        start_supervised!(
          {Registry,
           name: Module.concat([Registry, "DispatchSpace#{System.unique_integer([:positive])}"]),
           providers: BuiltIns.providers()}
        )

      [spec] = MeetingActionItems.register()
      {:ok, row} = Responsibilities.upsert_by_key(spec)
      _agent = wire_native_assignee(row.key)

      {:ok, project} =
        Platform.Tasks.create_project(%{
          name: "Intent Space #{System.unique_integer([:positive])}"
        })

      {:ok, meeting} =
        Meetings.create_meeting(%{project_id: project.id, name: "Standup"})

      signal =
        fire!(row, %{
          kind: :event_topic,
          topic: "meeting:action_item_intent",
          payload: %{
            intent_id: Platform.Types.UUIDv7.generate(),
            meeting_id: meeting.id,
            chunk_excerpt: "I'll revert onboarding by Friday",
            classified_intent: "action_items",
            confidence: 0.9,
            speaker: "Priya"
          }
        })

      # Resolved through `IntentContext.space_id/1`'s meeting fallback —
      # the payload names no space, so the meeting's own `chat_space_id`
      # is the answer. This is the production shape: `intent_payload/2`
      # stamps `space_id` off the TRANSCRIPT row, which mid-meeting may
      # not exist yet, and six such fires on 2026-08-01 produced zero
      # invites.
      assert signal.metadata.space_id == meeting.chat_space_id
      assert Chat.get_space(meeting.chat_space_id)

      refute Map.has_key?(signal, :space_id)
    end
  end

  defp refute_key(signal) do
    refute Map.has_key?(signal.metadata, :space_id)
    true
  end
end
