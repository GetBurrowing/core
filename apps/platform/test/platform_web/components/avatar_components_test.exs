defmodule PlatformWeb.AvatarComponentsTest do
  @moduledoc """
  Task 01a00122-553c ("Give agents a face"), stage 3.

  `PlatformWeb.AvatarComponents` used to expose a single `human_avatar/1` that
  agent code was being tempted to reuse. It now exposes two thin components over
  one private renderer, and the whole point of the split is that the two are NOT
  interchangeable. These tests pin the differences that make that true:

    * an agent renders exactly ONE initial (what `PresenceHooks.avatar_initial/2`
      has always produced), a human up to TWO;
    * an agent stamps `data-avatar-kind="agent"`, a human `"human"`;
    * an agent's fallback circle is the flat `bg-base-300 text-primary` it has
      always been, NOT the seeded `avatar-fallback-N` human palette.

  The letter-count assertions read the rendered text of the fallback span rather
  than merely asserting the substring is present, so widening the agent path to
  two initials turns them red.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.AvatarComponents

  # Text content of the fallback initials span, or nil when the avatar rendered
  # an image instead. Deliberately reads the letters themselves — an assertion
  # on `=~ "A"` would survive the component rendering "AL".
  defp fallback_initials(html) do
    case Regex.run(~r{<span[^>]*aria-hidden="true"[^>]*>\s*([^<]*?)\s*</span>}, html) do
      [_, initials] -> initials
      nil -> nil
    end
  end

  describe "agent_avatar/1 with a stored image" do
    test "renders the img and stamps image mode under the agent kind" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.agent_avatar name="Helga Vantar" avatar_url="/agents/abc/avatar?v=GKHEI" />
        """)

      assert html =~ ~s(data-avatar-kind="agent")
      assert html =~ ~s(data-avatar-mode="image")
      assert html =~ ~s(src="/agents/abc/avatar?v=GKHEI")
      assert html =~ "object-cover"
      assert html =~ ~s(loading="lazy")

      # The image replaces the circle's letters entirely.
      assert fallback_initials(html) == nil
      refute html =~ "data-avatar-palette"
    end

    test "the cache-busting token stage 2 appends is passed through untouched" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.agent_avatar name="Helga" avatar_url="/agents/abc/avatar?v=GKHEI" />
        """)

      assert html =~ "avatar?v=GKHEI"
    end
  end

  describe "agent_avatar/1 without an image" do
    test "renders exactly ONE initial in fallback mode" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.agent_avatar name="Ada Lovelace" />
        """)

      assert html =~ ~s(data-avatar-kind="agent")
      assert html =~ ~s(data-avatar-mode="fallback")

      initials = fallback_initials(html)

      assert initials == "A",
             "agent avatars show a single initial (PresenceHooks.avatar_initial/2 " <>
               "behaviour); rendered #{inspect(initials)} instead"

      assert String.length(initials) == 1,
             "expected exactly one letter for an agent fallback, got " <>
               "#{String.length(initials)} (#{inspect(initials)})"

      refute html =~ "<img"
    end

    test "keeps today's flat agent circle and never the seeded human palette" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.agent_avatar name="Ada Lovelace" />
        """)

      assert html =~ "bg-base-300"
      assert html =~ "text-primary"
      refute html =~ "avatar-fallback"
      refute html =~ "data-avatar-palette"
    end

    test "a blank-string avatar_url behaves exactly as nil" do
      assigns = %{}

      blank =
        rendered_to_string(~H"""
        <.agent_avatar name="Ada Lovelace" avatar_url="   " />
        """)

      nil_url =
        rendered_to_string(~H"""
        <.agent_avatar name="Ada Lovelace" avatar_url={nil} />
        """)

      assert blank =~ ~s(data-avatar-mode="fallback")
      refute blank =~ "<img"
      assert fallback_initials(blank) == "A"
      assert blank == nil_url
    end

    test "falls back to U for a nameless agent" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.agent_avatar name="   " />
        """)

      assert fallback_initials(html) == "U"
    end

    test "honours the shared size scale" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.agent_avatar name="Ada" size="xs" />
        """)

      assert html =~ "size-5"
    end
  end

  describe "human_avatar/1 is unchanged by the split" do
    test "still renders TWO initials under the human kind" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.human_avatar name="Ada Lovelace" seed="user-1" />
        """)

      assert html =~ ~s(data-avatar-kind="human")
      assert html =~ ~s(data-avatar-mode="fallback")
      assert html =~ "human-avatar"

      initials = fallback_initials(html)

      assert initials == "AL",
             "human avatars show up to two initials; rendered #{inspect(initials)}"

      assert String.length(initials) == 2
    end

    test "still renders the seeded fallback palette class" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.human_avatar name="Ada Lovelace" seed="user-1" />
        """)

      expected = "avatar-fallback-#{:erlang.phash2("user-1", 8)}"

      assert html =~ "avatar-fallback"
      assert html =~ expected
      assert html =~ ~s(data-avatar-palette="#{expected}")
    end

    test "still renders an image when one is set" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.human_avatar name="Ada Lovelace" avatar_url="/uploads/ada.png" />
        """)

      assert html =~ ~s(data-avatar-kind="human")
      assert html =~ ~s(data-avatar-mode="image")
      assert html =~ ~s(src="/uploads/ada.png")
      refute html =~ "data-avatar-palette"
    end

    test "a blank-string avatar_url still behaves as nil" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.human_avatar name="Ada Lovelace" avatar_url="" />
        """)

      assert html =~ ~s(data-avatar-mode="fallback")
      refute html =~ "<img"
    end
  end

  describe "the wrapper a caller's class lands on" do
    # The agent accent ring is a box-shadow (.msg-agent-avatar). A caller's
    # `class` lands on the outer wrapper, not on the circle, so the wrapper has
    # to be round or the ring draws as a rectangle. Stage 5 passes exactly that
    # class from chat_message.ex.
    test "is rounded on both kinds so a caller-supplied ring stays circular" do
      assigns = %{}

      agent =
        rendered_to_string(~H"""
        <.agent_avatar name="Ada Lovelace" class="msg-agent-avatar" />
        """)

      human =
        rendered_to_string(~H"""
        <.human_avatar name="Ada Lovelace" class="ring-2" />
        """)

      assert [_, agent_wrapper] = Regex.run(~r/<div class="([^"]*)"/, agent)
      assert [_, human_wrapper] = Regex.run(~r/<div class="([^"]*)"/, human)

      assert agent_wrapper =~ "rounded-full"
      assert agent_wrapper =~ "msg-agent-avatar"
      assert human_wrapper =~ "rounded-full"
      assert human_wrapper =~ "ring-2"
    end
  end

  describe "the two kinds differ where it matters" do
    test "same name, same absent image, different letters and different kind" do
      assigns = %{}

      human =
        rendered_to_string(~H"""
        <.human_avatar name="Ada Lovelace" />
        """)

      agent =
        rendered_to_string(~H"""
        <.agent_avatar name="Ada Lovelace" />
        """)

      assert fallback_initials(human) == "AL"
      assert fallback_initials(agent) == "A"
      assert human =~ ~s(data-avatar-kind="human")
      assert agent =~ ~s(data-avatar-kind="agent")
    end
  end
end
