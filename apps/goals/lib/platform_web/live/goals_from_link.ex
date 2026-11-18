defmodule PlatformWeb.GoalsFromLink do
  @moduledoc """
  The "From: {takeaway title}" link (canvas 01a15ef6 node `p`,
  `button.lnk.from`): an entry that cites a takeaway links to the short read
  with that takeaway focused. Lifted unchanged from member 4's "What we're
  trying" card (task 01a1dfc1, Goals 4/8) so the Notebook row (task
  01a1dfc1-7625, Goals 5/8 stage 4) uses the same link, not a second one.

  `page` is `PlatformWeb.GoalsPage.load/2`'s map; the title is read from
  its own takeaways (`page.takeaway_titles`). An entry with no
  `takeaway_id`, or citing a takeaway the page does not list, draws nothing.
  """
  use Phoenix.Component

  alias PlatformWeb.GoalsPage

  attr :page, :map, required: true
  attr :entry, :map, required: true
  attr :role, :string, required: true

  def from_link(assigns) do
    id = assigns.entry.takeaway_id
    assigns = assign(assigns, id: id, title: id && assigns.page.takeaway_titles[id])

    ~H"""
    <.link
      :if={@title}
      navigate={GoalsPage.read_href(@page.card.goal, @id)}
      class={[GoalsPage.link_class(), "mt-1 inline-block text-sm"]}
      data-role={@role}
    >
      From: {@title}
    </.link>
    """
  end
end
