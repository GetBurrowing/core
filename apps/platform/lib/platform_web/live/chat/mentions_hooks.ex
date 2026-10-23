defmodule PlatformWeb.ChatLive.MentionsHooks do
  @moduledoc """
  Lifecycle hook module for the Mentions autocomplete in
  `PlatformWeb.ChatLive`.

  See ADR 0035. Mentions has distributed UI (two dropdowns — one next
  to the main compose form, one per inline thread compose) so it lives
  as a LifecycleHook. Owns:

    * Assigns: `:mention_suggestions`, `:mention_source`,
      `:mention_query` (the typed query while one is active, else nil; the
      in-flow list's empty row reads it), `:mention_addable_agents`
    * Events:  `"mention_query"`, `"mention_clear"`

  ## Cross-LiveView event contract

  The `compose_input.js` hook pushes `mention_query` and `mention_clear`
  from both `ChatLive` and `TasksLive`. Event names here must match
  that contract. Rename requires updating all three files together.

  ## The thread reply list lives in a stream row

  The space composer's list re-renders with the assigns. The thread reply
  box's list is inside its parent message's row in the `:messages` stream,
  and a stream row renders only when it is (re)inserted. So a query from a
  thread composer (`inline-thread-compose-form-<message id>`), and the clear
  or source change that closes it, reinserts that one row
  (`MessagesHooks.reinsert_stream_message/2`), and only while the row is in
  the stream.

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

  alias Platform.Chat
  alias PlatformWeb.ChatLive.MessagesHooks
  alias Platform.Chat.Space

  @default_source "compose-form"
  @max_suggestions 8

  @doc "Attach Mentions handlers. Call from `ChatLive.mount/3`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:mention_suggestions, [])
    |> assign(:mention_source, @default_source)
    |> assign(:mention_query, nil)
    |> assign(:mention_addable_agents, [])
    |> attach_hook(:mention_events, :handle_event, &handle_event/3)
  end

  @doc """
  Reset Mentions state on space change.

  Also loads, ONCE per space entry, the summonable agents that are not yet
  in the space (`Chat.list_addable_agents/1`) into `:mention_addable_agents`,
  so `mention_query` can offer them without a query per keystroke. An external
  session, or a socket with no active space, gets `[]`: external users are
  never offered agents.
  """
  @spec reset_for_space(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reset_for_space(socket) do
    socket
    |> assign(:mention_suggestions, [])
    |> assign(:mention_source, @default_source)
    |> assign(:mention_query, nil)
    |> assign(:mention_addable_agents, addable_agents_for(socket.assigns))
  end

  defp addable_agents_for(%{external?: true}), do: []
  defp addable_agents_for(%{active_space: %Space{} = space}), do: Chat.list_addable_agents(space)
  defp addable_agents_for(_assigns), do: []

  # ── Hook callbacks ────────────────────────────────────────────────────

  defp handle_event("mention_query", %{"query" => query} = params, socket) do
    source = Map.get(params, "source", @default_source)
    participants = socket.assigns[:participants_map] || %{}

    # rbac-external-users M5 stage 4: thread the render-branch flag + acting user
    # so the external surface's @-mention dropdown offers only allowlisted-org
    # humans (no agents). Internal sessions pass `external?: false` → unchanged.
    suggestions =
      build_suggestions(query, participants,
        external?: socket.assigns[:external?] == true,
        user_id: socket.assigns[:user_id],
        addable_agents: socket.assigns[:mention_addable_agents] || []
      )

    previous = socket.assigns[:mention_source]

    {:halt,
     socket
     |> assign(:mention_suggestions, suggestions)
     |> assign(:mention_source, source)
     |> assign(:mention_query, if(is_binary(query), do: query, else: nil))
     |> rerender_thread_rows([previous, source])}
  end

  defp handle_event("mention_query", _params, socket) do
    {:halt,
     socket
     |> assign(:mention_suggestions, [])
     |> assign(:mention_query, nil)
     |> rerender_thread_rows([socket.assigns[:mention_source]])}
  end

  defp handle_event("mention_clear", _params, socket) do
    previous = socket.assigns[:mention_source]

    {:halt,
     socket
     |> assign(:mention_suggestions, [])
     |> assign(:mention_source, @default_source)
     |> assign(:mention_query, nil)
     |> rerender_thread_rows([previous])}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  @thread_source_prefix "inline-thread-compose-form-"

  @doc """
  The parent message id a thread reply composer's `source` names, or nil
  for any other source (the space composer, the steering composer).
  """
  @spec thread_message_id(term()) :: String.t() | nil
  def thread_message_id(@thread_source_prefix <> id) when id != "", do: id
  def thread_message_id(_source), do: nil

  # Reinsert the stream row of every thread composer among `sources`, so its
  # list opens, filters or closes (see the moduledoc). A row that is not in
  # the stream is never inserted by this.
  defp rerender_thread_rows(socket, sources) do
    rendered = socket.assigns[:rendered_message_ids] || MapSet.new()

    sources
    |> Enum.map(&thread_message_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.filter(&MapSet.member?(rendered, &1))
    |> Enum.reduce(socket, &MessagesHooks.reinsert_stream_message(&2, &1))
  end

  @doc """
  Pure suggestion builder used by `mention_query`. Exposed for tests so the
  ranking contract can be exercised without a LiveView.

  ## Matching

  A participant matches when its downcased `display_name` starts with the
  downcased query (a PREFIX match) or contains it (an INFIX match). Archived
  users are dropped (task 019f671f validation 1(c); `participants_map` still
  carries them so historical author attribution renders, but they must NOT be
  selectable).

  ## Ranking

  Suggestions sort by, in order:

    1. group: agents, then users, then the `here` broadcast sentinel last;
    2. prefix match before infix match;
    3. within the agent group, in-space agents before addable (not-in-space)
       agents of the same match tier;
    4. alphabetical by downcased display name.

  `@max_suggestions` is applied AFTER ranking, so a long list of people never
  truncates the agents away.

  ## Addable agents

  `addable_agents:` (default `[]`) is the list `Chat.list_addable_agents/1`
  returned for the space. Each one that matches joins the agent group carrying
  `not_in_space: true`; every other suggestion carries `not_in_space: false`.
  An addable entry naming an agent already in `participants_map` (by principal
  id or by display name) is dropped, so an in-space agent never surfaces as
  not-in-space and no agent appears twice.

  ## External scope (rbac-external-users M5 stage 4)

  `external?: true` + `user_id:` drops (a) agent participants, (b) every
  addable agent, and (c) any human the external user may not DM/mention,
  reusing M8's `Chat.external_dm_permitted?/3` so mention scope == DM scope ==
  enforcement. A `permit_fn/3` opt overrides that predicate purely (for tests).
  The `@here` sentinel survives the scope filter: it broadcasts only within
  the current allowlisted space.
  """
  @spec build_suggestions(String.t() | nil, map(), keyword()) :: [map()]
  def build_suggestions(query, participants_map, opts \\ []) when is_map(participants_map) do
    query_lower = String.downcase(query || "")
    external? = Keyword.get(opts, :external?, false)

    in_space =
      participants_map
      |> Map.values()
      |> Enum.reject(&match?(%{archived: true}, &1))
      |> filter_external_scope(external?, opts)
      |> Enum.map(&Map.put(&1, :not_in_space, false))

    addable =
      if external? do
        []
      else
        opts |> Keyword.get(:addable_agents, []) |> addable_suggestions(in_space)
      end

    (in_space ++ addable ++ here_candidates(query_lower))
    |> Enum.flat_map(&rank(&1, query_lower))
    |> Enum.sort()
    |> Enum.map(fn {_key, suggestion} -> suggestion end)
    |> Enum.take(@max_suggestions)
  end

  # Internal surface: no additional scope filter.
  defp filter_external_scope(participants, false, _opts), do: participants

  # External surface: defense-in-depth on top of M6/M7's space scoping. Drop
  # agent participants outright, and keep only humans the external user may DM
  # (M8's predicate, injectable via `:permit_fn` for pure tests). A participant
  # with no resolvable principal id is dropped closed rather than open.
  defp filter_external_scope(participants, true, opts) do
    user_id = Keyword.get(opts, :user_id)
    permit? = Keyword.get(opts, :permit_fn, &Chat.external_dm_permitted?/3)

    Enum.filter(participants, fn
      %{participant_type: "agent"} -> false
      %{principal_id: pid} when is_binary(pid) -> permit?.(user_id, "user", pid)
      _ -> false
    end)
  end

  # Shape each addable agent like a participant identity, and drop any that
  # names an agent already in the space (the addable list is loaded once per
  # space entry, so an agent seated since then would otherwise appear twice).
  defp addable_suggestions(agents, in_space) do
    present = Enum.filter(in_space, &(&1[:participant_type] == "agent"))
    present_ids = MapSet.new(present, & &1[:principal_id])
    present_names = MapSet.new(present, &downcase_name(&1[:display_name]))

    agents
    |> Enum.map(&addable_suggestion/1)
    |> Enum.reject(fn s ->
      is_nil(s.display_name) or MapSet.member?(present_ids, s.principal_id) or
        MapSet.member?(present_names, downcase_name(s.display_name))
    end)
    |> Enum.uniq_by(& &1.principal_id)
  end

  defp addable_suggestion(agent) do
    name = Map.get(agent, :display_name) || Map.get(agent, :name)
    id = Map.get(agent, :id)

    %{
      name: name,
      display_name: name,
      participant_type: "agent",
      principal_id: id,
      avatar_url: blank_to_nil(Map.get(agent, :avatar_url)),
      avatar_seed: id,
      archived: false,
      not_in_space: true
    }
  end

  defp blank_to_nil(url) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp downcase_name(name) when is_binary(name), do: String.downcase(name)
  defp downcase_name(_), do: nil

  # `[{sort_key, suggestion}]` when the suggestion matches, `[]` otherwise.
  # The key's tuple order IS the ranking: group, match tier, in-space before
  # addable, then name.
  defp rank(%{display_name: name} = suggestion, query) when is_binary(name) do
    down = String.downcase(name)

    case match_tier(down, query) do
      nil ->
        []

      tier ->
        not_in_space = if suggestion[:not_in_space] == true, do: 1, else: 0
        [{{group_rank(suggestion), tier, not_in_space, down}, suggestion}]
    end
  end

  defp rank(_suggestion, _query), do: []

  defp group_rank(%{participant_type: "agent"}), do: 0
  defp group_rank(%{participant_type: "broadcast"}), do: 2
  defp group_rank(_), do: 1

  defp match_tier(name, query) do
    cond do
      String.starts_with?(name, query) -> 0
      String.contains?(name, query) -> 1
      true -> nil
    end
  end

  # `@here` is a broadcast sentinel, not a real participant. It is offered
  # whenever the query is a case-insensitive prefix of "here" (empty query
  # included, so the affordance is discoverable) and ranks LAST. Insertion
  # produces `@[here]`, which the mention parser recognises (ADR 0037; see
  # `Platform.Chat.AttentionRouter.here_mention?/1`).
  defp here_candidates(query) do
    if String.starts_with?("here", query), do: [here_sentinel()], else: []
  end

  defp here_sentinel do
    %{
      name: "here",
      display_name: "here",
      participant_type: "broadcast",
      avatar_url: nil,
      avatar_seed: nil,
      not_in_space: false
    }
  end
end
