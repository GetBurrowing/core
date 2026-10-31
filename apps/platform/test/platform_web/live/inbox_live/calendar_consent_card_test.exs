defmodule PlatformWeb.InboxLive.CalendarConsentCardTest do
  @moduledoc """
  The Inbox calendar consent card rebuilt to prototype 01a178d2 v4
  (`consentHTML`; task 01a18d9f stage 4): pending, approved, preapproved,
  reverted and revoked copy, and the Approve / Revert / Undo verbs.
  """
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Platform.{Calendar, Repo}
  alias Platform.Access.Scope
  alias Platform.Memory.Briefing

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "consent-ui-#{n}@example.com",
        name: "Consent viewer",
        oidc_sub: "consent-ui-#{n}"
      })

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })

    agent =
      Repo.insert!(%Platform.Agents.Agent{
        name: "Scheduler",
        slug: "scheduler-#{n}",
        metadata: %{"role" => "scheduling"}
      })

    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        runtime_id: "scheduler-#{n}",
        owner_user_id: user.id,
        agent_id: agent.id,
        status: "active",
        display_name: "Scheduler"
      })

    Repo.insert!(%Platform.Access.RuntimeProfile{
      runtime_id: runtime.id,
      tool_profile: ["context_read"],
      restricted_permissions:
        Platform.Access.RuntimeProfiles.translated_permissions(["context_read"])
    })

    %{
      conn: init_test_session(conn, current_user_id: user.id),
      user: user,
      owner: Scope.for_user(user),
      agent: agent,
      scope: Scope.for_runtime(runtime)
    }
  end

  defp grant!(ctx, extra \\ %{}) do
    {:ok, _} =
      Calendar.AgentAccess.grant(
        ctx.owner,
        ctx.agent.id,
        Map.merge(%{read: true, create: true}, extra)
      )
  end

  # Friday 6 Nov 2026, 14:00–14:45 UTC.
  defp propose!(ctx) do
    {:ok, consent} =
      Calendar.AgentAccess.propose(
        ctx.scope,
        ctx.user.id,
        "create",
        %{
          title: "Interview",
          description: "Round 2",
          starts_at: ~U[2026-11-06 14:00:00.000000Z],
          ends_at: ~U[2026-11-06 14:45:00.000000Z],
          time_zone: "Etc/UTC"
        },
        "consent-#{System.unique_integer([:positive])}"
      )

    consent
  end

  defp open!(ctx, consent) do
    briefing = Repo.get!(Briefing, consent.briefing_id)
    {:ok, view, _} = live(ctx.conn, "/inbox/briefing/#{briefing.digest_date}")
    view
  end

  defp card(consent), do: "[data-kind=calendar][data-consent-key='calendar:#{consent.id}']"

  test "pending card: pills, question, meta and the three actions", ctx do
    grant!(ctx)
    consent = propose!(ctx)
    view = open!(ctx, consent)
    card = card(consent) <> "[data-consent-state=pending]"

    assert has_element?(view, card <> " .cal-pill-acc", "Needs your OK")
    assert has_element?(view, card <> " .cal-pill", "Scheduler · scheduling")

    assert has_element?(
             view,
             card <> " .cal-consent-q",
             "I’m tentatively booking Interview Fri 2pm, OK?"
           )

    assert has_element?(
             view,
             card <> " .cal-consent-meta",
             "Round 2 · Fri 6 Nov, 14:00–14:45. It’s on your calendar as a tentative hold. Nothing has been sent yet."
           )

    assert has_element?(view, card <> " button", "Approve")
    assert has_element?(view, card <> " button", "Revert")

    assert has_element?(
             view,
             card <>
               " a[data-role=consent-see-calendar][href='/calendar?date=2026-11-06&select=#{consent.hold_id}']",
             "See it on the calendar"
           )
  end

  test "Approve books it, Undo reverts it", ctx do
    grant!(ctx)
    consent = propose!(ctx)
    view = open!(ctx, consent)

    view |> element(card(consent) <> " button", "Approve") |> render_click()
    approved = card(consent) <> "[data-consent-state=approved]"
    assert has_element?(view, approved <> " .cal-pill-ok", "Approved by you")

    assert has_element?(
             view,
             approved <> " .cal-consent-q",
             "Interview is booked for Fri 6 Nov, 14:00–14:45."
           )

    assert has_element?(
             view,
             approved <> " .cal-consent-meta",
             "Scheduler turned the hold into a real event."
           )

    assert has_element?(view, approved <> " a[data-role=consent-see-calendar]")

    view |> element(approved <> " button", "Undo") |> render_click()
    reverted = card(consent) <> "[data-consent-state=reverted]"
    assert has_element?(view, reverted <> " .cal-pill", "Reverted by you")
  end

  test "Revert removes the hold and offers no Undo", ctx do
    grant!(ctx)
    consent = propose!(ctx)
    view = open!(ctx, consent)

    view |> element(card(consent) <> " button", "Revert") |> render_click()
    reverted = card(consent) <> "[data-consent-state=reverted]"
    assert has_element?(view, reverted <> " .cal-pill", "Reverted by you")
    assert has_element?(view, reverted <> " .cal-consent-q", "The Fri 2pm hold is gone.")

    assert has_element?(
             view,
             reverted <> " .cal-consent-meta",
             "Scheduler has been told you passed on that slot."
           )

    refute has_element?(view, reverted <> " button", "Undo")
    refute has_element?(view, reverted <> " a[data-role=consent-see-calendar]")
  end

  test "a preapproved request reads as preapproved", ctx do
    grant!(ctx, %{preapprove: true})
    consent = propose!(ctx)
    view = open!(ctx, consent)
    approved = card(consent) <> "[data-consent-state=approved]"
    assert has_element?(view, approved <> " .cal-pill-ok", "Preapproved by you")
  end

  test "revoking access removes the pending hold and says so", ctx do
    grant!(ctx)
    consent = propose!(ctx)
    {:ok, _} = Calendar.AgentAccess.revoke(ctx.owner, ctx.agent.id)
    view = open!(ctx, consent)
    revoked = card(consent) <> "[data-consent-state=revoked]"

    assert has_element?(
             view,
             revoked <> " .cal-consent-meta",
             "Scheduler lost calendar access, so its pending hold was removed."
           )

    refute has_element?(view, revoked <> " button", "Undo")
  end
end
