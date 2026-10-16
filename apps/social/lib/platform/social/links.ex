defmodule Platform.Social.Links do
  @moduledoc """
  The link an agent's draft carries (task 01a140a9-4c70, Social 4/7). Pure:
  no DB, no network.

  `effective_link/4`: an explicit `link_url` wins, unchanged. Otherwise the
  base is the source `episode_url` when it is a YouTube video, else the
  profile's `home_url`. A YouTube video base with a `start_s` is normalised
  to `https://www.youtube.com/watch?v=ID&t=<whole seconds>`: any earlier `t`
  is replaced (never two) and tracking such as `si=` is dropped. Any other
  base (a channel page, a podcast site) is returned unchanged.

  `append_to_body/2` puts the link on its own line, once: a body that already
  contains it is returned as is.
  """

  @video_id ~r/\A[A-Za-z0-9_-]{6,}\z/
  @watch_hosts ~w(youtube.com www.youtube.com m.youtube.com music.youtube.com)
  @short_hosts ~w(youtu.be www.youtu.be)

  @spec effective_link(String.t() | nil, String.t() | nil, String.t() | nil, number() | nil) ::
          String.t() | nil
  def effective_link(link_url, home_url, episode_url, start_s) do
    if present?(link_url) do
      link_url
    else
      base = if youtube_video_id(episode_url), do: episode_url, else: blank_to_nil(home_url)

      case {youtube_video_id(base), start_s} do
        {id, s} when is_binary(id) and is_number(s) ->
          "https://www.youtube.com/watch?v=#{id}&t=#{max(trunc(s), 0)}"

        _ ->
          base
      end
    end
  end

  @doc "The video id when `url` is a YouTube video URL (youtu.be or watch?v=), else nil."
  @spec youtube_video_id(term()) :: String.t() | nil
  def youtube_video_id(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host} = uri when scheme in ["http", "https"] ->
        host = host && String.downcase(host)

        cond do
          host in @short_hosts -> uri.path |> to_string() |> String.trim_leading("/") |> id()
          host in @watch_hosts and uri.path in ["/watch", "/watch/"] -> watch_id(uri.query)
          true -> nil
        end

      _ ->
        nil
    end
  end

  def youtube_video_id(_), do: nil

  @spec append_to_body(String.t() | nil, String.t() | nil) :: String.t() | nil
  def append_to_body(body, link) do
    cond do
      not present?(link) -> body
      not present?(body) -> link
      String.contains?(body, link) -> body
      true -> String.trim_trailing(body) <> "\n" <> link
    end
  end

  defp watch_id(nil), do: nil
  defp watch_id(query), do: query |> URI.decode_query() |> Map.get("v") |> id()

  defp id(candidate) when is_binary(candidate) do
    candidate = candidate |> String.split("/") |> hd()
    if Regex.match?(@video_id, candidate), do: candidate, else: nil
  end

  defp id(_), do: nil

  defp present?(s), do: is_binary(s) and String.trim(s) != ""
  defp blank_to_nil(s), do: if(present?(s), do: s, else: nil)
end
