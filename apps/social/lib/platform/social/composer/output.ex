defmodule Platform.Social.Composer.Output do
  @moduledoc """
  Parses the composer's model replies against CLOSED shapes (task 01a14aca,
  Composer 1/5; Social authoring 6/11, task 01a16c50). A reply is one JSON
  object with exactly the expected keys and string values; one surrounding
  code fence is tolerated. Anything else is `{:error, :invalid_output}`,
  which the composer turns into that one column's error.

    * `linkedin`, `instagram`, `tiktok`: `{"text", "why_shape"}`.
    * `youtube`: `{"title", "description", "why_shape"}`; the description
      is the post body, the title rides beside it.
    * `x`: `{"posts": [string, ...], "why_shape"}`. The posts are joined
      into ONE body with blank lines, and the thread shown is
      `Platform.Social.PlatformLimits.thread/1` of that body: the same split,
      numbering and weighted counts the preview and every other X surface
      use, so the composer never numbers a thread one way and the preview
      another. A body within 280 is one post with no number.

  Every result is `%{text, title, posts, why_shape}`; `title` is nil except
  on YouTube and `posts` is nil except on X.
  """

  alias Platform.Social.PlatformLimits

  @spec parse_adaptation(String.t(), String.t()) :: {:ok, map()} | {:error, :invalid_output}
  def parse_adaptation(platform, content) when platform in ~w(linkedin instagram tiktok) do
    with {:ok, %{"text" => text, "why_shape" => why}} <- decode(content, ~w(text why_shape)),
         true <- present?(text) and present?(why) do
      {:ok, %{text: String.trim(text), title: nil, posts: nil, why_shape: String.trim(why)}}
    else
      _ -> {:error, :invalid_output}
    end
  end

  def parse_adaptation("youtube", content) do
    with {:ok, %{"title" => title, "description" => text, "why_shape" => why}} <-
           decode(content, ~w(title description why_shape)),
         true <- present?(title) and present?(text) and present?(why) do
      {:ok,
       %{
         text: String.trim(text),
         title: String.trim(title),
         posts: nil,
         why_shape: String.trim(why)
       }}
    else
      _ -> {:error, :invalid_output}
    end
  end

  def parse_adaptation("x", content) do
    with {:ok, %{"posts" => posts, "why_shape" => why}} <- decode(content, ~w(posts why_shape)),
         true <- is_list(posts) and posts != [] and Enum.all?(posts, &present?/1),
         true <- present?(why) do
      text = posts |> Enum.map(&String.trim/1) |> Enum.join("\n\n")

      {:ok,
       %{text: text, title: nil, posts: PlatformLimits.thread(text), why_shape: String.trim(why)}}
    else
      _ -> {:error, :invalid_output}
    end
  end

  def parse_adaptation(_platform, _content), do: {:error, :invalid_output}

  defp decode(content, keys) when is_binary(content) do
    case Jason.decode(unfence(content)) do
      {:ok, map} when is_map(map) ->
        if Enum.sort(Map.keys(map)) == Enum.sort(keys), do: {:ok, map}, else: :error

      _ ->
        :error
    end
  end

  defp decode(_content, _keys), do: :error

  defp unfence(content) do
    trimmed = String.trim(content)

    case Regex.run(~r/\A```(?:json)?\s*\n(.*)\n```\z/s, trimmed) do
      [_, inner] -> inner
      nil -> trimmed
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
