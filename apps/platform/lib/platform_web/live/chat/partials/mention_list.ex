defmodule PlatformWeb.ChatLive.Partials.MentionList do
  @moduledoc """
  The in-flow @mention list (redesign rung 10, stage 3): the list that opens
  straight out of a composer while an `@query` is being typed.

  It is part of the composer, not a floating card: it renders in normal flow
  inside the composer's form, directly above the pill, on the composer's own
  glass with its edge and no shadow (direction canvas 01a16233, nodes `lay`
  and `pal`). Below lg the chat dock is an absolute overlay, so the list
  grows upward over the conversation; at lg it takes no height of its own
  (see `.mention-list` in app.css), so the conversation viewport and its
  scroll position never change while it is open.

  Row anatomy follows the prototype's `.mention-strip`: a 32px avatar, the
  name in base-content, and a small kind pill ("agent" / "person"). No section
  headers and no role line. An agent who is not in the space says so on its
  row ("Not in this space · adds them"), because picking it adds them.

  That note is the row's second line, under the name (direction canvas
  01a16233, rule "Not in this space": a visible consequence, so it can't be
  hidden). It wraps rather than ellipsizes, so it reads whole in the
  ~220px phone thread list too. A row with a note is taller than the 50px
  (phone) / 40px (desktop) of a row without one; `here`'s "Notify everyone
  in the channel" is a note and sits the same way.

  ## Keyboard and focus

  The rows never take focus. `ComposeInput` (hooks/compose_input.js) owns
  the highlight: it moves it with the arrow keys, picks with Enter or Tab,
  closes on Esc, and keeps the field's `aria-activedescendant` on the
  highlighted row. It also prevents the default of a pointerdown on a row, so
  the phone keyboard stays up and the caret stays put; the row's click then
  dispatches `chat:insert-mention` on the field, which inserts the chip.

  The server renders the first row highlighted; the hook re-applies its own
  index after every patch, clamped to the new length.

  ## The wrapper is always rendered

  The `[data-role="mention-list"]` wrapper is in the DOM whether or not the
  list is open; only its panel comes and goes (`open`). A wrapper that came
  and went would be a new unkeyed sibling before the pill, and LiveView's
  DOM patch would morph the pill into it and move the field (a keyed
  element) into a fresh pill: the field blurs on every open and close, the
  phone keyboard drops, and the tab bar flashes back. Measured on the dev rig
  before this: one blur and two `chat:dock-resized` per open. Closed, the
  wrapper holds only the (empty) live region and takes no height.

  The polite live region lives in the wrapper for the same reason: it is in
  the DOM before the list opens, so the "4 agents, 1 person" text that
  arrives with the list is a change to an existing region, which screen
  readers announce (a region inserted already holding its text often is
  not).

  ## Ids

  `id` is the listbox (the field's `aria-controls`), and each pickable row is
  `<id>-opt-<n>`, which is what `aria-activedescendant` names.

  The wrapper is `<id>-wrap`. Its DOM id is its morph key: without one,
  LiveView keys it by the render's magic id (`data-phx-id`), which is
  minted anew whenever the whole template renders again, as a stream row
  does on every reinsert (the thread reply box's list, stage 4). A wrapper
  whose key changed is a new node to the DOM patch, which then moves the
  field after it, and a moved field blurs (measured on the dev rig: one
  blur per keystroke, and a stale `--chat-dock-h` from the tab bar's flash).

  Used by `Partials.Composer.composer/1` for the space composer, and by
  `PlatformWeb.Components.ChatMessage` above each thread reply box (stage 4).
  The thread's list is the one planned exception to "in flow": that reply
  box sits inside `#message-list`, so app.css hangs the list from the box's
  top edge (`.thread-field-box .mention-list`, absolute, the box's width)
  instead, and it covers the thread messages above it.
  """

  use Phoenix.Component

  import PlatformWeb.AvatarComponents, only: [agent_avatar: 1, human_avatar: 1]

  alias Phoenix.LiveView.JS

  attr(:id, :string, required: true, doc: "the listbox id, which the field's aria-controls names")
  attr(:suggestions, :list, required: true, doc: "MentionsHooks.build_suggestions/3 entries")

  attr(:query, :string,
    default: nil,
    doc: "the typed query, for the empty row; nil when the caller does not know it"
  )

  attr(:field_id, :string, required: true, doc: "the field a picked row inserts its chip into")
  attr(:open, :boolean, default: true, doc: "false renders only the empty wrapper")

  def mention_list(assigns) do
    suggestions = order(assigns.suggestions)

    assigns =
      assigns
      |> assign(:rows, Enum.with_index(suggestions))
      |> assign(:status, status_text(suggestions))

    ~H"""
    <div id={"#{@id}-wrap"} data-role="mention-list" class="mention-list">
      <p class="sr-only" aria-live="polite" data-role="mention-list-status">
        {if @open, do: @status}
      </p>
      <div :if={@open} class="mention-list-panel">
        <div id={@id} role="listbox" aria-label="Mention suggestions" class="mention-list-box">
          <div
            :for={{suggestion, idx} <- @rows}
            id={"#{@id}-opt-#{idx}"}
            role="option"
            aria-selected={to_string(idx == 0)}
            data-mention-suggestion={if idx == 0, do: "first", else: "row"}
            data-mention-name={suggestion.name}
            data-kind={kind(suggestion)}
            phx-click={
              JS.dispatch("chat:insert-mention",
                to: "##{@field_id}",
                detail: %{name: suggestion.name}
              )
            }
            class="mention-list-row active:bg-base-100"
          >
            <%= case kind(suggestion) do %>
              <% "broadcast" -> %>
                <span class="mention-list-broadcast" aria-hidden="true">
                  <span class="hero-megaphone size-4"></span>
                </span>
              <% "agent" -> %>
                <.agent_avatar
                  name={suggestion.name}
                  avatar_url={suggestion[:avatar_url]}
                  size="md"
                  class="flex-shrink-0"
                />
              <% _ -> %>
                <.human_avatar
                  name={suggestion.name}
                  avatar_url={suggestion[:avatar_url]}
                  seed={suggestion[:avatar_seed]}
                  size="md"
                  class="flex-shrink-0"
                />
            <% end %>
            <span class="mention-list-text">
              <span class="mention-list-line">
                <span class="mention-list-name">{suggestion.name}</span>
                <span :if={kind(suggestion) != "broadcast"} class="mention-list-kind">
                  {kind_label(suggestion)}
                </span>
              </span>
              <span :if={kind(suggestion) == "broadcast"} class="mention-list-note">
                Notify everyone in the channel
              </span>
              <span :if={suggestion[:not_in_space] == true} class="mention-list-note">
                Not in this space · adds them
              </span>
            </span>
          </div>
          <div
            :if={@rows == [] and is_binary(@query)}
            role="option"
            aria-disabled="true"
            aria-selected="false"
            data-role="mention-list-empty"
            class="mention-list-empty"
          >
            No one matches “{@query}”
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  True when the list has something to show: suggestions, or a known query
  that matched no one (the empty row).
  """
  @spec open?([map()], String.t() | nil) :: boolean()
  def open?(suggestions, query), do: suggestions != [] or is_binary(query)

  @doc """
  The polite live-region text: "4 agents, 1 person", pluralised, counting
  only the agent and person rows. An empty filter reads "No one matches".
  """
  @spec status_text([map()]) :: String.t()
  def status_text(suggestions) do
    agents = Enum.count(suggestions, &(kind(&1) == "agent"))
    people = Enum.count(suggestions, &(kind(&1) == "user"))
    here? = Enum.any?(suggestions, &(kind(&1) == "broadcast"))

    parts =
      [count_label(agents, "agent", "agents"), count_label(people, "person", "people")]
      |> Enum.reject(&is_nil/1)

    parts = if here?, do: parts ++ ["here"], else: parts

    case parts do
      [] -> "No one matches"
      _ -> Enum.join(parts, ", ")
    end
  end

  defp count_label(0, _one, _many), do: nil
  defp count_label(1, one, _many), do: "1 #{one}"
  defp count_label(n, _one, many), do: "#{n} #{many}"

  # Agents, then people, then the `here` broadcast; stable within a group,
  # so the server's ranking inside each group stands.
  defp order(suggestions) do
    Enum.sort_by(suggestions, fn s ->
      case kind(s) do
        "agent" -> 0
        "broadcast" -> 2
        _ -> 1
      end
    end)
  end

  defp kind(%{participant_type: "agent"}), do: "agent"
  defp kind(%{participant_type: "broadcast"}), do: "broadcast"
  defp kind(_), do: "user"

  defp kind_label(s), do: if(kind(s) == "agent", do: "agent", else: "person")
end
