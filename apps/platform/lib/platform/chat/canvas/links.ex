defmodule Platform.Chat.Canvas.Links do
  @moduledoc """
  The canonical address of a canvas (task 019e2c4b, stage 5).

  One builder for `/canvases/:id`, so the route registered in
  `PlatformWeb.Router`, the copy-link control on the standalone page
  (`PlatformWeb.CanvasLive`) and the `view_url` field returned by the canvas
  MCP tools cannot drift apart. Three literals would eventually disagree; one
  function cannot.

  ## Canonical, never a token

  `view_url/1` is always the canonical form. It carries no credential: it
  resolves for a viewer who already holds a grant under
  `Platform.Chat.CanvasAccess` and denies everyone else. When share tokens
  eventually ship they get a SEPARATE `share_url` field rather than changing
  what this returns, so a canonical link can never silently become a bearer
  credential that someone pastes into a public channel.

  `PlatformWeb.Endpoint.url/0` already resolves the correct per-environment
  host, so no new configuration is introduced (precedent:
  `Platform.Tasks.StackDeployer`'s task URLs).
  """

  @path "/canvases/"

  @doc """
  Absolute URL of the standalone canvas page for `canvas_id`.

  The id is not validated here — an id that does not resolve renders stage 4's
  not-found state, and a viewer without a grant renders the forbidden state.
  Both are properties of the page, not of the link.
  """
  @spec view_url(binary()) :: String.t()
  def view_url(canvas_id) when is_binary(canvas_id) do
    PlatformWeb.Endpoint.url() <> @path <> canvas_id
  end

  @doc """
  The path segment the URL is built on, exposed so tests can assert route
  parity against `PlatformWeb.Router` rather than against a second literal.
  """
  @spec path_prefix() :: String.t()
  def path_prefix, do: @path
end
