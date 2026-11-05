defmodule Platform.Chat.LinkUnfurls.OEmbed do
  @moduledoc """
  oEmbed for a FIXED table of providers (task 01a1a944 stage 2). There is no
  discovery: a page's `<link rel="alternate" type="application/json+oembed">`
  is never followed, so a page cannot point the install at an endpoint of its
  choosing. GitHub and everything else use the page's OpenGraph only.

  | provider  | hosts                                         | endpoint |
  |-----------|-----------------------------------------------|----------|
  | `youtube` | youtube.com, www/m/music.youtube.com, youtu.be | `https://www.youtube.com/oembed?format=json&url=` |
  | `vimeo`   | vimeo.com, www.vimeo.com, player.vimeo.com     | `https://vimeo.com/api/oembed.json?url=` |
  | `x`       | x.com, twitter.com (and www./mobile.)          | `https://publish.twitter.com/oembed?url=` |

  The endpoint is fetched through the same guarded
  `Platform.Chat.LinkUnfurls.Fetcher` as the page. `parse/1` reads the
  fields unfurls use. A duration comes only from the provider's own
  `duration` field (Vimeo gives one; YouTube's oEmbed does not, so a YouTube
  card shows no duration rather than an invented one).
  """

  alias Platform.Chat.LinkUnfurls.Parser

  @providers [
    {"youtube", ~w(youtube.com www.youtube.com m.youtube.com music.youtube.com youtu.be),
     "https://www.youtube.com/oembed?format=json&url="},
    {"vimeo", ~w(vimeo.com www.vimeo.com player.vimeo.com),
     "https://vimeo.com/api/oembed.json?url="},
    {"x", ~w(x.com www.x.com twitter.com www.twitter.com mobile.twitter.com mobile.x.com),
     "https://publish.twitter.com/oembed?url="}
  ]

  @type t :: %{
          provider: String.t(),
          type: String.t() | nil,
          title: String.t() | nil,
          author: String.t() | nil,
          provider_name: String.t() | nil,
          thumbnail_url: String.t() | nil,
          thumbnail_width: pos_integer() | nil,
          thumbnail_height: pos_integer() | nil,
          duration_seconds: non_neg_integer() | nil
        }

  @doc "`{provider, endpoint_url}` for a URL in the table, else nil."
  @spec endpoint(String.t()) :: {String.t(), String.t()} | nil
  def endpoint(url) when is_binary(url) do
    with %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) <-
           URI.parse(url),
         {provider, _hosts, base} <-
           Enum.find(@providers, fn {_, hosts, _} -> String.downcase(host) in hosts end) do
      {provider, base <> URI.encode_www_form(url)}
    else
      _ -> nil
    end
  end

  @doc "The fields unfurls use, from an oEmbed JSON body; nil when it is not one."
  @spec parse(binary(), String.t()) :: t() | nil
  def parse(json, provider) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} ->
        %{
          provider: provider,
          type: str(map["type"], 40),
          title: str(map["title"], 300),
          author: str(map["author_name"], 200),
          provider_name: str(map["provider_name"], 200),
          thumbnail_url: absolute(string(map["thumbnail_url"])),
          thumbnail_width: int(map["thumbnail_width"]),
          thumbnail_height: int(map["thumbnail_height"]),
          duration_seconds: int(map["duration"])
        }

      _ ->
        nil
    end
  end

  # Only an absolute http(s) URL: a relative one has nothing to resolve
  # against (URI.merge raises on a relative base, so it comes back nil).
  defp absolute(nil), do: nil
  defp absolute(url), do: Parser.absolute_http_url(url, url)

  defp string(v) when is_binary(v), do: v
  defp string(_), do: nil

  defp str(v, max) when is_binary(v), do: Parser.cap(v, max)
  defp str(_v, _max), do: nil

  defp int(v) when is_integer(v) and v > 0, do: v
  defp int(v) when is_float(v) and v > 0, do: round(v)

  defp int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp int(_), do: nil
end
