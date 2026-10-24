defmodule PlatformWeb.AvatarComponents do
  @moduledoc """
  Shared avatar rendering for human and agent identities.

  Two thin public components — `human_avatar/1` and `agent_avatar/1` — sit over
  one private renderer. They are deliberately NOT interchangeable, and the two
  differences between them are load-bearing rather than cosmetic:

    * `human_avatar/1` renders up to TWO initials over the deterministic
      `avatar-fallback-N` palette, seeded from a stable value such as user id,
      email, or OIDC subject, and stamps `data-avatar-kind="human"`.
    * `agent_avatar/1` renders exactly ONE initial — matching what agents have
      always shown via `PlatformWeb.Chat.PresenceHooks.avatar_initial/2` — over
      the flat `bg-base-300 text-primary` circle agents have always used, and
      stamps `data-avatar-kind="agent"`.

  An agent's fallback circle deliberately does NOT consult the human phash
  palette, and it deliberately does NOT consult `agents.color`. The agent colour
  is the accent ring the caller draws around the avatar (`.msg-agent-avatar` in
  `app.css`), not the circle itself. An imageless agent must look exactly as it
  did before this module grew a second component.

  Both components render a stored avatar image identically when one is present,
  and both stamp `data-avatar-mode` as `"image"` or `"fallback"`. A blank-string
  `avatar_url` is normalised to no avatar on both paths.
  """

  use Phoenix.Component

  @size_classes %{
    "xs" => "size-5 text-[10px]",
    "sm" => "size-6 text-xs",
    "md" => "size-8 text-sm",
    "lg" => "size-10 text-base",
    "xl" => "size-[72px] text-[26px]"
  }

  @circle_base "rounded-full overflow-hidden flex items-center justify-center"

  @doc """
  Avatar for a human identity: up to two initials over the seeded fallback
  palette, or the stored avatar image when one is set.
  """
  attr(:name, :string, required: true)
  attr(:avatar_url, :string, default: nil)
  attr(:seed, :any, default: nil)
  attr(:size, :string, default: "md", values: ["xs", "sm", "md", "lg", "xl"])
  attr(:class, :any, default: nil)
  attr(:title, :string, default: nil)
  attr(:rest, :global)

  def human_avatar(assigns) do
    avatar_url = normalize_optional_string(assigns.avatar_url)
    seed = assigns.seed || assigns.name || "user"
    size_class = Map.get(@size_classes, assigns.size, @size_classes["md"])
    palette_class = fallback_palette_class(seed)

    assigns
    |> assign(:avatar_url, avatar_url)
    |> assign(:seed, seed)
    |> assign(:kind, "human")
    |> assign(:palette_class, palette_class)
    |> assign(:wrapper_class, [
      "avatar human-avatar rounded-full select-none",
      !avatar_url && "avatar-placeholder"
    ])
    |> assign(:circle_class, [
      "#{@circle_base} font-semibold uppercase tracking-wide",
      size_class,
      !avatar_url && ["avatar-fallback", palette_class]
    ])
    |> assign(:initials, initials(assigns.name, 2))
    |> assign_new(:title, fn -> assigns.name end)
    |> render_avatar()
  end

  @doc """
  Avatar for an agent identity: exactly ONE initial over the flat
  `bg-base-300 text-primary` circle, or the stored avatar image when one is set.

  Takes no `seed` — agents never render the seeded human palette, so accepting
  one would only invite callers to expect a colour that never arrives.

  `fallback_class` lets a caller override the circle's fallback-mode colour
  classes (default `"bg-base-300 text-primary"`) — e.g. the activity feed
  tints an imageless agent's circle by action kind. It is a seam for the
  CIRCLE only: `class` still targets the outer wrapper (see `render_avatar/1`
  below), and `fallback_class` is ignored entirely once `avatar_url` is set,
  so an agent with an uploaded image is never affected by it.
  """
  attr(:name, :string, required: true)
  attr(:avatar_url, :string, default: nil)
  attr(:size, :string, default: "md", values: ["xs", "sm", "md", "lg", "xl"])
  attr(:class, :any, default: nil)
  attr(:fallback_class, :any, default: "bg-base-300 text-primary")
  attr(:title, :string, default: nil)
  attr(:rest, :global)

  def agent_avatar(assigns) do
    avatar_url = normalize_optional_string(assigns.avatar_url)
    size_class = Map.get(@size_classes, assigns.size, @size_classes["md"])

    assigns
    |> assign(:avatar_url, avatar_url)
    |> assign(:kind, "agent")
    |> assign(:palette_class, nil)
    |> assign(:wrapper_class, [
      "avatar agent-avatar shrink-0 rounded-full select-none",
      !avatar_url && "avatar-placeholder"
    ])
    |> assign(:circle_class, [
      "#{@circle_base} font-bold uppercase tracking-wide",
      size_class,
      !avatar_url && assigns.fallback_class
    ])
    |> assign(:initials, initials(assigns.name, 1))
    |> assign_new(:title, fn -> assigns.name end)
    |> render_avatar()
  end

  # Shared body for both public components. Everything that differs between a
  # human and an agent has already been decided by the caller and handed over as
  # an assign; nothing in here branches on kind.
  #
  # `avatar-placeholder` on the FALLBACK wrapper is load-bearing, and measured:
  # without it the initial rendered in the top-left corner of the circle, half
  # clipped by its own `overflow: hidden`. `avatar` is a DaisyUI component, and
  # DaisyUI ships `.avatar > div { display: block }` at specificity (0,1,1) —
  # which beats the `flex` utility (0,1,0), so `items-center justify-center`
  # never applied and the span laid out as ordinary inline text. `.avatar-
  # placeholder > div { display: flex; align-items: center; justify-content:
  # center }` is DaisyUI's own answer for an avatar whose child is initials
  # rather than an image; it has equal specificity and is emitted later, so it
  # wins on source order without an `!important`. It is applied ONLY in fallback
  # mode: with an image, `display: block` on the child is correct and DaisyUI's
  # `.avatar img { height: 100%; width: 100%; object-fit: cover }` does the work.
  #
  # The OUTER wrapper carries `rounded-full` even though it paints nothing. It
  # is the element a caller's `class` lands on, and the agent accent ring is a
  # `box-shadow` (`.msg-agent-avatar` in app.css) — a box-shadow on a square box
  # draws a square ring. Before the split, `chat_message.ex` put that class
  # straight on the single rounded circle; now there are two elements and only
  # the outer one is reachable from outside. Without this the ring would render
  # as a rectangle the moment a call site passes `class="msg-agent-avatar"`.
  defp render_avatar(assigns) do
    ~H"""
    <div
      class={[@wrapper_class, @class]}
      title={@title}
      data-avatar-kind={@kind}
      data-avatar-mode={if @avatar_url, do: "image", else: "fallback"}
      data-avatar-palette={if @avatar_url, do: nil, else: @palette_class}
      {@rest}
    >
      <div class={@circle_class}>
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

  defp initials(nil, _count), do: "U"

  defp initials(name, count) when is_binary(name) and is_integer(count) do
    name
    |> String.trim()
    |> case do
      "" ->
        "U"

      trimmed ->
        trimmed
        |> String.split(~r/\s+/, trim: true)
        |> Enum.take(count)
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

  defp initials(value, count), do: value |> to_string() |> initials(count)

  @doc """
  The `avatar-fallback-N` class for a seed. The index comes from
  `Platform.Avatars.fallback_tone/1`, the same function the push notification
  reads for `author_avatar_tone` (task 01a12773), so the browser and the
  native apps colour a person's letter disc identically.
  """
  @spec fallback_palette_class(term()) :: String.t()
  def fallback_palette_class(seed) do
    "avatar-fallback-#{Platform.Avatars.fallback_tone(seed)}"
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
