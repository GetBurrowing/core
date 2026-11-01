defmodule PlatformWeb.FirstRunLive do
  @moduledoc """
  `/start`: the first-run "What do you want to do?" box (task 01a19554-fd07,
  stage 2), after design-direction canvas 01a19555-f352-7000-b536-4cf47e58db93
  (revision 1).

  A new member types a goal; `Platform.Onboarding.FirstRunGoal.submit/3`
  posts it into their DM with the Burrow agent, and the member lands in that
  DM with an info flash. The page lives in the normal app shell, so the
  sidebar stays visible.

  ## Who sees it

  Only a member `FirstRunGoal.pending?/1` answers true for. Anyone else
  (submitted, skipped, backfilled `"existing"`, external) who opens `/start`
  is sent to `/chat`.

  ## Events

    * `"change"` keeps `@goal` in step with the field.
    * `"fill"` (a chip) sets `@goal` and pushes `first_run:fill` so the
      `FirstRunGoal` hook writes the text into the field and focuses it. It
      never submits: the member edits the goal first.
    * `"submit"` hands off. `:no_agent` and any other error keep the goal and
      show an inline line; blank is a no-op.
    * `"skip"` records the dismissal and goes to `/chat`.

  ## Tokens

  `primary` / `primary-content` appear only on Send; the field's focus ring
  is `ring-focus-ring` (`--focus-ring`). No other element uses primary.

  ## Declared deviations from the canvas

    * Chip 3 is "Turn my to-do list into tasks", not "Catch me up on what I
      missed": Burrow is in none of the member's spaces, so it cannot catch
      them up (see `FirstRunGoal`).
    * The "Handed off" typing indicator is Burrow's own; this view does not
      fake one.
    * The canvas's "neutral" slot for the placeholder, the helper line and
      "Skip for now" is painted with `text-subtle`, this codebase's AA-tuned
      secondary-text token. `--color-neutral` is daisyUI's dark fill colour,
      and as text on base-100 in the dark theme it reads at roughly 3:1. Placeholders
      are pinned to `placeholder:text-subtle` by
      `Platform.Design.PlaceholderContrastTest`.
  """
  use PlatformWeb, :live_view

  alias Platform.Onboarding.FirstRunGoal

  @info "Burrow is on it. This conversation stays in your sidebar."

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user_record]

    if FirstRunGoal.pending?(user) do
      {:ok,
       socket
       |> assign(:page_title, "Get started")
       |> assign(:goal, "")
       |> assign(:notice, nil)
       |> assign(:examples, FirstRunGoal.example_goals())}
    else
      {:ok, push_navigate(socket, to: ~p"/chat")}
    end
  end

  @impl true
  def handle_event("change", params, socket) do
    {:noreply, assign(socket, :goal, goal_param(params))}
  end

  def handle_event("fill", %{"goal" => goal}, socket) when is_binary(goal) do
    {:noreply,
     socket
     |> assign(:goal, goal)
     |> assign(:notice, nil)
     |> push_event("first_run:fill", %{goal: goal})}
  end

  def handle_event("submit", params, socket) do
    goal = goal_param(params, socket.assigns.goal)
    socket = assign(socket, :goal, goal)

    case FirstRunGoal.submit(socket.assigns.current_user_record, goal) do
      {:ok, space, _msg} ->
        {:noreply,
         socket
         |> put_flash(:info, @info)
         |> push_navigate(to: ~p"/chat/#{PlatformWeb.ChatLive.space_nav_target(space)}")}

      {:error, :blank} ->
        {:noreply, socket}

      {:error, :no_agent} ->
        {:noreply, assign(socket, :notice, :no_agent)}

      {:error, _other} ->
        {:noreply, assign(socket, :notice, :error)}
    end
  end

  def handle_event("skip", _params, socket) do
    FirstRunGoal.skip(socket.assigns.current_user_record)
    {:noreply, push_navigate(socket, to: ~p"/chat")}
  end

  defp goal_param(params, default \\ "")
  defp goal_param(%{"goal" => goal}, _default) when is_binary(goal), do: goal
  defp goal_param(_params, default), do: default

  @impl true
  def render(assigns) do
    ~H"""
    <div
      data-role="first-run"
      class="flex min-h-full w-full justify-center bg-base-100 px-4 py-10 md:items-center md:py-16"
    >
      <form
        id="first-run-form"
        phx-change="change"
        phx-submit="submit"
        class="flex w-full max-w-[40rem] flex-col gap-3"
      >
        <label
          for="first-run-input"
          data-role="first-run-question"
          class="text-2xl font-semibold text-base-content md:text-3xl"
        >
          What do you want to do?
        </label>
        <p id="first-run-helper" data-role="first-run-helper" class="text-sm text-subtle">
          Describe a goal in your own words. Burrow will take it from there.
        </p>

        <div class="relative mt-2 rounded-[var(--radius-box)] border border-edge bg-base-100 focus-within:ring-2 focus-within:ring-focus-ring">
          <textarea
            id="first-run-input"
            name="goal"
            rows="3"
            data-role="first-run-input"
            phx-hook="FirstRunGoal"
            aria-describedby="first-run-helper"
            placeholder="e.g. Plan our team's work for this week"
            style="field-sizing: content"
            class="block max-h-[50vh] min-h-[7.5rem] w-full resize-none rounded-[var(--radius-box)] bg-transparent px-4 pb-14 pt-4 text-lg text-base-content placeholder:text-subtle focus:outline-none"
          >{@goal}</textarea>
          <button
            type="submit"
            data-role="first-run-send"
            disabled={String.trim(@goal) == ""}
            class="absolute bottom-3 right-3 inline-flex items-center gap-1.5 rounded-[var(--radius-field)] bg-primary px-3 py-1.5 text-sm font-medium text-primary-content disabled:cursor-not-allowed disabled:opacity-50"
          >
            <span
              class="loading loading-spinner loading-xs hidden phx-submit-loading:inline-block"
              aria-hidden="true"
            >
            </span>
            <span>Send</span>
            <span class="hero-arrow-right size-4 phx-submit-loading:hidden" aria-hidden="true"></span>
          </button>
        </div>

        <p
          :if={@notice == :error}
          data-role="first-run-error"
          role="alert"
          class="text-sm text-error"
        >
          That didn't send. Try again.
        </p>
        <p
          :if={@notice == :no_agent}
          data-role="first-run-no-agent"
          role="status"
          class="rounded-[var(--radius-field)] bg-base-200 px-3 py-2 text-sm text-base-content"
        >
          Burrow isn't set up on this workspace yet. Your admin can connect it.
        </p>

        <div class="flex flex-wrap gap-2">
          <button
            :for={example <- @examples}
            type="button"
            phx-click="fill"
            phx-value-goal={example}
            data-role="first-run-chip"
            class="rounded-full bg-base-200 px-3 py-1.5 text-sm font-medium text-base-content hover:bg-base-300 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
          >
            {example}
          </button>
        </div>

        <div class="flex justify-center pt-6">
          <button
            type="button"
            phx-click="skip"
            data-role="first-run-skip"
            class="text-sm text-subtle hover:text-base-content hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
          >
            Skip for now
          </button>
        </div>
      </form>
    </div>
    """
  end
end
