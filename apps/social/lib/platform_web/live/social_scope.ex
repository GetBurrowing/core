defmodule PlatformWeb.SocialScope do
  @moduledoc """
  Which brand(s) the Social page is showing (Social authoring 1/11).

  The `:scope` assign is `{:profile, profile}` (one brand; `@profile` is that
  profile) or `:all` (All brands). `@profile` keeps the last single brand
  while the scope is `:all`, so per-brand panes (Connections, Settings,
  Clips) never read a cross-brand state: the shell hides them behind
  "Pick a brand" instead.

  Every profile list comes from a FRESH `Platform.Social.list_profiles_for_user/1`
  (`visible_profiles/1`); an id from the client only ever SELECTS among it.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Platform.Social
  alias PlatformWeb.{SocialHelpers, SocialTabs, SocialTopBar}

  @doc "The profiles the viewer may see, re-read now."
  def visible_profiles(%{assigns: %{user: %{id: id}}}) do
    case Platform.Accounts.get_user(id) do
      nil -> []
      user -> Social.list_profiles_for_user(user)
    end
  end

  def visible_profiles(_socket), do: []

  @doc "The switcher's profiles, their needs-approval counts, and the top bar's status."
  def assign_profiles(socket, profiles) do
    socket
    |> assign(:profiles, profiles)
    |> assign(:counts, Social.needs_approval_counts(Enum.map(profiles, & &1.id)))
    |> SocialTopBar.assign_status()
  end

  def count(counts, %{id: id}), do: Map.get(counts, id, 0)
  def count(_counts, _), do: 0

  @doc "Needs-approval posts across every visible profile."
  def waiting_total(counts), do: counts |> Map.values() |> Enum.sum()

  @doc """
  ONE place a profile becomes current. Every tab's `load/1` runs here, so
  every per-profile stream is re-streamed with `reset: true` and a switch
  leaves nothing of the previous profile. `can_edit?` is ONLY for
  rendering; every write handler re-checks through `authorize/1`.
  """
  def load_profile(socket, profile) do
    socket =
      socket
      |> assign(:profile, profile)
      |> assign(:scope, {:profile, profile})
      |> assign(:detail, nil)
      |> assign(:notice, nil)
      |> assign_tabs(profile != nil and profile.studio_enabled == true)

    socket
    |> assign(:can_edit?, profile != nil and match?({:ok, _, _}, SocialHelpers.authorize(socket)))
    |> then(&SocialTabs.reduce(&1.assigns.tabs, &1, fn mod, acc -> mod.load(acc) end))
  end

  @doc """
  Enters All brands: only tabs whose module says `all_brands?/0` reload;
  the others keep their last brand's state, hidden behind "Pick a brand".
  """
  def select_all(socket) do
    studio_enabled? = Enum.any?(visible_profiles(socket), &(&1.studio_enabled == true))

    socket
    |> assign(:scope, :all)
    |> assign(:detail, nil)
    |> assign(:notice, nil)
    |> assign_tabs(studio_enabled?)
    |> then(fn socket ->
      tabs = Enum.filter(socket.assigns.tabs, & &1.module.all_brands?())
      SocialTabs.reduce(tabs, socket, fn mod, acc -> mod.load(acc) end)
    end)
  end

  @doc "Re-evaluate the Studio tab from freshly visible profiles without switching scope."
  def refresh_studio_tabs(socket, profiles) do
    enabled? =
      case socket.assigns.scope do
        :all -> Enum.any?(profiles, &(&1.studio_enabled == true))
        {:profile, %{id: id}} -> Enum.any?(profiles, &(&1.id == id and &1.studio_enabled == true))
        _ -> false
      end

    assign_tabs(socket, enabled?)
  end

  defp assign_tabs(socket, studio_enabled?) do
    legacy_tabs = SocialTabs.tabs()

    tabs =
      if studio_enabled? do
        [%{key: "today", label: "Today", module: PlatformWeb.SocialTodayTab} | legacy_tabs]
      else
        legacy_tabs
      end

    socket =
      if studio_enabled? do
        socket
      else
        socket
        |> assign(:studio_today_posts, [])
        |> assign(:studio_today_clips, [])
        |> assign(:studio_results, [])
        |> assign(:studio_goals, [])
        |> assign(:studio_pitches, [])
        |> assign(:studio_profile_accessible?, false)
        |> assign(:studio_loaded_profile_ids, MapSet.new())
        |> assign(:studio_post_detail, nil)
      end

    socket
    |> assign(:tabs, tabs)
    |> then(fn socket ->
      if socket.assigns.tab == "today" and not studio_enabled?,
        do: assign(socket, :tab, "queue"),
        else: socket
    end)
  end

  def all?(%{assigns: %{scope: :all}}), do: true
  def all?(_socket), do: false

  @doc "Makes `key` the current tab (an enabled key only) and runs its `on_select/1`."
  def select_tab(socket, key) do
    case SocialTabs.get(socket.assigns.tabs, key) do
      nil -> socket
      tab -> socket |> assign(:tab, key) |> tab.module.on_select()
    end
  end
end
