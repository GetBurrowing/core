defmodule PlatformWeb.SocialTab do
  @moduledoc """
  The contract every Social tab module implements (Social authoring 1/11).
  `PlatformWeb.SocialTabs` lists the modules; `PlatformWeb.SocialLive` only
  walks that list, so a tab is added, changed or switched on in ITS OWN
  file and `social_live.ex` is never edited for it.

  `use PlatformWeb.SocialTab` brings the HTML helpers, the LiveView socket
  functions a pane needs, `PlatformWeb.SocialHelpers`, and a default for
  every callback except `enabled?/0` and `pane/1`:

    * `enabled?/0` - false keeps the tab out of `SocialTabs.tabs/0`: no
      button, no `data-tab`, no pane, no events routed to it.
    * `pane/1` - the pane body, given the LiveView's assigns. Every enabled
      pane stays in the DOM (hidden when inactive) so its streams survive a
      tab change.
    * `all_brands?/0` (default false) - whether the pane can render for the
      "All brands" scope. When false and the scope is `:all`, the shell shows
      "Pick a brand to see <Tab>" instead, so no pane renders half-scoped.
    * `init/1` - mount-time assigns (before the first profile loads).
    * `load/1` - (re)load for the current `:scope`. Called by
      `PlatformWeb.SocialScope.load_profile/2` on every profile switch, and
      on entering All brands for tabs with `all_brands?/0` true.
    * `on_select/1` - runs after the tab becomes the current tab.
    * `from_query/2` - reads this tab's own URL params (untrusted strings).
    * `events/0` + `handle_event/3` - the phx events this tab owns.
    * `handle_info/2` - return `:unhandled` for messages it does not own.
    * `tab_label/1` - the tab button's text (default: the registry label).
    * `tab_badge/1` - extra markup inside the tab button.
    * `overlay/1` - markup rendered outside the panes (a modal that must not
      sit inside a hidden pane).
  """

  import Phoenix.Component, only: [sigil_H: 2]

  alias Phoenix.LiveView.Socket

  @doc false
  # The default `tab_badge/1` and `overlay/1`: renders nothing.
  def nothing(assigns), do: ~H""

  @callback enabled?() :: boolean()
  @callback pane(map()) :: Phoenix.LiveView.Rendered.t()
  @callback all_brands?() :: boolean()
  @callback init(Socket.t()) :: Socket.t()
  @callback load(Socket.t()) :: Socket.t()
  @callback on_select(Socket.t()) :: Socket.t()
  @callback from_query(Socket.t(), map()) :: Socket.t()
  @callback events() :: [String.t()]
  @callback handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  @callback handle_info(term(), Socket.t()) :: {:noreply, Socket.t()} | :unhandled
  @callback tab_label(map()) :: String.t() | nil
  @callback tab_badge(map()) :: Phoenix.LiveView.Rendered.t()
  @callback overlay(map()) :: Phoenix.LiveView.Rendered.t()

  defmacro __using__(_opts) do
    quote do
      @behaviour PlatformWeb.SocialTab

      use PlatformWeb, :html

      import Phoenix.LiveView,
        only: [
          stream: 3,
          stream: 4,
          stream_insert: 3,
          stream_delete: 3,
          connected?: 1,
          redirect: 2,
          send_update: 2,
          cancel_upload: 3,
          consume_uploaded_entry: 3,
          allow_upload: 3
        ]

      import PlatformWeb.SocialHelpers

      @impl PlatformWeb.SocialTab
      def all_brands?, do: false

      @impl PlatformWeb.SocialTab
      def init(socket), do: socket

      @impl PlatformWeb.SocialTab
      def load(socket), do: socket

      @impl PlatformWeb.SocialTab
      def on_select(socket), do: socket

      @impl PlatformWeb.SocialTab
      def from_query(socket, _query), do: socket

      @impl PlatformWeb.SocialTab
      def events, do: []

      @impl PlatformWeb.SocialTab
      def handle_event(_event, _params, socket), do: {:noreply, socket}

      @impl PlatformWeb.SocialTab
      def handle_info(_message, _socket), do: :unhandled

      @impl PlatformWeb.SocialTab
      def tab_label(_assigns), do: nil

      @impl PlatformWeb.SocialTab
      def tab_badge(assigns), do: PlatformWeb.SocialTab.nothing(assigns)

      @impl PlatformWeb.SocialTab
      def overlay(assigns), do: PlatformWeb.SocialTab.nothing(assigns)

      defoverridable all_brands?: 0,
                     init: 1,
                     load: 1,
                     on_select: 1,
                     from_query: 2,
                     events: 0,
                     handle_event: 3,
                     handle_info: 2,
                     tab_label: 1,
                     tab_badge: 1,
                     overlay: 1
    end
  end
end
