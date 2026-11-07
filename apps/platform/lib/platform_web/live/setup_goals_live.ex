defmodule PlatformWeb.SetupGoalsLive do
  @moduledoc """
  `/setup/goals`: the setup goal question (task 01a1b6de stage 1; design
  direction canvas 01a1b6de-c3bf-7000-8024-6e29d6ee9e83, node `layout`,
  screen 1). Reached from `/setup/connect-ai` once the owner's AI is
  connected.

  The owner writes up to `Platform.Chat.Space.max_goals/0` goals in their
  own words. Continue saves them through `Platform.Agents.Lead.save_setup_goals/1`
  (the agents space, else the default team channel led by the lead agent)
  and goes on to the Burrow agent's Getting started space, or `/chat` when
  there is none. Skip writes nothing. The goals stay editable later from the
  chat goal editor, which reads the same row.

  `{Lead}` in the helper line is `Platform.Agents.Lead.name/0`, the one
  config point for the lead's name.

  ## Tokens

  `primary` / `primary-content` only on Continue. Fields use `border-edge`
  and `ring-focus-ring`; secondary text is `text-subtle`. No display type.

  ## Authorization

  The route sits in the `:admin` live_session (`ModuleGate` maps this view to
  the `:admin` module) and the mount re-checks `Tenancy.root_admin?/1`, as
  `/setup/connect-ai` does.
  """
  use PlatformWeb, :live_view

  require Logger

  alias Platform.Agents.{Burrow, Lead}
  alias Platform.Agents.Burrow.GettingStarted
  alias Platform.Chat.Space
  alias Platform.Tenancy

  @impl true
  def mount(_params, _session, socket) do
    if Tenancy.root_admin?(socket.assigns[:current_user_record]) do
      goals =
        case Lead.goals() do
          [] -> [""]
          goals -> goals
        end

      {:ok,
       socket
       |> assign(:page_title, "Your goals")
       |> assign(:lead_name, Lead.name())
       |> assign(:max, Space.max_goals())
       |> assign(:error, nil)
       |> assign_goals(goals)}
    else
      {:ok, redirect(socket, to: "/access-denied?module=admin")}
    end
  end

  @impl true
  def handle_event("change", params, socket) do
    {:noreply, socket |> assign(:error, nil) |> assign_goals(goals_param(params, socket))}
  end

  def handle_event("add", _params, socket) do
    goals = socket.assigns.goals

    goals =
      if length(goals) < socket.assigns.max, do: goals ++ [""], else: goals

    {:noreply, assign_goals(socket, goals)}
  end

  def handle_event("save", params, socket) do
    goals = goals_param(params, socket)

    case Lead.save_setup_goals(goals) do
      {:ok, _space_or_skipped} ->
        {:noreply, push_navigate(socket, to: next_path())}

      {:error, reason} ->
        Logger.warning("[SetupGoalsLive] goals not saved: #{inspect(error_kind(reason))}")

        {:noreply,
         socket
         |> assign(:error, error_text(reason, socket.assigns.max))
         |> assign_goals(goals)}
    end
  end

  def handle_event(event, _params, socket) do
    Logger.warning("[SetupGoalsLive] refused unknown event #{inspect(event)}")
    {:noreply, socket}
  end

  defp assign_goals(socket, goals) do
    socket
    |> assign(:goals, goals)
    |> assign(:form, to_form(%{"goals" => goals}, as: :setup))
  end

  # The form posts `setup[goals][]`, in order. A browser that sends more than
  # the page offers is still refused by the changeset, never truncated here.
  defp goals_param(%{"setup" => %{"goals" => goals}}, _socket) when is_list(goals),
    do: Enum.map(goals, &to_string/1)

  defp goals_param(%{"setup" => %{"goals" => goals}}, _socket) when is_map(goals),
    do: goals |> Enum.sort_by(fn {k, _} -> k end) |> Enum.map(fn {_, v} -> to_string(v) end)

  defp goals_param(_params, socket), do: socket.assigns.goals

  @doc "Where Continue and Skip go: Burrow's Getting started space, else `/chat`."
  @spec next_path() :: String.t()
  def next_path do
    with %{} = agent <- Burrow.get(),
         %{slug: slug} <- GettingStarted.getting_started_space(agent) do
      "/chat/#{slug}"
    else
      _ -> "/chat"
    end
  end

  defp error_kind(%Ecto.Changeset{} = cs), do: Keyword.keys(cs.errors)
  defp error_kind(other), do: other

  defp error_text(%Ecto.Changeset{errors: errors}, max) do
    case Keyword.get(errors, :goals) do
      {_msg, opts} ->
        if opts[:count] == max,
          do: "You can set up to #{max} goals.",
          else: "Each goal can be at most #{opts[:count]} characters."

      nil ->
        "That didn't save. Try again."
    end
  end

  defp error_text(_reason, _max), do: "That didn't save. Try again."

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full overflow-y-auto bg-base-100">
      <div class="mx-auto w-full max-w-[560px] px-4 pt-10 pb-[calc(2.5rem+env(safe-area-inset-bottom))]">
        <.form
          for={@form}
          id="setup-goals-form"
          phx-change="change"
          phx-submit="save"
          class="flex flex-col gap-4"
        >
          <h1
            id="setup-goals-question"
            class="text-2xl font-semibold text-base-content"
          >
            What should your team get done first?
          </h1>

          <div id="setup-goals-fields" class="flex flex-col gap-3">
            <input
              :for={{goal, index} <- Enum.with_index(@goals)}
              type="text"
              id={"setup-goal-#{index}"}
              name="setup[goals][]"
              value={goal}
              maxlength="500"
              aria-label={"Goal #{index + 1}"}
              placeholder={if index == 0, do: "e.g. Launch the new site by December"}
              class="block min-h-11 w-full rounded-[var(--radius-field)] border border-edge bg-base-100 px-4 py-2 text-base text-base-content placeholder:text-subtle focus:outline-none focus:ring-2 focus:ring-focus-ring"
            />
          </div>

          <button
            :if={length(@goals) < @max}
            type="button"
            id="setup-goals-add"
            phx-click="add"
            class="self-start rounded-[var(--radius-field)] text-sm font-medium text-base-content hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
          >
            + add another (up to {@max})
          </button>

          <p id="setup-goals-helper" class="text-sm text-subtle">
            {@lead_name} will keep everyone pointed at these and tell you what's in the way.
          </p>

          <p :if={@error} id="setup-goals-error" role="alert" class="text-sm text-error">
            {@error}
          </p>

          <div class="flex items-center justify-end gap-4 pt-2">
            <.link
              id="setup-goals-skip"
              navigate={next_path()}
              class="text-sm text-subtle hover:text-base-content hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
            >
              Skip for now
            </.link>
            <button
              type="submit"
              id="setup-goals-continue"
              class="btn btn-primary min-h-11"
            >
              Continue
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
