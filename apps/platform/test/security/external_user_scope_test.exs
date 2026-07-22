defmodule Platform.Security.ExternalUserScopeTest do
  @moduledoc """
  M15 security suite — Stage 1 (S1): the HTTP-entry gate (M6).

  Drives REAL routes through the router so the `:enforce_external_scope`
  pipeline → `PlatformWeb.Plugs.ExternalUserScope` actually runs. Proves the
  allowlist gate an EXTERNAL user hits at the front door:

    * every non-chat route, every out-of-scope space, and a nonexistent space
      all return a uniform HTTP 403 — and the nonexistent-slug 403 is
      BYTE-INDISTINGUISHABLE from the out-of-scope-space 403 (no existence
      oracle, canvas §9);
    * `/`, `/chat`, and a scoped `/chat/<A.slug>` are NOT 403;
    * a `[:platform, :auth, :access_blocked]` event fires with the right reason
      for each denial;
    * the plug is a strict NO-OP for internal users (INT reaches `/tasks` and
      `/chat/<A.slug>`, and NO access_blocked telemetry fires for INT).

  Binds to M6 shipped: pipeline `:enforce_external_scope`, the plug, the
  `Chat.participant?/2`-backed space-scope gate, and `ErrorHTML`/`ErrorJSON`
  `:"403"`.
  """
  use PlatformWeb.ConnCase, async: false

  alias Platform.ExternalUserFixtures, as: World

  setup do
    # init_test_session stores the session on the conn (not a cookie), so it is
    # cleared on the automatic recycle between requests — build + log in a fresh
    # conn per request instead of reusing one across multiple GETs.
    Map.put(World.external_world(), :__world__, true)
  end

  defp req(user_id, path) do
    Phoenix.ConnTest.build_conn()
    |> World.login(user_id)
    |> get(path)
  end

  # ── EXTERNAL user: denials ─────────────────────────────────────────────

  describe "external user is denied everything off the chat surface" do
    test "403 on each non-chat route", %{ext: ext} do
      for path <- ["/tasks", "/admin", "/org_memory"] do
        assert req(ext.id, path).status == 403, "expected 403 for external user on #{path}"
      end
    end

    test "403 on an out-of-scope existing space B", %{ext: ext, b: b} do
      assert req(ext.id, "/chat/#{b.slug}").status == 403
    end

    test "403 on a nonexistent space", %{ext: ext} do
      assert req(ext.id, "/chat/does-not-exist-zzz").status == 403
    end

    test "nonexistent-slug 403 is BYTE-INDISTINGUISHABLE from the out-of-scope-B 403 (no existence oracle)",
         %{ext: ext, b: b} do
      out_of_scope = req(ext.id, "/chat/#{b.slug}")
      missing = req(ext.id, "/chat/does-not-exist-zzz")

      assert out_of_scope.status == 403
      assert missing.status == 403
      # The rendered body must be identical — an off-limits slug is
      # indistinguishable from a missing one. Normalize the per-request CSRF
      # nonce (random on EVERY request regardless of the resource, so not an
      # existence oracle) before the byte comparison.
      assert strip_csrf(response(missing, 403)) == strip_csrf(response(out_of_scope, 403))
    end
  end

  defp strip_csrf(body) do
    Regex.replace(~r/name="csrf-token" content="[^"]*"/, body, ~s(name="csrf-token"))
  end

  # ── EXTERNAL user: allowed chat surface ────────────────────────────────

  describe "external user reaches the chat surface" do
    test "root and chat index are NOT 403", %{ext: ext} do
      refute req(ext.id, "/").status == 403
      refute req(ext.id, "/chat").status == 403
    end

    test "the scoped space A is NOT 403 (200 / live dead-render)", %{ext: ext, a: a} do
      assert req(ext.id, "/chat/#{a.slug}").status == 200
    end
  end

  # ── Telemetry: access_blocked with per-denial reasons ──────────────────

  describe "access_blocked telemetry" do
    setup do
      ref = attach_telemetry()
      on_exit(fn -> detach_telemetry(ref) end)
      %{ref: ref}
    end

    test "fires reason external_non_chat_route for /tasks", %{ext: ext} do
      req(ext.id, "/tasks")
      assert_receive {:access_blocked, meta}
      assert meta.reason == "external_non_chat_route"
      assert meta.actor_id == ext.id
      assert meta.resource_type == "route"
    end

    test "fires reason external_out_of_scope for the out-of-scope space B", %{ext: ext, b: b} do
      req(ext.id, "/chat/#{b.slug}")
      assert_receive {:access_blocked, meta}
      assert meta.reason == "external_out_of_scope"
      assert meta.actor_id == ext.id
    end
  end

  # ── INTERNAL user: strict no-op (regression) ───────────────────────────

  describe "internal user is unaffected — the plug is a strict no-op" do
    test "200 on /tasks", %{int: int} do
      assert req(int.id, "/tasks").status == 200
    end

    test "200 on the scoped space A", %{int: int, a: a} do
      assert req(int.id, "/chat/#{a.slug}").status == 200
    end

    test "NO access_blocked telemetry fires for an internal user", %{int: int} do
      ref = attach_telemetry()
      req(int.id, "/tasks")
      refute_receive {:access_blocked, _}, 50
      detach_telemetry(ref)
    end
  end

  # ── Telemetry plumbing ─────────────────────────────────────────────────

  defp attach_telemetry do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "m15-s1-#{inspect(ref)}",
      [:platform, :auth, :access_blocked],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:access_blocked, metadata})
      end,
      nil
    )

    ref
  end

  defp detach_telemetry(ref), do: :telemetry.detach("m15-s1-#{inspect(ref)}")
end
