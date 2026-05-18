defmodule PlatformWeb.Components.MoreSheetTest do
  @moduledoc """
  Tests for the More-sheet refactor (task 019e389b Stage 3).

  The sheet's destinations now come from
  `PlatformWeb.Components.IconRail.destinations/1` — the same single source
  of truth that drives the desktop icon-rail and the mobile bottom-rail.
  Asserts:

    * Working-cluster destinations render (Skills / Context / Memory /
      Prompts / Meetings).
    * Admin section is gated on `is_fabrikam_user` and is DOM-absent (not just
      visually hidden) for non-Fabrikam users.
    * Hero icons render via the data-driven loop.
  """

  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.MoreSheet

  defp render_more_sheet(assigns) do
    assigns =
      Map.merge(
        %{
          open: true,
          is_fabrikam_user: false,
          current_user: nil
        },
        assigns
      )

    rendered_to_string(~H"""
    <.more_sheet
      open={@open}
      is_fabrikam_user={@is_fabrikam_user}
      current_user={@current_user}
    />
    """)
  end

  describe "working cluster destinations" do
    test "renders every working-cluster destination from IconRail.destinations/1" do
      html = render_more_sheet(%{})

      # Working cluster keys per IconRail.canonical_destinations.
      # (Memory tabs under Context per Marlowe 2026-05-18; not its own destination.)
      for key <- ["skills", "context", "prompts", "meetings"] do
        assert html =~ ~s(data-destination="#{key}"),
               "expected data-destination=#{inspect(key)} in the More sheet"
      end
    end

    test "renders the Working section label" do
      html = render_more_sheet(%{})
      assert html =~ ">Working<"
    end
  end

  describe "admin gate" do
    test "renders the Admin section when is_fabrikam_user is true" do
      html = render_more_sheet(%{is_fabrikam_user: true})
      assert html =~ ">Admin<"
      assert html =~ ~s(data-destination="admin")
    end

    test "omits the Admin section entirely when is_fabrikam_user is false" do
      html = render_more_sheet(%{is_fabrikam_user: false})
      refute html =~ ">Admin<"
      refute html =~ ~s(data-destination="admin")
    end
  end

  describe "hero icons" do
    test "renders a hero icon class for each visible destination" do
      html = render_more_sheet(%{is_fabrikam_user: true})

      # Spot-check a working-cluster hero + the admin hero — full coverage
      # is in IconRailTest.
      assert html =~ "hero-book-open"
      assert html =~ "hero-cog-6-tooth"
    end
  end

  describe "profile row" do
    test "renders the profile row when current_user is present" do
      html = render_more_sheet(%{current_user: %{name: "Marlowe"}})
      assert html =~ "Marlowe"
      assert html =~ "Sign out"
    end

    test "omits the profile row when current_user is nil" do
      html = render_more_sheet(%{current_user: nil})
      refute html =~ "Sign out"
    end
  end
end
