defmodule Platform.Chat.LinkUnfurls.Parser do
  @moduledoc """
  Reads an outside page's preview metadata from its HTML (task 01a1a944
  stage 2), with Floki, in this order of preference:

    1. OpenGraph: `og:title`, `og:description`, `og:image` (its
       `:secure_url` when that is https, and `:width` / `:height`),
       `og:site_name`, `og:type`, `og:video:duration`;
    2. the Twitter card: `twitter:title`, `twitter:description`,
       `twitter:image`, `twitter:card`;
    3. `<title>` and `<meta name="description">`.

  A video duration is taken only when the page states one (`og:video:duration`
  in seconds, or an ISO-8601 `itemprop="duration"`); none is ever guessed.

  The image is resolved against the FINAL page URL (after redirects), and is
  kept only when it is an absolute `http` or `https` URL with a host. A
  `data:`, `javascript:` or any other scheme is dropped (nil), so the page
  can never make a viewer's browser render inline bytes or run script from
  a preview. Text is trimmed, whitespace collapsed, and capped: title at
  300 characters, description at 500.
  """

  @title_max 300
  @description_max 500
  @short_max 200
  @url_max 2_048

  @type t :: %{
          title: String.t() | nil,
          description: String.t() | nil,
          image_url: String.t() | nil,
          image_width: pos_integer() | nil,
          image_height: pos_integer() | nil,
          site_name: String.t() | nil,
          author: String.t() | nil,
          og_type: String.t() | nil,
          twitter_card: String.t() | nil,
          duration_seconds: non_neg_integer() | nil
        }

  @doc "The preview fields of `html`, fetched from `page_url`. Never raises."
  @spec parse(binary(), String.t()) :: t()
  def parse(html, page_url) when is_binary(html) and is_binary(page_url) do
    case Floki.parse_document(html) do
      {:ok, doc} -> from_doc(doc, page_url)
      _ -> empty()
    end
  rescue
    _ -> empty()
  end

  @doc false
  def empty do
    %{
      title: nil,
      description: nil,
      image_url: nil,
      image_width: nil,
      image_height: nil,
      site_name: nil,
      author: nil,
      og_type: nil,
      twitter_card: nil,
      duration_seconds: nil
    }
  end

  defp from_doc(doc, page_url) do
    meta = meta_map(doc)
    get = fn keys -> Enum.find_value(keys, &present(Map.get(meta, &1))) end

    image =
      case present(Map.get(meta, "og:image:secure_url")) do
        "https://" <> _ = secure -> secure
        _ -> get.(["og:image", "og:image:url", "twitter:image", "twitter:image:src"])
      end

    %{
      title: cap(get.(["og:title", "twitter:title"]) || title_tag(doc), @title_max),
      description:
        cap(get.(["og:description", "twitter:description", "description"]), @description_max),
      image_url: absolute_http_url(image, page_url),
      image_width: positive_int(Map.get(meta, "og:image:width")),
      image_height: positive_int(Map.get(meta, "og:image:height")),
      site_name: cap(get.(["og:site_name"]), @short_max),
      author: cap(get.(["author", "article:author"]), @short_max),
      og_type: cap(get.(["og:type"]), 60),
      twitter_card: cap(get.(["twitter:card"]), 60),
      duration_seconds: duration(meta)
    }
  end

  # Every <meta> keyed by its property, name or itemprop (lowercased); the
  # first occurrence of a key wins.
  defp meta_map(doc) do
    doc
    |> Floki.find("meta")
    |> Enum.reduce(%{}, fn node, acc ->
      key =
        Enum.find_value(["property", "name", "itemprop"], fn attr ->
          case Floki.attribute(node, attr) do
            [value | _] when value != "" -> String.downcase(String.trim(value))
            _ -> nil
          end
        end)

      case {key, Floki.attribute(node, "content")} do
        {nil, _} -> acc
        {key, [content | _]} -> Map.put_new(acc, key, content)
        _ -> acc
      end
    end)
  end

  defp title_tag(doc) do
    case Floki.find(doc, "head title") ++ Floki.find(doc, "title") do
      [node | _] -> present(Floki.text(node))
      [] -> nil
    end
  end

  defp duration(meta) do
    with nil <- seconds(Map.get(meta, "og:video:duration")),
         nil <- seconds(Map.get(meta, "video:duration")) do
      iso8601_duration(Map.get(meta, "duration"))
    end
  end

  defp seconds(nil), do: nil

  defp seconds(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  @iso ~r/\AP(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)(?:\.\d+)?S)?)?\z/

  @doc false
  def iso8601_duration(nil), do: nil

  def iso8601_duration(value) do
    case Regex.run(@iso, String.trim(String.upcase(value))) do
      [_ | parts] ->
        [d, h, m, s] =
          parts
          |> Enum.concat(List.duplicate("", 4 - length(parts)))
          |> Enum.map(&if(&1 == "", do: 0, else: String.to_integer(&1)))

        total = ((d * 24 + h) * 60 + m) * 60 + s
        if total > 0, do: total, else: nil

      _ ->
        nil
    end
  end

  @doc """
  `candidate` resolved against `base`, when the result is an absolute
  `http`/`https` URL with a host; nil otherwise (including any `data:` or
  `javascript:` URL).
  """
  @spec absolute_http_url(String.t() | nil, String.t()) :: String.t() | nil
  def absolute_http_url(nil, _base), do: nil

  def absolute_http_url(candidate, base) when is_binary(candidate) do
    candidate = String.trim(candidate)

    with true <- candidate != "" and byte_size(candidate) <= @url_max,
         %URI{scheme: scheme, host: host} = uri
         when scheme in ["http", "https"] and
                is_binary(host) and host != "" <-
           URI.merge(URI.parse(base), candidate) do
      URI.to_string(uri)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp positive_int(nil), do: nil

  defp positive_int(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 and n < 100_000 -> n
      _ -> nil
    end
  end

  defp present(nil), do: nil

  defp present(value) when is_binary(value) do
    case value |> String.replace(~r/\s+/u, " ") |> String.trim() do
      "" -> nil
      v -> v
    end
  end

  @doc false
  def cap(nil, _max), do: nil
  def cap(value, max) when is_binary(value), do: value |> present() |> slice(max)

  defp slice(nil, _max), do: nil
  defp slice(value, max), do: String.slice(value, 0, max)
end
