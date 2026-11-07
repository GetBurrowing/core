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

  ## Pick mode

  `pick` makes the same list the "Get someone's attention" picker (redesign
  rung 12, `Partials.Overlays.message_attention_sheet/1`): a row pushes
  `add_message_attention` with the message id and the row's principal id
  instead of inserting a chip, a row in `added` reads a right-aligned
  "added" and does nothing, and no row starts highlighted (no composer hook
  owns a highlight there). The panel sits on the sheet's own surface, in
  flow at every width (`.mention-list--pick` in app.css). One list, one row
  anatomy: the composer and the picker cannot drift apart.

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

  attr(:field_id, :string,
    default: nil,
    doc: "the field a picked row inserts its chip into; unused in pick mode"
  )

  attr(:open, :boolean, default: true, doc: "false renders only the empty wrapper")

  attr(:pick, :string,
    default: nil,
    doc: "pick mode: the message id a row asks attention for (see Pick mode)"
  )

  attr(:added, :any,
    default: MapSet.new(),
    doc: "pick mode: principal ids already asked, rendered as 'added' no-ops"
  )

  attr(:why, :string,
    default: nil,
    doc: "pick mode: the learned row whose 'Why this?' line is open (a principal id)"
  )

  def mention_list(assigns) do
    suggestions = order(assigns.suggestions)

    assigns =
      assigns
      |> assign(:rows, Enum.with_index(suggestions))
      |> assign(:status, status_text(suggestions))

    ~H"""
    <div
      id={"#{@id}-wrap"}
      data-role="mention-list"
      class={["mention-list", @pick && "mention-list--pick"]}
    >
      <p class="sr-only" aria-live="polite" data-role="mention-list-status">
        {if @open, do: @status}
      </p>
      <div :if={@open} class="mention-list-panel">
        <div id={@id} role="listbox" aria-label="Mention suggestions" class="mention-list-box">
          <%= for {suggestion, idx} <- @rows do %>
            <div
              id={"#{@id}-opt-#{idx}"}
              role="option"
              aria-selected={to_string(idx == 0 and is_nil(@pick))}
              aria-disabled={added?(suggestion, @added) && "true"}
              data-mention-suggestion={if idx == 0, do: "first", else: "row"}
              data-mention-name={suggestion.name}
              data-principal-id={@pick && suggestion[:principal_id]}
              data-added={added?(suggestion, @added) && "true"}
              data-kind={kind(suggestion)}
              phx-click={row_click(suggestion, @pick, @field_id, @added)}
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
                <.reason_line :if={@pick && suggestion[:learned] == true} suggestion={suggestion} />
              </span>
              <span
                :if={added?(suggestion, @added)}
                class="mention-list-added"
                data-role="mention-list-added"
              >
                added
              </span>
            </div>
            <.why_line
              :if={@pick && suggestion[:learned] == true && @why == suggestion[:principal_id]}
              suggestion={suggestion}
            />
          <% end %>
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

  attr(:suggestion, :map, required: true)

  @doc """
  The learned row's reason line (task 01a1b6a1 stage 4; direction canvas
  01a1b6a2 nodes `layout` and `type`, mockup 01a1b6ad): the row's second
  line, `--color-info`, 13px regular with the name semibold, and the ✦ mark
  at its start. Mark and sentence are one tap target, which opens the row's
  "Why this?" line (`toggle_attention_why`) and never picks the row.
  """
  def reason_line(assigns) do
    assigns = assign(assigns, :name, reason_name(assigns.suggestion))

    ~H"""
    <button
      type="button"
      data-role="learned-reason"
      phx-click={
        JS.push("toggle_attention_why", value: %{"principal-id" => @suggestion[:principal_id]})
      }
      class="block self-start rounded text-left text-[13px] font-normal leading-[18px] text-info focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
    >
      <span data-role="learned-mark" class="mr-1 text-[11px] leading-none" aria-hidden="true">✦</span>
      <span>
        You usually ask <span data-role="learned-reason-name" class="font-semibold">{@name}</span>
        here
      </span>
    </button>
    """
  end

  attr(:suggestion, :map, required: true)

  @doc """
  "Why this?" (stage 4): one plain sentence, no count and no percentage, and
  the way into Settings → Learned defaults.
  """
  def why_line(assigns) do
    assigns = assign(assigns, :name, reason_name(assigns.suggestion))

    ~H"""
    <div
      data-role="learned-why"
      role="note"
      class="mx-3 mb-1.5 rounded-[var(--radius-field)] bg-base-200 px-2.5 py-2 text-[13px] leading-[18px] text-base-content"
    >
      <span class="font-semibold text-info">Why this?</span>
      You often ask {@name} to look at your messages in this space.
      <.link
        navigate="/settings?sheet=learned_defaults"
        data-role="learned-why-link"
        class="mt-1 block font-semibold text-base-content underline underline-offset-2"
      >
        Learned defaults ›
      </.link>
    </div>
    """
  end

  defp reason_name(%{reason: {:usually, name}}) when is_binary(name), do: name
  defp reason_name(suggestion), do: suggestion[:display_name] || suggestion[:name]

  # Composer mode inserts a chip into the field; pick mode asks attention for
  # the row's principal, and an already-added row does nothing.
  defp row_click(suggestion, nil, field_id, _added) do
    JS.dispatch("chat:insert-mention", to: "##{field_id}", detail: %{name: suggestion.name})
  end

  defp row_click(suggestion, message_id, _field_id, added) do
    if added?(suggestion, added) do
      nil
    else
      JS.push("add_message_attention",
        value: %{"message-id" => message_id, "ids" => [suggestion[:principal_id]]}
      )
    end
  end

  defp added?(%{principal_id: id}, %MapSet{} = added) when is_binary(id),
    do: MapSet.member?(added, id)

  defp added?(_suggestion, _added), do: false

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

  # Learned rows first (task 01a1b6a1 stage 4: the picker's learned order is
  # the point, so it is exempt from the kind sort), then agents, then people,
  # then the `here` broadcast; stable within a group, so the server's ranking
  # inside each group stands.
  defp order(suggestions) do
    Enum.sort_by(suggestions, fn s ->
      cond do
        s[:learned] == true -> -1
        kind(s) == "agent" -> 0
        kind(s) == "broadcast" -> 2
        true -> 1
      end
    end)
  end

  defp kind(%{participant_type: "agent"}), do: "agent"
  defp kind(%{participant_type: "broadcast"}), do: "broadcast"
  defp kind(_), do: "user"

  defp kind_label(s), do: if(kind(s) == "agent", do: "agent", else: "person")
end
