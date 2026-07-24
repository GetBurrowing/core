defmodule PlatformWeb.ExternalHoldingLive do
  @moduledoc """
  The zero-access **holding** landing (rbac-external-users M3 stage 2, task
  019f8837) — the calm "your workspace is being set up" surface that ANY
  incompletely-provisioned external user lands on, AND the consumer half of
  the seamless live-recovery centerpiece: a waiting tab upgrades itself to
  full access WITH NO RE-LOGIN the moment an admin grants.

  ## Never a black hole, never a discovery leak

  A holding external login is authenticated (M2 keeps `current_user_id` set)
  but holds ZERO scoped rows — no membership, no participants, no allowlist.
  Rendering the normal app shell would leak a space/discovery list. So this
  LiveView is served by its OWN `:external_holding` live_session paired with
  the chrome-less `Layouts.holding/1` layout: no icon rail, no bottom nav,
  no space list — brand chip + logout are the only affordances.

  ## Mount branching

    * Session carries `%{state: :holding, user_id: uid}` under the
      `"external_admission"` key (planted by M2's auth callback / dev_login)
      → render the holding card and, once `connected?`, subscribe to
      `ExternalAdmission.external_admission_topic(uid)`.
    * Session key ABSENT / not holding (an ordinary internal full user hit
      `/welcome` directly) → `push_navigate(to: "/chat")` immediately. We
      NEVER park an internal user on the holding page (regression guard,
      mirroring M2's "never black-hole internal users" invariant).

  ## Seamless upgrade

  `recover/3` (M2 seam, invoked by the M3 stage-4 admin queue) broadcasts
  `{:external_admission, :recovered, uid, %Result{state: :full}}` on the
  topic this LiveView subscribed to. The already-authenticated session
  simply `push_navigate`s to `/chat` — no re-auth, no new
  `find_or_create_from_oidc`.
  """
  use PlatformWeb, :live_view

  alias Platform.Accounts.ExternalAdmission
  alias PlatformWeb.ExternalRedirect
  alias PlatformWeb.Layouts

  @impl true
  def mount(_params, session, socket) do
    case session["external_admission"] do
      %{state: :holding, user_id: uid} when is_binary(uid) ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(
            Platform.PubSub,
            ExternalAdmission.external_admission_topic(uid)
          )
        end

        {:ok,
         socket
         |> assign(:page_title, "Setting up your workspace")
         |> assign(:holding_user_id, uid), layout: {Layouts, :holding}}

      _ ->
        # Not holding — an ordinary internal full user reached /welcome, or
        # the seam key is absent. Never park a non-holding user here.
        {:ok, push_navigate(socket, to: ~p"/chat")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl true
  # The seamless upgrade: an admin granted access, `recover/3` broadcast the
  # recovery, and this waiting tab navigates to the full surface with no
  # re-auth. `%{state: :full}` matches both the `%Result{}` struct and a bare
  # map, so a benign re-broadcast (double-grant race) is handled identically.
  def handle_info({:external_admission, :recovered, _uid, %{state: :full}}, socket) do
    # task 019f9257: the recovering user is an external user (holding is
    # external-only), waiting on `suite./welcome`. Pin them to the chat host so
    # /welcome transitions to their SCOPED external surface, not the leaky
    # suite-host `/chat`. LiveView `push_navigate` cannot cross hosts, so use a
    # full redirect to the absolute chat-host URL when CHAT_HOST is configured;
    # fall back to a same-host `push_navigate` in dev/test.
    if ExternalRedirect.chat_host_configured?() do
      {:noreply, redirect(socket, external: ExternalRedirect.chat_url("/chat"))}
    else
      {:noreply, push_navigate(socket, to: ~p"/chat")}
    end
  end

  # Tolerate any other message shape without crashing the holding tab.
  def handle_info(_message, socket), do: {:noreply, socket}
end
