defmodule PlatformWeb.ChatLive.PresenceHooksTest do
  @moduledoc """
  Regression coverage for the `:composite_status` cross-LV write.

  PR #302 (`task/019e0b0a`) wrapped `:composite_status` in
  `%Phoenix.LiveView.AsyncResult{}` at the `ShellLive` write sites and
  bound it to `<.async_result>` in the shell template. The cross-LV
  write in `PresenceHooks.apply_agent_typing/3` was missed, so any
  `{:agent_typing, ...}` event from an active agent assigned a bare
  atom (`:busy`, `:idle`, `:none`, ...) into the assign — which then
  crashed the LV render with `FunctionClauseError` on
  `Phoenix.Component.async_result/1`, disconnecting the user's WS.

  The fix lifted `ShellLive.async_ok/2` to public and routed the two
  `presence_hooks` writes through it. These tests pin the shape so the
  regression cannot return.
  """

  use ExUnit.Case, async: true

  alias Phoenix.LiveView.AsyncResult
  alias Phoenix.LiveView.Socket
  alias PlatformWeb.ChatLive.PresenceHooks
  alias PlatformWeb.ShellLive

  describe "apply_agent_typing/3 — :composite_status stays wrapped in AsyncResult" do
    test "typing: true assigns %AsyncResult{ok?: true, result: :busy} (not bare atom)" do
      socket =
        build_socket(%{
          composite_status: AsyncResult.ok(AsyncResult.loading(), :idle),
          principal_name: AsyncResult.ok(AsyncResult.loading(), "rowan@example.com"),
          active_space: nil,
          agent_typing_pids: MapSet.new()
        })

      {:halt, updated} = PresenceHooks.apply_agent_typing(socket, true, "agent-1")

      assert %AsyncResult{ok?: true, result: :busy} = updated.assigns.composite_status,
             "typing: true must yield wrapped :busy, not a bare atom — bare atoms crash <.async_result>"
    end

    test "typing: false with no active_space leaves :composite_status untouched (still wrapped)" do
      seed = AsyncResult.ok(AsyncResult.loading(), :busy)

      socket =
        build_socket(%{
          composite_status: seed,
          principal_name: AsyncResult.ok(AsyncResult.loading(), "rowan@example.com"),
          # nil active_space steers the typing:false branch into the no-op
          # case clause without touching SpaceAgentPresence (DB-free unit test).
          active_space: nil,
          agent_typing_pids: MapSet.new(["agent-1"])
        })

      {:halt, updated} = PresenceHooks.apply_agent_typing(socket, false, "agent-1")

      assert updated.assigns.composite_status == seed,
             "typing:false with no active_space should leave :composite_status as-is"

      assert %AsyncResult{} = updated.assigns.composite_status,
             "shape must remain %AsyncResult{} — bare atoms here would crash render"
    end

    test "typing toggle on/off/on preserves AsyncResult shape across writes" do
      socket =
        build_socket(%{
          composite_status: AsyncResult.ok(AsyncResult.loading(), :idle),
          principal_name: AsyncResult.ok(AsyncResult.loading(), "rowan@example.com"),
          active_space: nil,
          agent_typing_pids: MapSet.new()
        })

      {:halt, s1} = PresenceHooks.apply_agent_typing(socket, true, "agent-a")
      assert %AsyncResult{ok?: true, result: :busy} = s1.assigns.composite_status

      {:halt, s2} = PresenceHooks.apply_agent_typing(s1, false, "agent-a")
      # No active_space, so :busy carries forward — still wrapped.
      assert %AsyncResult{} = s2.assigns.composite_status

      {:halt, s3} = PresenceHooks.apply_agent_typing(s2, true, "agent-b")
      assert %AsyncResult{ok?: true, result: :busy} = s3.assigns.composite_status
    end

    test "missing principal_name skips the cross-LV write (template not yet bound)" do
      socket =
        build_socket(%{
          composite_status: AsyncResult.loading(),
          principal_name: nil,
          active_space: nil,
          agent_typing_pids: MapSet.new()
        })

      {:halt, updated} = PresenceHooks.apply_agent_typing(socket, true, "agent-1")

      # Untouched — still the seeded loading struct.
      assert %AsyncResult{loading: true} = updated.assigns.composite_status
    end
  end

  describe "ShellLive.async_ok/2 — wrap-or-rewrap helper used by cross-LV writers" do
    test "rewraps existing AsyncResult, preserving struct identity for LV diffing" do
      existing = AsyncResult.ok(AsyncResult.loading(), :idle)
      rewrapped = ShellLive.async_ok(existing, :busy)

      assert %AsyncResult{ok?: true, result: :busy} = rewrapped
    end

    test "lazily wraps a bare value when assign hasn't been seeded" do
      wrapped = ShellLive.async_ok(nil, :none)

      assert %AsyncResult{ok?: true, result: :none} = wrapped
    end

    test "tolerates any non-AsyncResult input (defensive against bare atoms in flight)" do
      wrapped = ShellLive.async_ok(:idle, :busy)

      assert %AsyncResult{ok?: true, result: :busy} = wrapped
    end
  end

  # Build a minimal LV socket with the assigns the function under test reads.
  # The `__changed__` map is what `Phoenix.Component.assign/3` and
  # `Phoenix.Component.update/3` use to track which assigns have been touched.
  defp build_socket(assigns) do
    %Socket{assigns: Map.put(assigns, :__changed__, %{})}
  end
end
