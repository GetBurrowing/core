defmodule PlatformWeb.SocialInviteLanding do
  @moduledoc """
  The invitee landing page (task 01a14ce1, stage 4), extracted from
  `PlatformWeb.SocialLive` by Social authoring 1/11 with no behaviour change.

  `?invite=<token>` renders this page INSTEAD of the profile UI, for every
  state (ready, expired, used, cancelled, not valid, signed out). Continue
  calls `Platform.Social.start_invite_connect/3` for the viewer, re-read on
  the click; the vendor return (`?invite_connect=<nonce>`) lands on the
  success card, or on the failed card whose Try again calls
  `restart_invite_connect/3`. The token (or nonce) is kept in assigns only
  while it can still be used, as a lookup key: every event re-resolves it
  through Social.
  """

  use PlatformWeb, :html

  import Phoenix.LiveView, only: [redirect: 2]
  import PlatformWeb.SocialHelpers

  alias Platform.Accounts.User
  alias Platform.Social
  alias Platform.Social.Approvals

  @invite_unusable "That invite link can't finish this connection. Nothing changed. Ask for a new link."

  @nonce ~r/\A[A-Za-z0-9_-]{16,128}\z/

  @doc "The copy for an invite that cannot finish this connection."
  def unusable, do: @invite_unusable

  def events, do: ~w(invite_continue invite_retry)

  # The user is re-read and the invite re-resolved through Social on every
  # event; the token or nonce in assigns is only a lookup key, never proof.
  def handle_event("invite_continue", _params, socket) do
    user = fresh_user(socket)

    case {user, socket.assigns.invite_token} do
      {%User{archived_at: nil} = user, token} when is_binary(token) ->
        case Social.start_invite_connect(token, user.id) do
          {:ok, url} ->
            {:noreply, redirect(socket, external: url)}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign_invite_landing(token, user)
             |> landing_error("Couldn't start the LinkedIn connection. Try again.")}
        end

      # No usable invite on this page (expired, used, forged...): nothing
      # to start, and no request.
      {_user, nil} ->
        {:noreply, socket}

      {_user, token} ->
        {:noreply, assign_invite_landing(socket, token, user)}
    end
  end

  def handle_event("invite_retry", _params, socket) do
    user = fresh_user(socket)

    case {user, socket.assigns.invite_nonce} do
      {%User{archived_at: nil} = user, nonce} when is_binary(nonce) ->
        case Social.restart_invite_connect(nonce, user.id) do
          {:ok, url} ->
            {:noreply, redirect(socket, external: url)}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign_failed_landing(nonce, user)
             |> landing_error(
               "Couldn't start the LinkedIn connection. Open your invite link again."
             )}
        end

      {_user, nil} ->
        {:noreply, socket}

      {_user, nonce} ->
        {:noreply, assign_failed_landing(socket, nonce, user)}
    end
  end

  @doc """
  ?invite=<token> is the shared link; ?invite_connect=<nonce>&error=... is
  a cancelled or failed vendor leg. Everything else is the normal page.
  """
  def landing_params(%{"invite" => token}) when is_binary(token), do: {:invite, token}

  def landing_params(%{"invite_connect" => nonce, "error" => _}) when is_binary(nonce),
    do: {:invite_failed, nonce}

  def landing_params(_query), do: :none

  defp shaped_nonce(value) when is_binary(value), do: if(value =~ @nonce, do: value)
  defp shaped_nonce(_value), do: nil

  @doc """
  Resolves the shared token for the viewer, re-read now. The token is kept
  in assigns ONLY while the invite is usable (Continue needs it as a lookup
  key); every other state drops it.
  """
  def assign_invite_landing(socket, token, user) do
    shaped_token = shaped_nonce(token)

    result =
      cond do
        not human?(user) -> :signed_out
        is_nil(shaped_token) -> {:error, :not_found}
        true -> Social.invite_landing_for(shaped_token, user.id)
      end

    case result do
      :signed_out ->
        socket |> assign(:invite_token, nil) |> assign(:landing, %{state: :signed_out})

      {:ok, invite, profile} ->
        socket
        |> assign(:invite_token, shaped_token)
        |> assign(:landing, landing(:ready, invite, profile, user))

      {:error, state, invite, profile} ->
        socket
        |> assign(:invite_token, nil)
        |> assign(:landing, landing(state, invite, profile, user))

      {:error, _reason} ->
        socket
        |> assign(:invite_token, nil)
        |> assign(:landing, %{state: :invalid, message: "This invite link isn't valid."})
    end
  end

  @doc """
  The vendor leg was cancelled or failed. The nonce stays in assigns only
  while Try again can use it.
  """
  def assign_failed_landing(socket, nonce, user) do
    shaped = shaped_nonce(nonce)

    result =
      cond do
        not human?(user) -> :signed_out
        is_nil(shaped) -> {:error, :not_found}
        true -> Social.invite_return_for(shaped, user.id)
      end

    case result do
      :signed_out ->
        socket |> assign(:invite_nonce, nil) |> assign(:landing, %{state: :signed_out})

      {:ok, invite, profile} ->
        socket
        |> assign(:invite_nonce, shaped)
        |> assign(:landing, landing(:failed, invite, profile, user))

      {:error, state, invite, profile} ->
        socket
        |> assign(:invite_nonce, nil)
        |> assign(:landing, landing(state, invite, profile, user))

      {:error, _reason} ->
        socket
        |> assign(:invite_nonce, nil)
        |> assign(:landing, %{state: :invalid, message: @invite_unusable})
    end
  end

  defp landing(state, invite, profile, user) do
    %{
      state: state,
      brand: profile.name,
      platform: platform_label(invite.platform),
      inviter: inviter_name(invite.created_by_user_id),
      expires_on: short_date(invite.expires_at),
      viewer_used?: state == :used and invite.used_by_user_id == user.id,
      profile_id: profile.id,
      error: nil
    }
  end

  defp landing_error(%{assigns: %{landing: %{state: state} = landing}} = socket, text)
       when state in [:ready, :failed],
       do: assign(socket, :landing, Map.put(landing, :error, text))

  defp landing_error(socket, _text), do: socket

  defp inviter_name(user_id) when is_binary(user_id) do
    case Platform.Accounts.get_user(user_id) do
      %User{} = user -> user_name(user)
      nil -> "the person who invited you"
    end
  end

  defp inviter_name(_user_id), do: "the person who invited you"

  @doc """
  The owner's ONE Social DM, where drafts for their own account arrive
  (Approvals.owner_dm/2, find-or-create). No link when it can't be had.
  """
  def owner_dm_path(profile, %User{id: user_id}) do
    case Approvals.owner_dm(profile.org_id, user_id) do
      {:ok, space} -> "/chat/" <> Platform.Chat.space_path_segment(space)
      _ -> nil
    end
  end

  attr :landing, :map, required: true

  @doc """
  The invitee landing page: ONE base-100 card on base-200, rendered instead
  of the profile UI. Continue / Try again are the only actions, and they
  exist only in the :ready / :failed states.
  """
  def page(assigns) do
    ~H"""
    <div class="flex min-h-full flex-1 items-start justify-center bg-base-200 px-4 py-8 sm:items-center sm:py-12">
      <section
        class="w-full max-w-md rounded-2xl border border-base-300 bg-base-100 p-6 sm:p-8"
        data-role="social-invite-landing"
        data-state={@landing.state}
      >
        <%= case @landing.state do %>
          <% :checking -> %>
            <p class="text-base-content/70">Checking your connection...</p>
          <% :signed_out -> %>
            <h1 class="text-2xl font-semibold">You've been invited to connect an account</h1>
            <p class="mt-2 text-base-content/70">Sign in to Burrow to see who invited you.</p>
            <a
              href="/auth/login"
              class="btn btn-primary mt-6 w-full"
              data-role="social-invite-sign-in"
            >
              Sign in to continue
            </a>
          <% :invalid -> %>
            <p class="text-base-content" data-role="social-invite-message">{@landing.message}</p>
          <% state -> %>
            <.landing_brand brand={@landing.brand} />
            <.landing_body landing={@landing} state={state} />
        <% end %>
      </section>
    </div>
    """
  end

  attr :brand, :string, required: true

  defp landing_brand(assigns) do
    ~H"""
    <div class="avatar avatar-placeholder mb-4">
      <div class="size-12 rounded-xl bg-neutral text-neutral-content">
        <span class="text-lg font-semibold">{initial(@brand)}</span>
      </div>
    </div>
    """
  end

  attr :landing, :map, required: true
  attr :state, :atom, required: true

  defp landing_body(%{state: :ready} = assigns) do
    ~H"""
    <h1 class="text-2xl font-semibold" data-role="social-invite-headline">
      Connect your {@landing.platform} to {@landing.brand}
    </h1>
    <p class="mt-1 text-sm text-base-content/70" data-role="social-invite-meta">
      {@landing.inviter} invited you. Link expires {@landing.expires_on}.
    </p>
    <ul class="mt-5 list-disc space-y-2 pl-5">
      <li>Agents can draft posts for your {@landing.platform} account.</li>
      <li class="font-semibold">Nothing posts until you approve it. Drafts arrive in your DM.</li>
      <li>You can disconnect any time from Connections.</li>
    </ul>
    <.landing_error_line error={@landing.error} />
    <div class="mt-6 flex flex-col gap-2">
      <button
        type="button"
        class="btn btn-primary w-full"
        phx-click="invite_continue"
        phx-disable-with="Opening LinkedIn..."
        data-role="social-invite-continue"
      >
        <.platform_icon platform="linkedin" class="size-4 text-base-content" />
        Continue to {@landing.platform}
      </button>
      <a href="/" class="btn btn-ghost w-full" data-role="social-invite-not-now">Not now</a>
    </div>
    """
  end

  defp landing_body(%{state: :expired} = assigns) do
    ~H"""
    <div role="status" class="alert alert-warning" data-role="social-invite-message">
      <.icon name="hero-clock" class="size-5 shrink-0" />
      <span>
        This invite expired on {@landing.expires_on}. Ask {@landing.inviter} for a new one.
      </span>
    </div>
    """
  end

  defp landing_body(%{state: :cancelled} = assigns) do
    ~H"""
    <p class="text-base-content" data-role="social-invite-message">
      This invite was cancelled. Ask {@landing.inviter} for a new one.
    </p>
    """
  end

  defp landing_body(%{state: :used} = assigns) do
    ~H"""
    <p class="text-base-content" data-role="social-invite-message">
      This invite was already used.
    </p>
    <a
      :if={@landing.viewer_used?}
      href={"/m/social?" <> URI.encode_query(%{"tab" => "connections", "profile" => @landing.profile_id})}
      class="link mt-3 inline-block"
      data-role="social-invite-account-link"
    >
      See your connected account
    </a>
    """
  end

  defp landing_body(%{state: :success} = assigns) do
    ~H"""
    <p class="text-base-content" data-role="social-invite-message">
      Your {@landing.platform} is connected to {@landing.brand}. Drafts will come to your DM.
    </p>
    <a
      :if={@landing.dm_path}
      href={@landing.dm_path}
      class="btn btn-primary mt-6 w-full"
      data-role="social-invite-dm-link"
    >
      Open your DM
    </a>
    """
  end

  defp landing_body(%{state: :failed} = assigns) do
    ~H"""
    <p class="text-base-content" data-role="social-invite-message">
      {@landing.platform} didn't finish connecting, so nothing changed. Your invite still works until {@landing.expires_on}.
    </p>
    <.landing_error_line error={@landing.error} />
    <button
      type="button"
      class="btn btn-primary mt-6 w-full"
      phx-click="invite_retry"
      phx-disable-with="Opening LinkedIn..."
      data-role="social-invite-retry"
    >
      Try again
    </button>
    """
  end

  attr :error, :string, default: nil

  defp landing_error_line(assigns) do
    ~H"""
    <p
      :if={@error}
      role="alert"
      class="mt-4 flex items-center gap-1.5 text-sm text-base-content"
      data-role="social-invite-error"
    >
      <.icon name="hero-exclamation-circle" class="size-4 shrink-0 text-error" />
      {@error}
    </p>
    """
  end
end
