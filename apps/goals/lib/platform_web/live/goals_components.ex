defmodule PlatformWeb.GoalsComponents do
  @moduledoc """
  Pieces shared by the Goals screens (task 01a1dfc1, Goals 4/8): the flag
  tile, the privacy chip and number formatting. Class recipes are copied
  from core's shipped components (`PlatformWeb.Components.BriefingRow`'s
  icon tile, `PlatformWeb.Inbox.InboxList`'s 42px disc, the `chip-soft`
  chip in core's app.css); colours come only from their semantic token
  classes.
  """
  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [icon: 1]

  @doc """
  The flag tile. `size` is `:md` (36px, the desktop row) or `:lg` (42px, the
  phone row). A goal with no number to follow gets the muted tile.
  """
  attr :size, :atom, default: :md, values: [:md, :lg]
  attr :muted?, :boolean, default: false

  def flag_tile(assigns) do
    ~H"""
    <span
      aria-hidden="true"
      data-role="goal-tile"
      data-muted={to_string(@muted?)}
      class={[
        "flex shrink-0 items-center justify-center",
        if(@size == :lg, do: "size-[42px] rounded-full", else: "size-9 rounded-xl"),
        if(@muted?, do: "bg-base-300 text-subtle", else: "bg-primary text-primary-content")
      ]}
    >
      <.icon name="hero-flag" class="size-5" />
    </span>
    """
  end

  @doc """
  The privacy chip: "Only you" (neutral), "Shared: {names}" for the owner
  of an opened goal, "Shared by {owner}" for a goal someone else owns
  (both success-tinted).
  """
  attr :privacy, :map, required: true, doc: "`%{label: String, shared?: boolean}`"

  def privacy_chip(assigns) do
    ~H"""
    <span
      data-role="goal-privacy"
      data-shared={to_string(@privacy.shared?)}
      class={[
        "chip-soft max-w-full truncate",
        if(@privacy.shared?, do: "chip-success", else: "chip-neutral")
      ]}
    >
      <.icon :if={!@privacy.shared?} name="hero-lock-closed" class="size-3 shrink-0" />
      <span class="truncate">{@privacy.label}</span>
    </span>
    """
  end

  @doc """
  A number as the page shows it: thousands separators, no trailing decimal
  zeros. Takes a `Decimal` or an integer.

      iex> PlatformWeb.GoalsComponents.format_number(Decimal.new("1250.50"))
      "1,250.5"
  """
  @spec format_number(Decimal.t() | integer()) :: String.t()
  def format_number(n) when is_integer(n), do: format_number(Decimal.new(n))

  def format_number(%Decimal{} = n) do
    text = n |> Decimal.normalize() |> Decimal.to_string(:normal)
    {sign, text} = if String.starts_with?(text, "-"), do: {"-", tail(text)}, else: {"", text}

    case String.split(text, ".", parts: 2) do
      [int] -> sign <> group(int)
      [int, frac] -> sign <> group(int) <> "." <> frac
    end
  end

  defp tail("-" <> rest), do: rest

  defp group(int) do
    int
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end
end
