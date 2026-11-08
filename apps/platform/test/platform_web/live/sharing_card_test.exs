defmodule PlatformWeb.SharingCardTest do
  @moduledoc """
  The "Sharing with Burrow" card (task 01a1b678 stage 5): Settings → Help
  and the setup disclosure on `/setup/connect-ai`.

  Mutants these name:

    * gate the card on `@feedback_enabled` → "renders with feedback disabled";
    * drop `Sharing.admin?/1` from `SharingCard.set/2` → "a forged
      set_sharing from a member changes nothing";
    * render the switch editable for everyone → "a member sees every switch
      read-only";
    * a hand-written event list in the panel → "the panel lists exactly
      UsageEvents.events()";
    * a hand-written row list → "one row per registry entry".
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Platform.AsyncAssertions

  alias Platform.AgentHost.{FakeHost, Reconciler}
  alias Platform.Audit.Event
  alias Platform.Repo
  alias Platform.Sharing
  alias Platform.Sharing.UsageEvents
  alias Platform.VaultFixtures

  setup do
    previous = Application.get_env(:platform, :feedback_policy)
    on_exit(fn -> Application.put_env(:platform, :feedback_policy, previous) end)
    :ok
  end

  defp authed(user), do: build_conn() |> init_test_session(current_user_id: user.id)

  defp all_on! do
    for key <- Sharing.keys(), do: {:ok, _} = Sharing.set(key, true, :system)
    :ok
  end

  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp attrs(view, selector, attr) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(attr)
  end

  defp switch_audits(key) do
    Repo.all(
      from(e in Event,
        where: e.event_type == "platform.sharing.switch_set",
        where: fragment("?->>'key' = ?", e.metadata, ^Atom.to_string(key))
      )
    )
  end

  describe "Settings → Help" do
    test "the card renders with feedback disabled; only Send feedback is gated" do
      Application.put_env(:platform, :feedback_policy, "disabled")
      {:ok, view, _html} = live(authed(VaultFixtures.non_admin!()), "/settings")

      assert has_element?(view, "[data-role=settings-help-label]", "Help")
      refute has_element?(view, "[data-role=settings-feedback]")
      assert has_element?(view, "#settings-sharing[data-role=sharing-card]")
      assert has_element?(view, "[data-role=sharing-heading]", "Sharing with Burrow")

      assert has_element?(
               view,
               "[data-role=sharing-subhead]",
               "Helps us decide what to build next. Each part can be turned off."
             )
    end

    test "one row per registry entry, in order, with the registry's copy" do
      {:ok, view, _html} = live(authed(VaultFixtures.admin!()), "/settings")

      assert attrs(view, "#settings-sharing [data-role=sharing-row]", "data-key") ==
               Enum.map(Sharing.keys(), &Atom.to_string/1)

      for entry <- Sharing.registry() do
        row = "#settings-sharing [data-role=sharing-row][data-key=#{entry.key}]"
        assert has_element?(view, row, entry.title)
        assert has_element?(view, row <> " [data-role=sharing-description]", entry.description)

        assert has_element?(
                 view,
                 row <> " [data-role=sharing-exactly-link]",
                 "Exactly what's sent"
               )
      end
    end

    test "the panel lists exactly UsageEvents.events(), the never-sent list and the install id line" do
      {:ok, view, _html} = live(authed(VaultFixtures.non_admin!()), "/settings")

      # Collapsed by default.
      refute has_element?(view, "#settings-sharing-exactly[open]")

      assert texts(view, "#settings-sharing [data-role=sharing-event]") == UsageEvents.events()
      assert has_element?(view, "#settings-sharing [data-role=sharing-event].font-mono")

      assert has_element?(
               view,
               "#settings-sharing [data-role=sharing-never-sent]",
               Enum.join(Sharing.never_sent(), " · ")
             )

      assert has_element?(
               view,
               "#settings-sharing [data-role=sharing-install-id-line]",
               "Your install id is random and isn't linked to your account."
             )

      for entry <- Sharing.registry(), line <- entry.exactly_sent do
        assert has_element?(
                 view,
                 "#settings-sharing [data-role=sharing-sent-entry][data-key=#{entry.key}]",
                 line
               )
      end
    end

    test "an admin's switches are editable and each toggle is stored and audited" do
      all_on!()
      admin = VaultFixtures.admin!()
      {:ok, view, _html} = live(authed(admin), "/settings")

      for key <- Sharing.keys() do
        assert has_element?(
                 view,
                 "#settings-sharing [data-role=sharing-switch][data-key=#{key}][aria-checked=true][data-readonly=false]"
               )
      end

      refute has_element?(view, "#settings-sharing [data-role=sharing-readonly-note]")

      view
      |> element("#settings-sharing [data-role=sharing-switch][data-key=usage_counts]")
      |> render_click()

      refute Sharing.enabled?(:usage_counts)

      assert has_element?(
               view,
               "#settings-sharing [data-role=sharing-switch][data-key=usage_counts][aria-checked=false]"
             )

      assert [%{actor_type: "user", actor_id: actor_id, metadata: %{"value" => false}} | _] =
               switch_audits(:usage_counts) |> Enum.reverse()

      assert actor_id == admin.id

      view
      |> element("#settings-sharing [data-role=sharing-switch][data-key=usage_counts]")
      |> render_click()

      assert Sharing.enabled?(:usage_counts)
    end

    test "turning Feedback you send off hides Send feedback, and the card stays to turn it back on" do
      Application.put_env(:platform, :feedback_policy, "quarantined")
      all_on!()
      {:ok, view, _html} = live(authed(VaultFixtures.admin!()), "/settings")
      assert has_element?(view, "[data-role=settings-feedback]")

      view
      |> element("#settings-sharing [data-role=sharing-switch][data-key=feedback]")
      |> render_click()

      refute has_element?(view, "[data-role=settings-feedback]")
      assert has_element?(view, "#settings-sharing [data-role=sharing-switch][data-key=feedback]")

      view
      |> element("#settings-sharing [data-role=sharing-switch][data-key=feedback]")
      |> render_click()

      assert has_element?(view, "[data-role=settings-feedback]")
    end

    test "a page mounted with Feedback you send off can turn it back on" do
      Application.put_env(:platform, :feedback_policy, "quarantined")
      all_on!()
      {:ok, _} = Sharing.set(:feedback, false, :system)
      {:ok, view, _html} = live(authed(VaultFixtures.admin!()), "/settings")
      refute has_element?(view, "[data-role=settings-feedback]")

      view
      |> element("#settings-sharing [data-role=sharing-switch][data-key=feedback]")
      |> render_click()

      assert Sharing.enabled?(:feedback)
      assert has_element?(view, "[data-role=settings-feedback]")

      assert has_element?(
               view,
               "#settings-sharing [data-role=sharing-switch][data-key=feedback][aria-checked=true]"
             )
    end

    test "a member sees every switch read-only" do
      all_on!()
      {:ok, view, _html} = live(authed(VaultFixtures.non_admin!()), "/settings")

      for key <- Sharing.keys() do
        assert has_element?(
                 view,
                 "#settings-sharing [data-role=sharing-switch][data-key=#{key}][aria-checked=true][disabled][data-readonly=true]"
               )
      end

      refute has_element?(view, "#settings-sharing [data-role=sharing-switch][phx-click]")

      assert has_element?(
               view,
               "#settings-sharing [data-role=sharing-readonly-note]",
               "Only an install admin can change these."
             )
    end

    test "a forged set_sharing from a member changes nothing and writes no audit row" do
      all_on!()
      before = length(switch_audits(:usage_counts))
      {:ok, view, _html} = live(authed(VaultFixtures.non_admin!()), "/settings")

      render_click(view, "set_sharing", %{"key" => "usage_counts", "enabled" => "false"})

      assert Sharing.enabled?(:usage_counts)
      assert length(switch_audits(:usage_counts)) == before
      assert has_element?(view, "#settings-sharing [data-role=sharing-error]")
    end

    test "an unknown key is refused without creating an atom" do
      {:ok, view, _html} = live(authed(VaultFixtures.admin!()), "/settings")
      render_click(view, "set_sharing", %{"key" => "not_a_sharing_key", "enabled" => "true"})
      assert has_element?(view, "#settings-sharing [data-role=sharing-error]")
    end
  end

  describe "the setup disclosure on /setup/connect-ai" do
    setup do
      fake = start_supervised!({FakeHost, report_after_ms: 0})
      assert_eventually(fn -> Reconciler.host_pid() == fake end, 3_000)
      :ok
    end

    test "switches already on, one primary Continue, no modal, and Continue folds it" do
      all_on!()
      {:ok, view, _html} = live(authed(VaultFixtures.admin!()), ~p"/setup/connect-ai")

      card = "#connect-ai-sharing[data-role=sharing-card][data-variant=setup]"

      assert has_element?(
               view,
               card <> " [data-role=sharing-heading]",
               "This install shares a little with Burrow."
             )

      for key <- Sharing.keys() do
        assert has_element?(
                 view,
                 card <>
                   " [data-role=sharing-switch][data-key=#{key}][aria-checked=true][data-readonly=false]"
               )
      end

      assert texts(view, card <> " [data-role=sharing-event]") == UsageEvents.events()
      assert texts(view, card <> " button.btn-primary") == ["Continue"]
      refute has_element?(view, card <> " [role=dialog]")
      # Inline: the subscription choices are there alongside it.
      assert has_element?(view, "#connect-ai-options")

      view |> element(card <> " [data-role=sharing-continue]") |> render_click()

      refute has_element?(view, card)

      assert has_element?(
               view,
               "[data-role=sharing-summary]",
               "Sharing with Burrow: 4 of 4 parts on."
             )
    end

    test "turning one part off in setup is stored, audited and summarised" do
      all_on!()
      admin = VaultFixtures.admin!()
      {:ok, view, _html} = live(authed(admin), ~p"/setup/connect-ai")

      view
      |> element("#connect-ai-sharing [data-role=sharing-switch][data-key=friction_reports]")
      |> render_click()

      refute Sharing.enabled?(:friction_reports)
      assert Enum.any?(switch_audits(:friction_reports), &(&1.actor_id == admin.id))

      view |> element("#connect-ai-sharing [data-role=sharing-continue]") |> render_click()
      assert has_element?(view, "[data-role=sharing-summary]", "3 of 4 parts on.")
    end
  end

  test "no owner-facing copy says telemetry or analytics, and no warning or error colour" do
    {:ok, view, _html} = live(authed(VaultFixtures.admin!()), "/settings")

    html =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#settings-sharing")
      |> LazyHTML.to_html()

    assert html =~ "Sharing with Burrow"
    refute html =~ ~r/telemetry|analytics/i
    alarm = ~r/(?<![\w-])(text|bg|border|ring|fill|stroke)-(warning|error)\b/
    # Anti-vacuity: the pattern catches a real class and not data-role="sharing-error".
    assert ~s(class="p-2 text-warning") =~ alarm
    refute ~s(data-role="sharing-error") =~ alarm
    refute html =~ alarm

    source = File.read!("lib/platform_web/components/sharing_card.ex")
    refute source =~ alarm
  end
end
