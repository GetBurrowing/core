defmodule PlatformWeb.SocialTabs do
  @moduledoc """
  The Social tab registry (Social authoring 1/11). `PlatformWeb.SocialLive`
  reads its tab strip, its panes, its event routing and its per-profile
  loads from `tabs/0` and nothing else.

  A tab is listed only while its module's `enabled?/0` is true. Tabs a later
  ticket owns ship here already, switched off, so turning one on is a
  one-line change in that tab's own file (`def enabled?, do: true`):

    * Ideas - `PlatformWeb.SocialIdeasTab` (authoring 7/11)
    * Results - `PlatformWeb.SocialResultsTab` (authoring 10/11)
    * the header "New idea" button - `PlatformWeb.SocialComposer` (6/11)

  The order below is the strip's order. See `PlatformWeb.SocialTab` for the
  callbacks a tab module implements.
  """

  @registry [
    %{key: "queue", label: "Queue", module: PlatformWeb.SocialQueueTab},
    %{key: "ideas", label: "Ideas", module: PlatformWeb.SocialIdeasTab},
    %{key: "calendar", label: "Calendar", module: PlatformWeb.SocialCalendarTab},
    %{key: "clips", label: "Clips", module: PlatformWeb.SocialClipsTab},
    %{key: "results", label: "Results", module: PlatformWeb.SocialResultsTab},
    %{key: "connections", label: "Connections", module: PlatformWeb.SocialConnectionsTab},
    %{key: "settings", label: "Settings", module: PlatformWeb.SocialSettingsTab}
  ]

  @type tab :: %{key: String.t(), label: String.t(), module: module()}

  @doc "Every registered tab, enabled or not, in strip order."
  @spec registry() :: [tab()]
  def registry, do: @registry

  @doc "The enabled tabs, in strip order: `[%{key, label, module}]`."
  @spec tabs() :: [tab()]
  def tabs, do: tabs(@registry)

  @doc "The entries of `registry` whose module's `enabled?/0` is true."
  @spec tabs([tab()]) :: [tab()]
  def tabs(registry), do: Enum.filter(registry, & &1.module.enabled?())

  @doc "The enabled tab with `key`, or nil (a disabled or unknown key)."
  @spec get([tab()], term()) :: tab() | nil
  def get(tabs, key), do: Enum.find(tabs, &(&1.key == key))

  @doc "Whether the enabled tab `key` renders for the All brands scope."
  @spec all_brands?([tab()], term()) :: boolean()
  def all_brands?(tabs, key) do
    case get(tabs, key) do
      nil -> false
      tab -> tab.module.all_brands?()
    end
  end

  @doc "The enabled tab module that owns phx event `event`, or nil."
  @spec event_owner([tab()], String.t()) :: module() | nil
  def event_owner(tabs, event) do
    Enum.find_value(tabs, fn tab -> if event in tab.module.events(), do: tab.module end)
  end

  @doc "Runs `fun.(module, socket)` over every tab in `tabs`, in order."
  @spec reduce([tab()], Phoenix.LiveView.Socket.t(), (module(), term() -> term())) :: term()
  def reduce(tabs, socket, fun),
    do: Enum.reduce(tabs, socket, fn tab, acc -> fun.(tab.module, acc) end)

  @doc """
  Offers `message` to each enabled tab's `handle_info/2`; the first answer
  other than `:unhandled` wins. Nobody claims it: `{:noreply, socket}`.
  """
  @spec handle_info([tab()], term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info(tabs, message, socket) do
    Enum.find_value(tabs, {:noreply, socket}, fn tab ->
      case tab.module.handle_info(message, socket) do
        :unhandled -> nil
        reply -> reply
      end
    end)
  end
end
