defmodule PlatformWeb.SocialHelpers do
  @moduledoc """
  What more than one Social tab needs (Social authoring 1/11): the approver
  re-check, the pane notice line, labels and small formatters. Imported by
  every `use PlatformWeb.SocialTab` module.
  """

  use PlatformWeb, :html

  alias Platform.Accounts.User
  alias Platform.Social
  alias Platform.Social.Account

  # Display names only; option VALUES always come from
  # Social.connectable_platforms/0.
  @platform_labels %{
    "x" => "X",
    "linkedin" => "LinkedIn",
    "tiktok" => "TikTok",
    "instagram" => "Instagram",
    "youtube" => "YouTube"
  }

  def platform_label(platform), do: Map.get(@platform_labels, platform, platform)

  def platform_options(platforms), do: Enum.map(platforms, &{platform_label(&1), &1})

  @doc """
  The user, re-read now, must pass approver_check/3 on the CURRENT profile,
  itself re-read through the scope.
  """
  def authorize(%{assigns: %{profile: %{} = profile, user: %{id: user_id}}}) do
    with %Social.Profile{} = fresh <- Social.get_profile(profile.org_id, profile.id),
         :ok <- Social.approver_check(fresh.org_id, fresh, user_id) do
      {:ok, fresh, user_id}
    else
      _ -> {:error, :not_an_approver}
    end
  end

  def authorize(_socket), do: {:error, :not_an_approver}

  @doc "A live account of `profile`, read through the scope, else nil."
  def profile_account(profile, id) do
    case Social.get_account(profile.org_id, id) do
      %Account{profile_id: profile_id, archived_at: nil} = account
      when profile_id == profile.id ->
        account

      _ ->
        nil
    end
  end

  def fresh_user(%{assigns: %{user: %{id: id}}}), do: Platform.Accounts.get_user(id)
  def fresh_user(_socket), do: nil

  def human?(%User{archived_at: nil}), do: true
  def human?(_user), do: false

  def user_name(%User{name: name}) when is_binary(name) and name != "", do: name
  def user_name(%User{email: email}) when is_binary(email), do: email
  def user_name(_user), do: "someone"

  def initial(name) when is_binary(name) and name != "",
    do: name |> String.first() |> String.upcase()

  def initial(_name), do: "?"

  @doc ~s("Oct 24")
  def short_date(%DateTime{} = at), do: Calendar.strftime(at, "%b %-d")

  def own_url(path), do: PlatformWeb.Endpoint.url() <> path

  def blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  def blank_to_nil(_), do: nil

  @doc "`tone` is :info (the plain notice line) or :warning (alert-warning)."
  def notice(socket, text, tone \\ :info),
    do: socket |> assign(:notice, text) |> assign(:notice_tone, tone)

  attr :notice, :string, default: nil
  attr :tone, :atom, default: :info, values: [:info, :warning]

  def notice_line(assigns) do
    ~H"""
    <p
      :if={@notice}
      role="status"
      class={[
        "mb-3 flex items-center justify-between gap-2 px-3 py-2 text-sm",
        @tone == :warning && "alert alert-warning",
        @tone != :warning && "rounded-lg border border-base-300 bg-base-100"
      ]}
      data-role="social-notice"
      data-tone={@tone}
    >
      <span>{@notice}</span>
      <button type="button" class="btn btn-ghost btn-xs" phx-click="dismiss_notice">Dismiss</button>
    </p>
    """
  end

  attr :platform, :string, required: true
  attr :class, :string, default: "size-4"

  @doc """
  LinkedIn's mark in currentColor (base-content, never brand blue); other
  platforms get a generic globe.
  """
  def platform_icon(%{platform: "linkedin"} = assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" class={["shrink-0 fill-current", @class]} aria-hidden="true">
      <path d="M20.45 20.45h-3.56v-5.57c0-1.33-.02-3.04-1.85-3.04-1.85 0-2.14 1.45-2.14 2.94v5.67H9.35V9h3.41v1.56h.05c.48-.9 1.64-1.85 3.37-1.85 3.6 0 4.27 2.37 4.27 5.46v6.28zM5.34 7.43a2.06 2.06 0 1 1 0-4.13 2.06 2.06 0 0 1 0 4.13zM7.12 20.45H3.56V9h3.56v11.45zM22.22 0H1.77C.79 0 0 .77 0 1.73v20.54C0 23.23.79 24 1.77 24h20.45c.98 0 1.78-.77 1.78-1.73V1.73C24 .77 23.2 0 22.22 0z" />
    </svg>
    """
  end

  def platform_icon(assigns) do
    ~H"""
    <.icon name="hero-globe-alt" class={"shrink-0 " <> @class} />
    """
  end
end
