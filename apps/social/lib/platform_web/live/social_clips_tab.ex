defmodule PlatformWeb.SocialClipsTab do
  @moduledoc """
  The Clips tab (Clip Studio 3/9, task 01a16662-8c00), moved verbatim out of
  `PlatformWeb.SocialLive` by Social authoring 1/11. The mount is unchanged:
  `PlatformWeb.SocialClipsReview` (the Review bay, with its ClipReview hook),
  `PlatformWeb.SocialClipsLibrary` while `?view=library`, and
  `PlatformWeb.SocialClipNew`, under the same ids.

  URL params (`from_query/2`): `view` (`review` | `library`) and `clip` (a
  UUID, else ignored). The tab button carries the pending count.

  Per brand only (`all_brands?/0` false): the bay is one profile's clips.
  """

  use PlatformWeb.SocialTab

  alias Platform.Social

  # The Review bay's two views (`?view=`).
  @clips_views ~w(review library)

  @impl true
  def enabled?, do: true

  @impl true
  def init(socket) do
    socket
    |> assign(:closing_filter, nil)
    |> assign(:clips_view, "review")
    |> assign(:clips_clip_id, nil)
    |> assign(:clips_profile_id, nil)
    |> assign(:clips_count, 0)
  end

  # The current profile's clips topic (the previous profile's is dropped)
  # and the tab's pending count.
  @impl true
  def load(socket) do
    previous = socket.assigns.clips_profile_id
    current = socket.assigns.profile && socket.assigns.profile.id

    if connected?(socket) and previous != current do
      if previous, do: Phoenix.PubSub.unsubscribe(Platform.PubSub, Social.clips_topic(previous))
      if current, do: Phoenix.PubSub.subscribe(Platform.PubSub, Social.clips_topic(current))
    end

    socket
    |> assign(:clips_profile_id, if(connected?(socket), do: current))
    |> load_count()
  end

  defp load_count(%{assigns: %{profile: %{id: id, org_id: org_id}}} = socket),
    do: assign(socket, :clips_count, Platform.Social.ClipReviewFeed.pending_count(org_id, id))

  defp load_count(socket), do: assign(socket, :clips_count, 0)

  @impl true
  def from_query(socket, query) do
    socket
    |> assign(:clips_view, if(query["view"] in @clips_views, do: query["view"], else: "review"))
    |> assign(:clips_clip_id, clip_param(query["clip"]))
    |> assign(:closing_filter, if(query["closing"] == "previous", do: "previous"))
  end

  defp clip_param(clip) when is_binary(clip) do
    case Ecto.UUID.cast(clip) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp clip_param(_clip), do: nil

  # A clips-topic broadcast for the CURRENT profile goes to the Review bay
  # and refreshes the tab's count; any other is ignored.
  @impl true
  def handle_info({:social_clip, %Platform.Social.Clip{} = clip}, socket) do
    case socket.assigns.profile do
      %{id: profile_id} when profile_id == clip.profile_id ->
        send_update(PlatformWeb.SocialClipsReview, id: "social-clips-review", clip_event: clip)

        if socket.assigns.clips_view == "library" do
          send_update(PlatformWeb.SocialClipsLibrary, id: "social-clips-library", refresh: true)
        end

        {:noreply, load_count(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:social_clip_job, %{profile_id: profile_id}}, socket) do
    if socket.assigns.profile && socket.assigns.profile.id == profile_id do
      send_update(PlatformWeb.SocialClipsReview, id: "social-clips-review", job_event: true)
    end

    {:noreply, socket}
  end

  # The Review bay's segmented control.
  def handle_info({:clips_view, view}, socket) when view in @clips_views,
    do: {:noreply, assign(socket, :clips_view, view)}

  def handle_info(_message, _socket), do: :unhandled

  @impl true
  def tab_badge(assigns) do
    ~H"""
    <span class="ml-1 text-base-content" data-role="social-clips-count">
      {if @clips_count > 0, do: @clips_count}
    </span>
    """
  end

  @impl true
  def pane(assigns) do
    ~H"""
    <.live_component
      module={PlatformWeb.SocialClipsReview}
      id="social-clips-review"
      profile={@profile}
      user_id={@user.id}
      view={@clips_view}
      clip_id={@clips_clip_id}
      closing_filter={@closing_filter}
    />
    <.live_component
      :if={@clips_view == "library"}
      module={PlatformWeb.SocialClipsLibrary}
      id="social-clips-library"
      profile={@profile}
      user_id={@user.id}
    />
    <.live_component module={PlatformWeb.SocialClipNew} id="social-clip-new" />
    """
  end
end
