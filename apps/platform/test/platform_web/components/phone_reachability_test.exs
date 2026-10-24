defmodule PlatformWeb.Components.PhoneReachabilityTest do
  @moduledoc """
  Every module the pre-redesign app let an actor open stays reachable on a
  phone, and every extension rail item does too (Social read as missing from
  the More sheet).

  "Reachable on a phone" is: a bottom-bar tab, a More-sheet row, or, for the
  admin surfaces the redesign moved, the More sheet's pinned Settings row
  plus the Settings page's Admin sheet. Each case is asserted for real
  Scopes (a root admin and a plain member), and only where
  `Platform.Access.module_access?/3` admits the key, so a module the actor
  may not open is not demanded.

  The sheet is taller than the visible sheet on a phone browser, so a row
  that is present can still be one nobody scrolls to. Extension rows were
  appended after Changelog, at the very end; the second describe pins them
  right after Inbox.

  async: false: flips `:mail_enabled` and `:extensions`.
  """
  use Platform.DataCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Access
  alias Platform.Access.Scope
  alias Platform.TenancyFixtures
  alias PlatformWeb.Components.{IconRail, MoreSheet}

  # The navigable top-level destinations origin/main's rails exposed
  # (`IconRail.destinations/1`'s core entries there), each with how the
  # redesign reaches it on a phone:
  #   {:tab_or_row, key}   a bottom-bar tab or a More-sheet row with that key
  #   {:successor, key}    the page was retired; its successor's row
  #   {:settings, path}    the Settings row, then the Admin sheet row for path
  #   :settings_admin      the Settings row, then any Admin sheet row
  @main_destinations [
    chat: {:tab_or_row, :chat},
    tasks: {:tab_or_row, :tasks},
    inbox: {:tab_or_row, :inbox},
    # /activity was retired by the redesign; ModuleGate gates /changelog on
    # the same `activity` module.
    activity: {:successor, :changelog},
    agents: {:tab_or_row, :agents},
    skills: {:tab_or_row, :skills},
    files: {:tab_or_row, :files},
    context: {:tab_or_row, :context},
    prompts: {:settings, "/admin/prompts"},
    experiments: {:tab_or_row, :experiments},
    meetings: {:tab_or_row, :meetings},
    email: {:tab_or_row, :email},
    admin: :settings_admin
  ]

  defp put_env(key, value) do
    previous = Application.fetch_env(:platform, key)
    Application.put_env(:platform, key, value)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:platform, key, v)
        :error -> Application.delete_env(:platform, key)
      end
    end)
  end

  defp plain_member! do
    n = System.unique_integer([:positive])

    %Platform.Accounts.User{}
    |> Platform.Accounts.User.changeset(%{
      email: "phone-reach-#{n}@example.com",
      name: "Phone Reach #{n}",
      oidc_sub: "phone-reach-#{n}"
    })
    |> Repo.insert!()
    |> TenancyFixtures.member_of_all_orgs!()
  end

  defp keys(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("data-destination")
  end

  defp phone(scope) do
    bar = render_component(&IconRail.bottom_rail/1, access_scope: scope, current_path: "/chat")

    sheet =
      render_component(&MoreSheet.more_sheet/1,
        open: true,
        access_scope: scope,
        current_user: "Phone Reach",
        current_path: "/chat"
      )

    %{
      tabs: keys(bar, "#bottom-nav a[data-destination]"),
      rows: keys(sheet, ".more-sheet-list .more-sheet-row[data-destination]"),
      settings?: keys(sheet, ".sheet-actions [data-destination=settings]") == ["settings"],
      admin_paths: Enum.map(PlatformWeb.SettingsLive.visible_admin_rows(scope), & &1.path)
    }
  end

  defp reachable?(phone, {:tab_or_row, key}),
    do: to_string(key) in (phone.tabs ++ phone.rows)

  defp reachable?(phone, {:successor, key}), do: to_string(key) in phone.rows

  defp reachable?(phone, {:settings, path}), do: phone.settings? and path in phone.admin_paths

  defp reachable?(phone, :settings_admin), do: phone.settings? and phone.admin_paths != []

  # Real Scopes from real memberships. An extension's own migration grants
  # its permission to the built-in admin and member roles (Social's grants
  # `social.use`); the fixture extension ships no migration, so its
  # `fixture.use` is added to the Scope the way that grant would carry it,
  # rather than by writing the shared role cache.
  defp actors do
    for {who, user} <- [root_admin: TenancyFixtures.root_admin!(), member: plain_member!()] do
      scope = Scope.for_user(user)
      {who, %{scope | permissions: Map.put(scope.permissions, "fixture.use", :all)}}
    end
  end

  setup do
    put_env(:mail_enabled, true)
    Platform.FixtureExtension.register()
    :ok
  end

  describe "every module an actor may open is reachable on a phone" do
    test "each destination main exposed, plus every extension rail item" do
      extension_items = Platform.Extensions.rail_items()
      assert extension_items != [], "the fixture extension must contribute a rail item"

      cases =
        @main_destinations ++ Enum.map(extension_items, &{&1.key, {:tab_or_row, &1.key}})

      for {who, scope} <- actors() do
        phone = phone(scope)

        allowed = Enum.filter(cases, fn {key, _how} -> Access.module_access?(scope, key) end)

        # Anti-vacuity: the root admin may open every one of them, so a
        # Scope that admits nothing cannot pass this test.
        if who == :root_admin, do: assert(length(allowed) == length(cases))

        missing = for {key, how} <- allowed, not reachable?(phone, how), do: key

        assert missing == [],
               "#{who} cannot reach #{inspect(missing)} on a phone " <>
                 "(tabs #{inspect(phone.tabs)}, More rows #{inspect(phone.rows)})"
      end
    end
  end

  describe "extension rows sit where the sheet opens, not past the fold" do
    test "every extension row comes right after Inbox, for each actor" do
      ext_keys = Enum.map(Platform.Extensions.rail_items(), &to_string(&1.key))

      for {who, scope} <- actors() do
        rows = phone(scope).rows
        visible_ext = Enum.filter(ext_keys, &(&1 in rows))
        assert visible_ext != [], "#{who} sees no extension row"

        assert Enum.take(rows, 1 + length(visible_ext)) == ["inbox" | visible_ext],
               "#{who}: extension rows must follow Inbox, got #{inspect(rows)}"
      end
    end
  end
end
