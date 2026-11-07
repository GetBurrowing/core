defmodule PlatformWeb.SettingsLive.LearnedDefaultsComponent do
  @moduledoc """
  Settings → Learned defaults (task 01a1b6a1 stage 4; direction canvas
  01a1b6a2 node `layout`, mockup canvas 01a1b6ad section D;
  `0061-learned-defaults.md` §§ 2, 5).

  The body of `SettingsLive`'s `:learned_defaults` sheet, its own component
  so the page's other sections stay untouched. Only the viewer's own habits
  are ever read (`Platform.Habits.list_patterns/1` filters on the owner).

    * The learning switch, "Learn from what I do": ON by default; writes
      `users.preferences["learned_defaults"]` through
      `Platform.Habits.set_enabled/2` and reads it back, so a failed write
      reverts and says so. Turning it off keeps what was learned (§ 2);
      Forget deletes.
    * A plain list, one row per learned habit (a stream): the space, who,
      how far it goes now ("Suggest first", "Fill it in", "Do it for me",
      from `Platform.Habits.suggest/3`, never a percentage), and Forget
      (`Platform.Habits.forget/2`), which removes the row from the stream.
  """

  use PlatformWeb, :live_component

  alias Platform.Chat
  alias Platform.Habits
  alias Platform.Habits.LearnedAttention

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:loaded?, false)
     |> assign(:error, nil)
     |> stream_configure(:learned_patterns, dom_id: &"learned-pattern-#{&1.id}")
     |> stream(:learned_patterns, [])}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, :user_id, assigns.user_id) |> assign(:id, assigns.id)

    socket =
      if socket.assigns.loaded?,
        do: socket,
        else: load(socket)

    {:ok, socket}
  end

  defp load(socket) do
    user_id = socket.assigns.user_id
    rows = if is_binary(user_id), do: rows(user_id), else: []

    socket
    |> assign(:loaded?, true)
    |> assign(:enabled?, is_binary(user_id) and Habits.enabled?(user_id))
    |> assign(:count, length(rows))
    |> stream(:learned_patterns, rows, reset: true)
  end

  @impl true
  def handle_event("set_learned_defaults", params, socket) do
    enabled? = params["enabled"] in ["true", true]
    user_id = socket.assigns.user_id

    result = if is_binary(user_id), do: Habits.set_enabled(user_id, enabled?), else: :error
    stored? = is_binary(user_id) and Habits.enabled?(user_id)

    error =
      case result do
        {:ok, _} when stored? == enabled? -> nil
        _ -> "Couldn't save. Your setting hasn't changed."
      end

    {:noreply, socket |> assign(:enabled?, stored?) |> assign(:error, error)}
  end

  def handle_event("forget_learned_default", %{"id" => id}, socket) when is_binary(id) do
    case Habits.forget(socket.assigns.user_id, id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> stream_delete_by_dom_id(:learned_patterns, "learned-pattern-#{id}")
         |> assign(:count, max(socket.assigns.count - 1, 0))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("forget_learned_default", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} data-role="learned-defaults" class="flex flex-col gap-4 px-[18px] pb-4">
      <p class="text-sm leading-5 text-subtle">
        Notices who you usually ask in each space. It can suggest them first, fill them in, or ask for you, and it always shows why. Only you see this list.
      </p>
      <button
        type="button"
        role="switch"
        aria-checked={to_string(@enabled?)}
        phx-click="set_learned_defaults"
        phx-value-enabled={to_string(!@enabled?)}
        phx-target={@myself}
        data-role="learned-defaults-switch"
        class="flex min-h-14 w-full items-center justify-between gap-3 rounded-box border border-edge bg-base-200 px-3.5 py-3 text-left text-[15px] text-base-content focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
      >
        <span class="min-w-0">
          <span class="block font-semibold">Learn from what I do</span>
          <span class="block text-xs text-subtle">
            Off stops learning and suggesting. What's already learned stays until you forget it.
          </span>
        </span>
        <span
          class={[
            "relative inline-flex h-[26px] w-11 flex-none rounded-full transition-colors",
            if(@enabled?, do: "bg-primary", else: "bg-base-300")
          ]}
          aria-hidden="true"
        >
          <span class={[
            "absolute top-[3px] size-5 rounded-full",
            if(@enabled?,
              do: "right-[3px] bg-primary-content",
              else: "left-[3px] bg-base-100 ring-1 ring-edge"
            )
          ]}>
          </span>
        </span>
      </button>
      <p :if={@error} data-role="learned-defaults-error" class="text-xs text-subtle">{@error}</p>

      <div>
        <p class="mx-1 mb-2 text-xs font-semibold uppercase tracking-[0.1em] text-subtle">
          Who you usually ask
        </p>
        <p
          :if={@count == 0}
          data-role="learned-defaults-empty"
          class="rounded-box border border-edge bg-base-100 px-3.5 py-3 text-[13px] text-subtle"
        >
          Nothing learned yet. When you ask the same person to look at your messages in a space, they show up here.
        </p>
        <ul
          id={"#{@id}-list"}
          phx-update="stream"
          data-role="learned-defaults-list"
          class={[
            "overflow-hidden rounded-box border border-edge",
            @count == 0 && "hidden"
          ]}
        >
          <li
            :for={{dom_id, row} <- @streams.learned_patterns}
            id={dom_id}
            data-role="learned-defaults-pattern"
            data-pattern-id={row.id}
            class="flex items-center gap-3 border-t border-edge bg-base-100 px-3.5 py-3 first:border-t-0"
          >
            <span class="min-w-0 flex-1">
              <span
                data-role="learned-defaults-space"
                class="block truncate text-xs font-semibold text-subtle"
              >
                {row.space_name}
              </span>
              <span class="block break-words text-[15px] font-semibold text-base-content">
                Ask {row.target_name} for attention
              </span>
              <span data-role="learned-defaults-rung" class="block text-[13px] text-subtle">
                {row.rung_label}
              </span>
            </span>
            <button
              type="button"
              phx-click="forget_learned_default"
              phx-value-id={row.id}
              phx-target={@myself}
              data-role="learned-defaults-forget"
              class="h-8 flex-none self-start rounded-[var(--radius-field)] border border-edge px-2.5 text-[13px] font-semibold text-subtle focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
            >
              Forget
            </button>
          </li>
        </ul>
        <p class="mx-1 mt-2.5 text-xs leading-[17px] text-subtle">
          “Do it for me” only ever covers things you can undo. It moves up a step after you accept the pre-fill several times, and drops back whenever you say Not, Undo or Stop.
        </p>
      </div>
    </div>
    """
  end

  # One row per pattern: the space's name, the target's name in that space,
  # and how far the habit goes now.
  defp rows(user_id) do
    user_id
    |> Habits.list_patterns()
    |> Enum.flat_map(fn {space_id, patterns} -> space_rows(user_id, space_id, patterns) end)
  end

  defp space_rows(user_id, space_id, patterns) do
    space = if is_binary(space_id), do: Chat.get_space(space_id)
    names = participant_names(space_id)
    learned = learned(user_id, space_id)

    Enum.map(patterns, fn p ->
      %{
        id: p.id,
        space_name: space_label(space),
        target_name: Map.get(names, p.target_id, "someone"),
        rung_label: rung_label(p, learned)
      }
    end)
  end

  defp participant_names(space_id) when is_binary(space_id) do
    space_id
    |> Chat.list_participants()
    |> Map.new(&{&1.participant_id, &1.display_name || "someone"})
  rescue
    _ -> %{}
  end

  defp participant_names(_space_id), do: %{}

  defp learned(user_id, space_id) do
    Habits.suggest(user_id, space_id, LearnedAttention.action())
  rescue
    _ -> %{prefill: nil, act: nil}
  end

  defp space_label(%{kind: "dm"}), do: "Direct message"
  defp space_label(%{name: name}) when is_binary(name), do: "#" <> name
  defp space_label(_space), do: "Everywhere"

  defp rung_label(p, learned) do
    target = %{target_type: p.target_type, target_id: p.target_id}

    cond do
      p.stopped_at != nil -> "Suggest first · won't ask for you"
      same?(learned[:act], target) -> "Do it for me"
      same?(learned[:prefill], target) -> "Fill it in"
      true -> "Suggest first"
    end
  end

  defp same?(%{target_type: t, target_id: id}, %{target_type: t, target_id: id}), do: true
  defp same?(_a, _b), do: false
end
