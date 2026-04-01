defmodule PlatformWeb.AvatarComponents do
  @moduledoc """
  Shared avatar rendering for human identities.

  Renders either a stored avatar image or a deterministic fallback palette based
  on a stable seed such as user id, email, or OIDC subject.
  """

  use Phoenix.Component

  @size_classes %{
    "xs" => "size-5 text-[10px]",
    "sm" => "size-6 text-xs",
    "md" => "size-8 text-sm",
    "lg" => "size-10 text-base"
  }

  @palette_size 8

  attr(:name, :string, required: true)
  attr(:avatar_url, :string, default: nil)
  attr(:seed, :any, default: nil)
  attr(:size, :string, default: "md", values: ["xs", "sm", "md", "lg"])
  attr(:class, :any, default: nil)
  attr(:title, :string, default: nil)
  attr(:rest, :global)

  def human_avatar(assigns) do
    avatar_url = normalize_optional_string(assigns.avatar_url)
    seed = assigns.seed || assigns.name || "user"
    size_class = Map.get(@size_classes, assigns.size, @size_classes["md"])
    palette_class = fallback_palette_class(seed)

    assigns =
      assigns
      |> assign(:avatar_url, avatar_url)
      |> assign(:seed, seed)
      |> assign(:size_class, size_class)
      |> assign(:palette_class, palette_class)
      |> assign(:initials, initials(assigns.name))
      |> assign_new(:title, fn -> assigns.name end)

    ~H"""
    <div
      class={["avatar human-avatar select-none", @class]}
      title={@title}
      data-avatar-kind="human"
      data-avatar-mode={if @avatar_url, do: "image", else: "fallback"}
      data-avatar-palette={if @avatar_url, do: nil, else: @palette_class}
      {@rest}
    >
      <div class={[
        "rounded-full overflow-hidden flex items-center justify-center font-semibold uppercase tracking-wide",
        @size_class,
        !@avatar_url && ["avatar-fallback", @palette_class]
      ]}>
        <img
          :if={@avatar_url}
          src={@avatar_url}
          alt={@name}
          class="size-full object-cover"
          loading="lazy"
        />
        <span :if={!@avatar_url} aria-hidden="true">{@initials}</span>
      </div>
    </div>
    """
  end

  defp initials(nil), do: "U"

  defp initials(name) when is_binary(name) do
    name
    |> String.trim()
    |> case do
      "" ->
        "U"

      trimmed ->
        trimmed
        |> String.split(~r/\s+/, trim: true)
        |> Enum.take(2)
        |> Enum.map(fn part ->
          part
          |> String.first()
          |> case do
            nil -> nil
            ch -> String.upcase(ch)
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.join()
        |> case do
          "" -> "U"
          initials -> initials
        end
    end
  end

  defp initials(value), do: value |> to_string() |> initials()

  defp fallback_palette_class(seed) do
    "avatar-fallback-#{:erlang.phash2(to_string(seed), @palette_size)}"
  end

  defp normalize_optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil
end
