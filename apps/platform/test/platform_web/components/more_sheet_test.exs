defmodule PlatformWeb.Components.MoreSheetTest do
  @moduledoc """
  Tests for the More-sheet refactor (task 019e389b Stage 3).

  The sheet's destinations now come from
  `PlatformWeb.Components.IconRail.destinations/1` — the same single source
  of truth that drives the desktop icon-rail and the mobile bottom-rail.
  Asserts:

    * Working-cluster destinations render (Skills / Context / Memory /
      Prompts / Meetings).
    * Admin section is gated on `root_user` and is DOM-absent (not just
      visually hidden) for non-Acme users.
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
          root_user: false,
          current_user: nil
        },
        assigns
      )

    rendered_to_string(~H"""
    <.more_sheet
      open={@open}
      root_user={@root_user}
      current_user={@current_user}
    />
    """)
  end

  describe "working cluster destinations" do
    test "renders member-visible working-cluster destinations for a non-acme user" do
      html = render_more_sheet(%{})

      # Working cluster keys visible to members per IconRail.canonical_destinations.
      # (Memory tabs under Context per Marlowe 2026-05-18; not its own destination.)
      # Prompts is root_only?:true as of 2026-05-20 — visible only to admins;
      # see acme-only assertion in the next test.
      for key <- ["skills", "context", "meetings"] do
        assert html =~ ~s(data-destination="#{key}"),
               "expected data-destination=#{inspect(key)} in the member-view More sheet"
      end

      refute html =~ ~s(data-destination="prompts")
    end

    test "renders all working-cluster destinations including Prompts for a acme user" do
      html = render_more_sheet(%{root_user: true})

      for key <- ["skills", "context", "prompts", "meetings"] do
        assert html =~ ~s(data-destination="#{key}"),
               "expected data-destination=#{inspect(key)} in the acme-view More sheet"
      end
    end

    test "renders the Working section label" do
      html = render_more_sheet(%{})
      assert html =~ ">Working<"
    end
  end

  describe "admin gate" do
    test "renders the Admin section when root_user is true" do
      html = render_more_sheet(%{root_user: true})
      assert html =~ ">Admin<"
      assert html =~ ~s(data-destination="admin")
    end

    test "omits the Admin section entirely when root_user is false" do
      html = render_more_sheet(%{root_user: false})
      refute html =~ ">Admin<"
      refute html =~ ~s(data-destination="admin")
    end
  end

  describe "hero icons" do
    test "renders a hero icon class for each visible destination" do
      html = render_more_sheet(%{root_user: true})

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

defmodule PlatformWeb.Components.MoreSheetMailFlagTest do
  @moduledoc """
  The More sheet reads `IconRail.destinations/1`, so the Email module's flag
  (task 01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 4) reaches it from the one
  place: flag off, no Email row; flag on, an Email row under Working.

  async: false — flips `:mail_enabled`.
  """
  use ExUnit.Case, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.MoreSheet

  defp with_mail(enabled) do
    previous = Application.fetch_env(:platform, :mail_enabled)
    Application.put_env(:platform, :mail_enabled, enabled)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:platform, :mail_enabled, value)
        :error -> Application.delete_env(:platform, :mail_enabled)
      end
    end)
  end

  defp render_sheet do
    assigns = %{}

    rendered_to_string(~H"""
    <.more_sheet open={true} root_user={false} current_user={nil} />
    """)
  end

  test "flag off: no Email row" do
    with_mail(false)
    html = render_sheet()
    assert html =~ ~s(data-destination="meetings")
    refute html =~ ~s(data-destination="email")
  end

  test "flag on: one Email row, in the Working section" do
    with_mail(true)
    html = render_sheet()
    doc = LazyHTML.from_fragment(html)
    assert doc |> LazyHTML.query(~s([data-destination="email"])) |> Enum.count() == 1

    {working_at, _} = :binary.match(html, ">Working<")
    {email_at, _} = :binary.match(html, ~s(data-destination="email"))
    assert email_at > working_at
  end
end
