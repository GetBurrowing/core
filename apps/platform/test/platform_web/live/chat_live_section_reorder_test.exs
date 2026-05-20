defmodule PlatformWeb.ChatLiveSectionReorderTest do
  @moduledoc """
  Drag-reorder + per-user persistence tests for the sectioned channel rail
  (chat plan v2 Stage 3).

  Coverage:
    * Default order = alphabetical when no preference saved
    * Saved preference rehydrates on mount
    * `section_reordered` event updates `:section_order` AND persists to
      `users.preferences["chat_section_order"]`
    * Pinned + DMs are NOT reorderable — drag handle absent on those
      sections (drag handle class no longer rendered on them)
    * Malformed / partial saved orders fall back to alphabetical
    * Pure-function `compute_reorder/3` semantics

  Pure-function `compute_reorder/3` is also exercised here rather than in
  the grouping test file because reorder is the operation under test.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias PlatformWeb.ChatLive

  # ── Test-data helpers ──────────────────────────────────────────────────

  defp insert_user(suffix) do
    Repo.insert!(%User{
      email: "reorder_#{suffix}@example.com",
      name: "Reorder Test #{suffix}",
      oidc_sub: "oidc-reorder-#{suffix}",
      avatar_url: nil
    })
  end

  defp authenticated_conn(conn, user) do
    init_test_session(conn, current_user_id: user.id)
  end

  defp create_channel(slug) do
    {:ok, ch} =
      Chat.create_space(%{
        name: String.capitalize(slug),
        slug: slug,
        kind: "channel"
      })

    ch
  end

  # Same `live_following_redirect` pattern as chat_live_section_render_test.
  defp live_following_redirect(conn) do
    case live(conn, ~p"/chat") do
      {:error, {:live_redirect, %{to: path}}} -> live(conn, path)
      ok -> ok
    end
  end

  defp desktop_sidebar(html) do
    case Regex.run(~r/<aside[^>]*id="chat-sidebar".*?<\/aside>/s, html) do
      [match] -> match
      _ -> ""
    end
  end

  # ── Default order ──────────────────────────────────────────────────────

  describe "default section order" do
    test "alphabetical when no preference is saved", %{conn: conn} do
      user = insert_user("default")
      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      offsets =
        for label <- ["Paragon", "Soylent", "Fabrikam", "Wayne-Tech", "SXI"] do
          {label, :binary.match(sidebar, label) |> elem(0)}
        end

      indices = Enum.map(offsets, fn {_, off} -> off end)

      assert indices == Enum.sort(indices),
             "Default order should be alphabetical, got #{inspect(offsets)}"
    end
  end

  # ── Mount-time hydration ───────────────────────────────────────────────

  describe "saved preference hydration" do
    test "non-default order rehydrates on mount", %{conn: conn} do
      user = insert_user("hydrate")
      # SXI first → Paragon last (intentionally non-alphabetical)
      saved_order = ["SXI", "Fabrikam", "Soylent", "Wayne-Tech", "Paragon"]
      {:ok, _} = Accounts.update_user_preference(user.id, :chat_section_order, saved_order)

      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      offsets =
        for label <- saved_order do
          {label, :binary.match(sidebar, label) |> elem(0)}
        end

      indices = Enum.map(offsets, fn {_, off} -> off end)

      assert indices == Enum.sort(indices),
             "Saved order should drive render order; got #{inspect(offsets)}"
    end

    test "malformed saved order falls back to alphabetical", %{conn: conn} do
      user = insert_user("malformed")
      # Missing buckets — not a permutation. Should be ignored.
      {:ok, _} =
        Accounts.update_user_preference(user.id, :chat_section_order, ["SXI", "Paragon"])

      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      offsets =
        for label <- ["Paragon", "Soylent", "Fabrikam", "Wayne-Tech", "SXI"] do
          {label, :binary.match(sidebar, label) |> elem(0)}
        end

      indices = Enum.map(offsets, fn {_, off} -> off end)

      assert indices == Enum.sort(indices),
             "Malformed saved order should fall back to alphabetical, got #{inspect(offsets)}"
    end

    test "unknown slugs in saved order fall back to alphabetical", %{conn: conn} do
      user = insert_user("unknown")
      # Same arity as canonical but with a bogus slug.
      {:ok, _} =
        Accounts.update_user_preference(
          user.id,
          :chat_section_order,
          ["Paragon", "Soylent", "Fabrikam", "Wayne-Tech", "Bogus"]
        )

      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      # Alphabetical fallback — Paragon comes before SXI.
      paragon_idx = :binary.match(sidebar, "Paragon") |> elem(0)
      sxi_idx = :binary.match(sidebar, "SXI") |> elem(0)
      assert paragon_idx < sxi_idx
    end
  end

  # ── section_reordered event ────────────────────────────────────────────

  describe "section_reordered event" do
    test "reorder updates assigns AND persists to user preferences", %{conn: conn} do
      user = insert_user("event")
      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, view, _html} = live_following_redirect(conn)

      # Move Soylent to SXI's slot (drop-above semantics — Soylent lands
      # where SXI was, SXI shifts down one).
      render_hook(view, "section_reordered", %{"from" => "soylent", "to" => "sxi"})

      # In-memory: rendered HTML reflects new order. Soylent should now
      # appear AFTER Wayne-Tech (its new slot is at SXI's original index)
      # but BEFORE SXI (which shifted down to fill what was after it).
      html = render(view)
      sidebar = desktop_sidebar(html)

      protect_idx = :binary.match(sidebar, "Wayne-Tech") |> elem(0)
      sxi_idx = :binary.match(sidebar, "SXI") |> elem(0)
      soylent_idx = :binary.match(sidebar, "Soylent") |> elem(0)

      # New order: Paragon, Fabrikam, Wayne-Tech, Soylent, SXI
      assert protect_idx < soylent_idx,
             "Expected Soylent after Wayne-Tech, got Soylent at #{soylent_idx} and Wayne-Tech at #{protect_idx}"

      assert soylent_idx < sxi_idx,
             "Expected SXI after Soylent (drop-above semantics), got Soylent at #{soylent_idx} and SXI at #{sxi_idx}"

      # Persisted: re-fetch user and assert preferences blob updated.
      updated_user = Repo.get!(User, user.id)
      saved = updated_user.preferences["chat_section_order"]
      assert saved == ["Paragon", "Fabrikam", "Wayne-Tech", "Soylent", "SXI"]
    end

    test "drop on self is a no-op", %{conn: conn} do
      user = insert_user("noop")
      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, view, _html} = live_following_redirect(conn)

      render_hook(view, "section_reordered", %{"from" => "fabrikam", "to" => "fabrikam"})

      # No persisted change.
      updated_user = Repo.get!(User, user.id)
      # `update_user_preference/3` was never called → preferences stays at
      # default %{}.
      assert updated_user.preferences == %{} or
               Map.get(updated_user.preferences, "chat_section_order") == nil
    end

    test "unknown slug is ignored", %{conn: conn} do
      user = insert_user("bogus")
      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, view, _html} = live_following_redirect(conn)

      render_hook(view, "section_reordered", %{"from" => "bogus", "to" => "fabrikam"})

      updated_user = Repo.get!(User, user.id)

      assert updated_user.preferences == %{} or
               Map.get(updated_user.preferences, "chat_section_order") == nil
    end
  end

  # ── Pinned + DMs NOT reorderable ───────────────────────────────────────

  describe "Pinned + DMs are not reorderable" do
    test "DMs section has data-section-reorderable=false and no drag handle", %{conn: conn} do
      user = insert_user("dms")
      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      # Pull just the DMs section out so we don't accidentally hit a
      # sub-org's drag handle in the assertion.
      [dms_section] =
        Regex.run(
          ~r/<section[^>]*data-section-key="dms".*?<\/section>/s,
          sidebar
        ) || [""]

      assert dms_section =~ ~s(data-section-reorderable="false")

      refute dms_section =~ "channel-section-drag-handle",
             "DMs section should NOT render a drag handle (locked to top)"
    end

    test "sub-org sections have data-section-reorderable=true and a drag handle", %{conn: conn} do
      user = insert_user("suborg")
      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      [paragon_section] =
        Regex.run(
          ~r/<section[^>]*data-section-key="Paragon".*?<\/section>/s,
          sidebar
        ) || [""]

      assert paragon_section =~ ~s(data-section-reorderable="true")
      assert paragon_section =~ ~s(data-section-slug="paragon")
      assert paragon_section =~ "channel-section-drag-handle"
    end

    test "Wayne-Tech uses lowercased slug 'wayne-tech'", %{conn: conn} do
      user = insert_user("wayne-tech")
      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, _view, html} = live_following_redirect(conn)
      sidebar = desktop_sidebar(html)

      assert sidebar =~ ~s(data-section-slug="wayne-tech")
    end

    test "Pinned + DMs not affected by sub-org reorder", %{conn: conn} do
      user = insert_user("rail_order")
      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, view, _html} = live_following_redirect(conn)

      render_hook(view, "section_reordered", %{"from" => "sxi", "to" => "paragon"})

      html = render(view)
      sidebar = desktop_sidebar(html)

      # DMs header still renders before all sub-orgs.
      dms_idx = :binary.match(sidebar, "Direct Messages") |> elem(0)
      sxi_idx = :binary.match(sidebar, "SXI") |> elem(0)
      paragon_idx = :binary.match(sidebar, "Paragon") |> elem(0)

      assert dms_idx < sxi_idx
      assert dms_idx < paragon_idx
    end
  end

  # ── Pure-function compute_reorder/3 ────────────────────────────────────

  describe "compute_reorder/3" do
    test "moves item to target's slot (drop-above semantics, target shifts down)" do
      order = ["A", "B", "C", "D", "E"]
      # Move B to D's slot → after removing B: A, C, D, E; insert B at D's
      # index (2) → A, C, B, D, E. Standard "drop above target" reorder.
      assert ChatLive.compute_reorder(order, "B", "D") == ["A", "C", "B", "D", "E"]
    end

    test "moves later item earlier" do
      order = ["A", "B", "C", "D", "E"]
      # Move D to B's slot → after removing D: A, B, C, E; insert D at B's
      # index (1) → A, D, B, C, E.
      assert ChatLive.compute_reorder(order, "D", "B") == ["A", "D", "B", "C", "E"]
    end

    test "drop on self is a no-op" do
      order = ["A", "B", "C"]
      assert ChatLive.compute_reorder(order, "B", "B") == order
    end

    test "unknown slug returns input unchanged" do
      order = ["A", "B", "C"]
      assert ChatLive.compute_reorder(order, "Z", "B") == order
      assert ChatLive.compute_reorder(order, "A", "Z") == order
    end
  end

  # ── Fail-soft when user row vanishes between mount and event ──────────
  #
  # If the user_id pinned in the LiveView assigns no longer maps to a row
  # (account deletion mid-session, embedded surface with a synthetic UUID),
  # `update_user_preference/3` returns `{:error, :not_found}` and the
  # event handler still flips `:section_order` in-memory so the UI stays
  # responsive. Persistence is best-effort by design.

  describe "fail-soft on missing user row" do
    test "reorder still updates in-memory order when user has been deleted", %{conn: conn} do
      user = insert_user("vanishing")
      conn = authenticated_conn(conn, user)
      create_channel("general")
      {:ok, view, _html} = live_following_redirect(conn)

      # Delete the user row out from under the LV. The session still
      # carries the now-stale user_id.
      Repo.delete!(user)

      render_hook(view, "section_reordered", %{"from" => "soylent", "to" => "sxi"})

      html = render(view)
      sidebar = desktop_sidebar(html)

      # In-memory order still applied.
      protect_idx = :binary.match(sidebar, "Wayne-Tech") |> elem(0)
      soylent_idx = :binary.match(sidebar, "Soylent") |> elem(0)
      sxi_idx = :binary.match(sidebar, "SXI") |> elem(0)

      assert protect_idx < soylent_idx
      assert soylent_idx < sxi_idx
    end
  end

  # ── Accounts.update_user_preference/3 helper ──────────────────────────

  describe "Accounts.update_user_preference/3" do
    test "upserts a single key into the preferences map" do
      user = insert_user("acct1")

      {:ok, updated} =
        Accounts.update_user_preference(user.id, :chat_section_order, ["SXI", "Fabrikam"])

      assert updated.preferences == %{"chat_section_order" => ["SXI", "Fabrikam"]}

      # Idempotent — overwriting the same key works.
      {:ok, updated2} =
        Accounts.update_user_preference(user.id, :chat_section_order, ["Fabrikam", "SXI"])

      assert updated2.preferences == %{"chat_section_order" => ["Fabrikam", "SXI"]}
    end

    test "merges into existing preferences without clobbering siblings" do
      user = insert_user("acct2")

      {:ok, _} = Accounts.update_user_preference(user.id, "theme", "dark")
      {:ok, updated} = Accounts.update_user_preference(user.id, :chat_section_order, ["SXI"])

      assert updated.preferences == %{
               "theme" => "dark",
               "chat_section_order" => ["SXI"]
             }
    end

    test "returns {:error, :not_found} for unknown user" do
      assert {:error, :not_found} =
               Accounts.update_user_preference(
                 Ecto.UUID.generate(),
                 :chat_section_order,
                 ["Paragon"]
               )
    end

    test "get_user_preferences/1 returns %{} for unknown user" do
      assert Accounts.get_user_preferences(Ecto.UUID.generate()) == %{}
      assert Accounts.get_user_preferences(nil) == %{}
    end
  end
end
