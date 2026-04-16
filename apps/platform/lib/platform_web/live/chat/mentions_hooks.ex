defmodule PlatformWeb.ChatLive.MentionsHooks do
  @moduledoc """
  Lifecycle hook module for the Mentions autocomplete in
  `PlatformWeb.ChatLive`.

  See ADR 0035. Mentions has distributed UI (two dropdowns — one next
  to the main compose form, one per inline thread compose) so it lives
  as a LifecycleHook. Owns:

    * Assigns: `:mention_suggestions`, `:mention_source`
    * Events:  `"mention_query"`, `"mention_clear"`

  ## Cross-LiveView event contract

  The `compose_input.js` hook pushes `mention_query` and `mention_clear`
  from both `ChatLive` and `TasksLive`. Event names here must match
  that contract. Rename requires updating all three files together.

  ## Implementation note

  Candidate lookup reads `@participants_map` rather than re-querying
  the database — the parent has already built it in `handle_params`
  from the same source data.

  ## Usage

      # In ChatLive.mount/3:
      socket = PlatformWeb.ChatLive.MentionsHooks.attach(socket)

      # In ChatLive.handle_params/3 on space change:
      socket = PlatformWeb.ChatLive.MentionsHooks.reset_for_space(socket)
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  @default_source "compose-form"
  @max_suggestions 8

  @doc "Attach Mentions handlers. Call from `ChatLive.mount/3`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:mention_suggestions, [])
    |> assign(:mention_source, @default_source)
    |> attach_hook(:mention_events, :handle_event, &handle_event/3)
  end

  @doc "Reset Mentions state on space change."
  @spec reset_for_space(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reset_for_space(socket) do
    socket
    |> assign(:mention_suggestions, [])
    |> assign(:mention_source, @default_source)
  end

  # ── Hook callbacks ────────────────────────────────────────────────────

  defp handle_event("mention_query", %{"query" => query} = params, socket) do
    source = Map.get(params, "source", @default_source)
    query_lower = String.downcase(query || "")

    suggestions =
      socket.assigns[:participants_map]
      |> Kernel.||(%{})
      |> Map.values()
      |> Enum.filter(&matches?(&1, query_lower))
      |> Enum.take(@max_suggestions)

    {:halt,
     socket
     |> assign(:mention_suggestions, suggestions)
     |> assign(:mention_source, source)}
  end

  defp handle_event("mention_query", _params, socket) do
    {:halt, assign(socket, :mention_suggestions, [])}
  end

  defp handle_event("mention_clear", _params, socket) do
    {:halt,
     socket
     |> assign(:mention_suggestions, [])
     |> assign(:mention_source, @default_source)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp matches?(%{display_name: name}, query) when is_binary(name) do
    name |> String.downcase() |> String.starts_with?(query)
  end

  defp matches?(_, _), do: false
end
