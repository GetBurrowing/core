defmodule PlatformWeb.TasksFilterPrefsTest do
  @moduledoc """
  Task 01a161fd stage 2: the /tasks project and epic are remembered per USER
  in `users.preferences["tasks_project"]` (`PlatformWeb.Tasks.FilterPrefs`).

  The render proxy is the old breadcrumb, `[data-role=tasks-breadcrumb]`,
  which renders inside `#tasks-main` at every width and only while a project
  is selected. The html `live/2` returns is the first CONNECTED render.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.{Repo, Tasks}

  defp u, do: System.unique_integer([:positive])

  defp user!(tag) do
    n = u()

    Repo.insert!(%User{
      email: "filter_prefs_#{tag}_#{n}@example.com",
      name: "Filter Prefs #{tag} #{n}",
      oidc_sub: "oidc-filter-prefs-#{tag}-#{n}"
    })
    |> Platform.TenancyFixtures.member_of_all_orgs!()
  end

  defp project!(name, attrs \\ %{}) do
    {:ok, project} = Tasks.create_project(Map.merge(%{name: "#{name} #{u()}"}, attrs))
    project
  end

  defp conn_for(user), do: build_conn() |> init_test_session(current_user_id: user.id)

  defp stored(user), do: Accounts.get_user_preferences(user.id)["tasks_project"]

  defp breadcrumb(html) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query("[data-role=tasks-breadcrumb]")
  end

  defp breadcrumb_text(html), do: html |> breadcrumb() |> LazyHTML.text()

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Pin the stored row's `updated_at` in the past, so ANY later write moves it.
  defp backdate!(user) do
    {1, _} =
      Repo.update_all(from(x in User, where: x.id == ^user.id),
        set: [updated_at: ~N[2000-01-01 00:00:00]]
      )

    ~N[2000-01-01 00:00:00]
  end

  defp updated_at(user), do: Repo.get!(User, user.id).updated_at

  setup do
    a = user!("a")
    b = user!("b")
    p = project!("Prefs Proj")
    q = project!("Prefs Other")
    %{a: a, b: b, p: p, q: q}
  end

  test "a project opened by URL opens on a fresh bare mount for the same user, not for another",
       %{a: a, b: b, p: p} do
    assert stored(a) == nil, "precondition: nothing stored"

    {:ok, view, html} = live(conn_for(a), "/tasks?project=#{p.id}")
    _ = render(view)
    assert breadcrumb_text(html) =~ p.name
    assert stored(a) == %{"project_id" => p.id, "epic_id" => nil}

    # A fresh LiveView, as if on another device: the first connected render
    # already shows P (no flash of All projects), from the server pref alone.
    {:ok, view, html} = live(conn_for(a), "/tasks")
    assert breadcrumb_text(html) =~ p.name
    assert assigns(view).selected_project_id == p.id

    {:ok, view, html} = live(conn_for(b), "/tasks")
    assert breadcrumb(html) |> Enum.to_list() == []
    assert assigns(view).selected_project_id == nil
    assert stored(b) == nil
  end

  test "an epic round-trips, and restoring it writes nothing", %{a: a, p: p} do
    {:ok, epic} = Tasks.create_epic(%{project_id: p.id, name: "Prefs Epic #{u()}"})

    {:ok, view, _html} = live(conn_for(a), "/tasks?project=#{p.id}&epic=#{epic.id}")
    _ = render(view)
    assert stored(a) == %{"project_id" => p.id, "epic_id" => epic.id}

    pinned = backdate!(a)

    {:ok, view, html} = live(conn_for(a), "/tasks")
    _ = render(view)
    assert breadcrumb_text(html) =~ p.name
    assert breadcrumb_text(render(view)) =~ epic.name
    assert assigns(view).selected_epic_id == epic.id

    # The URL path resets the epic before setting it again; that transient
    # {P, nil} must never reach the row.
    assert updated_at(a) == pinned
    assert stored(a) == %{"project_id" => p.id, "epic_id" => epic.id}
  end

  test "project=all overrides the stored project and stores All", %{a: a, p: p} do
    {:ok, _} = Accounts.put_tasks_project_pref(a.id, p.id, nil)

    {:ok, view, html} = live(conn_for(a), "/tasks?project=all")
    _ = render(view)
    assert breadcrumb(html) |> Enum.to_list() == []
    assert assigns(view).selected_project_id == nil
    assert stored(a) == %{"project_id" => nil, "epic_id" => nil}

    {:ok, _view, html} = live(conn_for(a), "/tasks")
    assert breadcrumb(html) |> Enum.to_list() == []
  end

  test "a stored project that is now archived falls back to All, and the stored value heals",
       %{a: a, p: p, q: q} do
    {:ok, _} = Accounts.put_tasks_project_pref(a.id, p.id, nil)
    {:ok, _} = Tasks.update_project(p, %{archived_at: DateTime.utc_now()})

    {:ok, view, html} = live(conn_for(a), "/tasks")
    _ = render(view)
    assert breadcrumb(html) |> Enum.to_list() == []
    assert assigns(view).selected_project_id == nil
    assert stored(a) == %{"project_id" => nil, "epic_id" => nil}

    # Positive control: an active stored project IS restored.
    {:ok, _} = Accounts.put_tasks_project_pref(a.id, q.id, nil)
    {:ok, _view, html} = live(conn_for(a), "/tasks")
    assert breadcrumb_text(html) =~ q.name
  end

  test "an archived project in the URL is never stored, even for a moment", %{a: a, p: p, q: q} do
    {:ok, _} = Accounts.put_tasks_project_pref(a.id, q.id, nil)
    {:ok, _} = Tasks.update_project(p, %{archived_at: DateTime.utc_now()})
    test_pid = self()
    handler = "filter-prefs-#{u()}"

    :telemetry.attach(
      handler,
      [:platform, :repo, :query],
      fn _event, _measurements, %{query: sql, params: params}, _ ->
        if sql =~ ~s(UPDATE "users"), do: send(test_pid, {:users_update, params})
      end,
      nil
    )

    try do
      {:ok, view, _html} = live(conn_for(a), "/tasks?project=#{p.id}")
      _ = render(view)
      assert assigns(view).selected_project_id == nil
    after
      :telemetry.detach(handler)
    end

    assert stored(a) == %{"project_id" => nil, "epic_id" => nil}

    writes = collect_updates([])
    assert writes != [], "positive control: the fallback was written"

    for params <- writes do
      refute inspect(params) =~ p.id, "the unresolved archived id was written: #{inspect(params)}"
    end
  end

  defp collect_updates(acc) do
    receive do
      {:users_update, params} -> collect_updates([params | acc])
    after
      0 -> acc
    end
  end

  test "the old sidebar's sidebar_select_project stores the preference", %{a: a, p: p} do
    {:ok, view, _html} = live(conn_for(a), "/tasks")
    assert stored(a) == nil

    _ =
      render_hook(with_target(view, "#tasks-sidebar"), "sidebar_select_project", %{"id" => p.id})

    _ = render(view)
    assert stored(a) == %{"project_id" => p.id, "epic_id" => nil}

    _ = render_click(with_target(view, "#tasks-filters"), "filter_clear")
    _ = render(view)
    assert stored(a) == %{"project_id" => nil, "epic_id" => nil}
  end

  test "a PubSub-only refresh writes nothing", %{a: a, p: p, q: q} do
    {:ok, view, _html} = live(conn_for(a), "/tasks?project=#{p.id}")
    _ = render(view)
    assert stored(a) == %{"project_id" => p.id, "epic_id" => nil}

    # Behind the LiveView's back, store a sentinel and backdate the row. A
    # refresh that wrote (even the same selection) would overwrite both.
    {:ok, _} = Accounts.put_tasks_project_pref(a.id, q.id, nil)
    pinned = backdate!(a)

    send(view.pid, {:task_created, nil})
    send(view.pid, {:epic_updated, nil})
    _ = render(view)

    assert assigns(view).selected_project_id == p.id, "positive control: still on P"
    assert stored(a) == %{"project_id" => q.id, "epic_id" => nil}
    assert updated_at(a) == pinned
  end

  # A root-org member reads every project, so the viewer here is a member of
  # ONE tenant org only, and the stored project lives in another.
  test "an unreadable project id in preferences is never rendered" do
    home_org = Platform.TenancyFixtures.tenant_org_id("prefs_home_#{u()}")
    foreign_org = Platform.TenancyFixtures.tenant_org_id("prefs_foreign_#{u()}")
    n = u()

    viewer =
      Repo.insert!(%User{
        email: "filter_prefs_tenant_#{n}@example.com",
        name: "Filter Prefs tenant #{n}",
        oidc_sub: "oidc-filter-prefs-tenant-#{n}"
      })

    %Platform.Tenancy.OrgMembership{}
    |> Platform.Tenancy.OrgMembership.changeset(%{
      user_id: viewer.id,
      org_id: home_org,
      role: "member"
    })
    |> Repo.insert!()

    home = project!("Prefs Home", %{org_id: home_org})
    foreign = project!("Prefs Foreign", %{org_id: foreign_org})

    {:ok, _} = Accounts.put_tasks_project_pref(viewer.id, foreign.id, nil)

    {:ok, view, html} = live(conn_for(viewer), "/tasks")
    rendered = render(view)

    for page <- [html, rendered] do
      tree = LazyHTML.from_fragment(page)
      assert tree |> LazyHTML.query("#tasks-main") |> Enum.count() == 1, "positive control"
      refute LazyHTML.text(tree) =~ foreign.name
    end

    assert assigns(view).selected_project_id == nil
    assert stored(viewer) == %{"project_id" => nil, "epic_id" => nil}

    # Positive control: the same whole-tree read DOES show a readable stored
    # project's name, in the breadcrumb.
    {:ok, _} = Accounts.put_tasks_project_pref(viewer.id, home.id, nil)
    {:ok, _view, html} = live(conn_for(viewer), "/tasks")
    assert html |> LazyHTML.from_fragment() |> LazyHTML.text() =~ home.name
    assert breadcrumb_text(html) =~ home.name
  end

  # Stage 5: a bare /tasks entry is rewritten IN PLACE to the selection it
  # shows, so Back to it shows that selection again rather than whatever is
  # remembered by then.
  #
  # A push_patch during the connected mount rides the JOIN reply
  # (`live_patch`), which `Phoenix.LiveViewTest` does not surface to
  # `assert_patch/2`. The channel runs `handle_params/3` again with the
  # patched URL in the same mount, so the URLs `handle_params` saw are the
  # observable: read off LiveView's own `[:phoenix, :live_view,
  # :handle_params, :start]` telemetry, for the view's pid only.
  describe "a bare URL is pinned to its selection" do
    defp handle_params_uris(fun) do
      test_pid = self()
      handler = "filter-prefs-pin-#{u()}"

      :telemetry.attach(
        handler,
        [:phoenix, :live_view, :handle_params, :start],
        fn _event, _measurements, %{uri: uri}, _ -> send(test_pid, {:hp, self(), uri}) end,
        nil
      )

      try do
        {:ok, view, _html} = fun.()
        _ = render(view)
        {view, collect_uris(view.pid, [])}
      after
        :telemetry.detach(handler)
      end
    end

    defp collect_uris(pid, acc) do
      receive do
        {:hp, ^pid, uri} -> collect_uris(pid, [URI.parse(uri) |> path_and_query() | acc])
        {:hp, _other, _uri} -> collect_uris(pid, acc)
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp path_and_query(%URI{path: path, query: nil}), do: path
    defp path_and_query(%URI{path: path, query: query}), do: path <> "?" <> query

    test "a stored project and epic replace the bare entry, keeping the other filters",
         %{a: a, p: p} do
      {:ok, epic} = Tasks.create_epic(%{project_id: p.id, name: "Pin Epic #{u()}"})
      {:ok, _} = Accounts.put_tasks_project_pref(a.id, p.id, epic.id)

      {view, uris} =
        handle_params_uris(fn -> live(conn_for(a), "/tasks?sort=oldest&status=in_progress") end)

      assert uris == [
               "/tasks?sort=oldest&status=in_progress",
               "/tasks?sort=oldest&project=#{p.id}&epic=#{epic.id}&status=in_progress"
             ]

      assert assigns(view).selected_project_id == p.id
      assert assigns(view).selected_epic_id == epic.id
    end

    test "nothing stored pins project=all", %{b: b} do
      {view, uris} = handle_params_uris(fn -> live(conn_for(b), "/tasks") end)
      assert uris == ["/tasks", "/tasks?project=all"]
      assert assigns(view).selected_project_id == nil
      assert stored(b) == nil, "pinning All writes nothing"
    end

    test "an unreadable stored project pins All, not the stale id", %{a: a, p: p} do
      {:ok, _} = Accounts.put_tasks_project_pref(a.id, p.id, nil)
      {:ok, _} = Tasks.update_project(p, %{archived_at: DateTime.utc_now()})

      {_view, uris} = handle_params_uris(fn -> live(conn_for(a), "/tasks") end)
      assert uris == ["/tasks", "/tasks?project=all"]
    end

    test "a URL that names a project is never rewritten", %{a: a, p: p, q: q} do
      {:ok, _} = Accounts.put_tasks_project_pref(a.id, q.id, nil)

      {view, uris} =
        handle_params_uris(fn -> live(conn_for(a), "/tasks?project=#{p.id}") end)

      assert uris == ["/tasks?project=#{p.id}"]
      assert assigns(view).selected_project_id == p.id
    end

    test "the pin REPLACES the current entry rather than pushing one, and only once", %{p: p} do
      socket = %Phoenix.LiveView.Socket{
        transport_pid: self(),
        assigns: %{
          __changed__: %{},
          tasks_pin_url: true,
          selected_project_id: p.id,
          board_sort: :oldest
        }
      }

      pinned = PlatformWeb.Tasks.FilterPrefs.pin_url(socket)

      assert pinned.redirected ==
               {:live, :patch, %{to: "/tasks?sort=oldest&project=#{p.id}", kind: :replace}}

      again = PlatformWeb.Tasks.FilterPrefs.pin_url(%{pinned | redirected: nil})
      assert again.redirected == nil
    end

    test "a later bare patch is a user step: it pushes and is not rewritten", %{a: a, p: p} do
      {:ok, _} = Accounts.put_tasks_project_pref(a.id, p.id, nil)

      {view, uris} =
        handle_params_uris(fn ->
          {:ok, view, html} = live(conn_for(a), "/tasks")
          _ = render_patch(view, "/tasks?sort=oldest")
          {:ok, view, html}
        end)

      assert uris == ["/tasks", "/tasks?project=#{p.id}", "/tasks?sort=oldest"]
      assert assigns(view).selected_project_id == p.id
    end
  end
end
