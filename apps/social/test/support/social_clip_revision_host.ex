defmodule PlatformWeb.SocialClipRevisionHost do
  @moduledoc false
  use PlatformWeb, :live_view
  alias Platform.Social

  def mount(_params, session, socket) do
    scope = session["scope"]

    {:ok,
     assign(socket,
       scope: scope,
       profile: Social.get_profile(scope, session["profile_id"]),
       clip: Social.get_clip(scope, session["clip_id"]),
       user_id: session["user_id"],
       notice: nil,
       notice_tone: :info
     )}
  end

  def handle_info({PlatformWeb.SocialClipRevision, :returned, _clip_id} = message, socket),
    do: PlatformWeb.SocialClipsTab.handle_info(message, socket)

  def handle_info({PlatformWeb.SocialClipRevision, _action, _clip_id}, socket),
    do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <PlatformWeb.SocialHelpers.notice_line notice={@notice} tone={@notice_tone} />
      <.live_component
        :if={PlatformWeb.SocialClipRevision.visible?(@clip)}
        module={PlatformWeb.SocialClipRevision}
        id={"revision-#{@clip.id}"}
        scope={@scope}
        profile={@profile}
        clip={@clip}
        user_id={@user_id}
      />
    </Layouts.app>
    """
  end
end
