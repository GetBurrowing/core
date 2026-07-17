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
    participants = socket.assigns[:participants_map] || %{}
    suggestions = build_suggestions(query, participants)

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

  @doc """
  Pure suggestion builder used by `mention_query`. Exposed for tests so we
  can exercise the `@here` sentinel ordering without spinning up a full
  LiveView. The pipeline is: filter participants by case-insensitive
  prefix → drop archived-user participants (task 019f671f validation 1(c);
  the `participants_map` still contains them so historical author
  attribution renders correctly, but they must NOT be selectable in the
  autocomplete) → prepend the `here` broadcast sentinel when the query is
  a prefix of "here" (empty query included) → truncate to
  `@max_suggestions`.
  """
  @spec build_suggestions(String.t() | nil, map()) :: [map()]
  def build_suggestions(query, participants_map) when is_map(participants_map) do
    query_lower = String.downcase(query || "")

    participants =
      participants_map
      |> Map.values()
      |> Enum.filter(&matches?(&1, query_lower))

    query_lower
    |> prepend_here_sentinel(participants)
    |> Enum.take(@max_suggestions)
  end

  # Archived-user participants live in `participants_map` for historical
  # rendering (see `PresenceHooks.enter_space/4` — `include_archived: true`
  # is deliberate). Reject them here so `@Rowan Kl` doesn't autocomplete to
  # an archived user. Agents carry `archived: false` (see
  # `PresenceHooks.participant_identity/2`), so this is safe as a single
  # boolean lookup regardless of `participant_type`.
  defp matches?(%{archived: true}, _query), do: false

  defp matches?(%{display_name: name}, query) when is_binary(name) do
    name |> String.downcase() |> String.starts_with?(query)
  end

  defp matches?(_, _), do: false

  # `@here` is a broadcast sentinel — not a real participant, but it sits at
  # the top of the suggestion list whenever the user's query is a
  # case-insensitive prefix of "here" (empty query included, so the
  # affordance is discoverable). Insertion produces `@[here]`, which the
  # mention parser recognises (ADR 0037; see
  # `Platform.Chat.AttentionRouter.here_mention?/1`).
  defp prepend_here_sentinel(query, participants) do
    if String.starts_with?("here", query) do
      [here_sentinel() | participants]
    else
      participants
    end
  end

  defp here_sentinel do
    %{
      name: "here",
      display_name: "here",
      participant_type: "broadcast",
      avatar_url: nil,
      avatar_seed: nil
    }
  end
end
