defmodule PlatformWeb.GoalsRead do
  @moduledoc """
  The short read (task 01a1dfc1, Goals 4/8 stage 3), canvas 01a15ef6 node
  `p` screen `read`: every takeaway of a goal, at
  `/m/goals?goal=<id>&read=<entry id or all>`. A "From:" link on a trying
  card opens it focused on that takeaway (the card carries the 2px focus
  ring, the canvas's `.flash`); "Read more" opens it with `read=all`,
  unfocused. An unknown `read` value shows the view unfocused. Reads come
  from `PlatformWeb.GoalsPage.load/2` (entries of kind `takeaway`).
  """
  use Phoenix.Component

  alias PlatformWeb.GoalsPage

  attr :page, :map, required: true
  attr :focus, :string, default: nil

  def short_read(assigns) do
    assigns = assign(assigns, :goal, assigns.page.card.goal)

    ~H"""
    <div class="mx-auto max-w-3xl p-6" data-role="goal-read" data-goal-id={@goal.id}>
      <.link
        navigate={"/m/goals?goal=" <> @goal.id}
        class="-ml-2 mb-3 inline-flex min-h-11 items-center rounded px-2 font-semibold text-interactive focus-visible-ring"
        data-role="goal-read-back"
      >
        ‹ Back
      </.link>
      <div class="mb-1.5 flex items-center gap-2">
        <span class={GoalsPage.tag_class()}>Short read</span>
      </div>
      <h2 class="text-2xl font-bold text-base-content">What we've learned</h2>
      <p :if={@page.coach} class="mt-1 text-sm text-subtle" data-role="goal-read-by">
        Researched by
        <span
          data-agent-slot={@page.coach.slot}
          class="font-semibold text-(--ag-text)"
        >
          {@page.coach.name}
        </span>
      </p>
      <p :if={@page.takeaways == []} class="mt-4 text-sm text-subtle">Nothing learned yet.</p>
      <article
        :for={entry <- @page.takeaways}
        class={[
          GoalsPage.card_class(),
          "mt-3",
          @focus == entry.id && "ring-2 ring-focus-ring ring-offset-2 ring-offset-base-200"
        ]}
        data-role="goal-read-card"
        data-entry-id={entry.id}
        data-focused={to_string(@focus == entry.id)}
      >
        <h4 class="text-base font-semibold text-base-content">{entry.title}</h4>
        <p :if={entry.body} class="mt-1 text-sm text-base-content">{entry.body}</p>
        <p :if={doing(entry)} class="mt-2 text-sm text-base-content" data-role="goal-read-doing">
          <b>What we're doing about it:</b> {doing(entry)}
        </p>
        <p :if={entry.sources != []} class="mt-2 text-xs text-subtle">
          Sources: {GoalsPage.sources(entry)}
        </p>
      </article>
    </div>
    """
  end

  defp doing(%{details: %{"doing" => d}}) when is_binary(d) and d != "", do: d
  defp doing(_entry), do: nil
end
