defmodule PlatformWeb.StaticReload do
  @moduledoc """
  Mount hook that reloads the page when the client's tracked assets are
  from an older deploy.

  A page that stays open across a deploy keeps its old `app.css` and
  `app.js`. When its LiveView reconnects to the new server it gets the
  NEW markup, and the old stylesheet has no rules for classes the deploy
  added. This happened on 2026-10-31: the calendar v4 rebuild (PR #62)
  added `cal-page`, `cal-panel`, `cal-input`, `mt-list-pane` and `mt-row`.
  The phone app's WebView had been open since before the deploy, so
  `/calendar/settings` and `/meetings` rendered as unstyled, run-on text
  while the older `btn` rules still applied. Desktop tabs looked fine
  because they had been loaded fresh.

  `phx-track-static` on the root layout's `app.css` and `app.js` makes the
  client send their digested URLs on connect, and
  `Phoenix.LiveView.static_changed?/1` compares them with the server's
  cache manifest. This hook acts on a mismatch: it halts the first
  `handle_params` with an external redirect to the same URL. That is a
  full page load, which brings the current assets. The redirect runs on
  the server, so it also works for a client still running the OLD
  `app.js`, which knows nothing about this hook.

  There is no reload loop. The reloaded page's tracked URLs are rendered
  from the same manifest the check compares against, so they match. A
  build without a manifest (dev, test) never reports a change.

  Only root LiveViews mounted at the router are checked.
  `static_changed?/1` raises in a nested child, and `handle_params` hooks
  need the router. A nested LiveView reloads with its parent.
  """

  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    if checkable?(socket) and static_changed?(socket) do
      {:cont, attach_hook(socket, :static_reload, :handle_params, &reload/3)}
    else
      {:cont, socket}
    end
  end

  defp checkable?(socket) do
    connected?(socket) and is_nil(socket.parent_pid) and not is_nil(socket.router)
  end

  defp reload(_params, uri, socket) do
    {:halt, redirect(socket, external: uri)}
  end
end
