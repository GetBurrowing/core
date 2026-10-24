defmodule Platform.Social.PlatformLimits do
  @moduledoc """
  Each platform's text limits, the fold a reader sees before "…more", the X
  thread split, and the deterministic flags a preview shows (task 01a16c4f,
  Social authoring 3/11). Pure: no DB, no process.

  Media checks are NOT duplicated here: `flags/2` runs
  `Platform.Social.MediaRules.check/3` and shows each of its sentences as a
  `media_rule` flag.

  Flags are computed facts, never judgments: there is no score of any kind
  (no virality, no quality, no "weak hook"). Each flag is
  `%{key: String.t(), text: String.t()}`; the key is what a preview puts in
  `data-flag`.

  ## Sources (each read 2026-10-23)

    * LinkedIn 3,000 characters per post:
      https://www.linkedin.com/help/linkedin/answer/a528176
    * X 280 characters per post, every URL counted as 23, wide characters
      (emoji, CJK) as 2: https://docs.x.com/fundamentals/counting-characters
    * Instagram caption 2,200 characters and 30 hashtags; images 4:5 to
      1.91:1, Reels recommended 9:16:
      https://developers.facebook.com/docs/instagram-platform/instagram-graph-api/reference/ig-user/media
    * TikTok caption 2,200 UTF-16 runes:
      https://developers.tiktok.com/doc/content-posting-api-reference-direct-post
    * YouTube title 100 characters, description 5,000:
      https://support.google.com/youtube/answer/57404
    * YouTube ignores every hashtag on a video with more than 60:
      https://support.google.com/youtube/answer/6390658

  No platform documents its fold. The fold numbers below are ASSUMED from
  how each app renders a feed item, and marked as such where they are set.
  The same goes for which captions make links clickable on TikTok and
  YouTube Shorts.
  """

  alias Platform.Social.MediaRules

  @type platform :: String.t()
  @type flag :: %{key: String.t(), text: String.t()}

  @limits %{
    "linkedin" => %{
      label: "LinkedIn",
      # https://www.linkedin.com/help/linkedin/answer/a528176 (read 2026-10-23)
      max_body: 3000,
      # ASSUMED (read 2026-10-23, no official source): the feed cuts a post
      # at about 210 characters or 3 lines, whichever comes first, and adds
      # "…see more".
      fold: 210,
      fold_lines: 3,
      fold_label: "…see more",
      links_clickable?: true,
      # No documented hashtag cap.
      hashtag_cap: nil,
      # ASSUMED: a single feed image renders at up to 1.91:1 landscape;
      # a link card's image is 1.91:1.
      media_ratio: "1.91:1"
    },
    "x" => %{
      label: "X",
      # https://docs.x.com/fundamentals/counting-characters (read 2026-10-23)
      max_body: 280,
      # A post of at most 280 is shown in full, so the fold is the post.
      fold: 280,
      fold_lines: nil,
      fold_label: "Show more",
      links_clickable?: true,
      hashtag_cap: nil,
      # https://docs.x.com/fundamentals/counting-characters (read 2026-10-23):
      # every URL counts as 23.
      url_weight: 23,
      # ASSUMED: the timeline crops a single image to 16:9.
      media_ratio: "16:9"
    },
    "instagram" => %{
      label: "Instagram",
      # https://developers.facebook.com/docs/instagram-platform/instagram-graph-api/reference/ig-user/media
      # (read 2026-10-23): "Maximum 2200 characters, 30 hashtags".
      max_body: 2200,
      # ASSUMED (read 2026-10-23, no official source): the feed shows about
      # 125 characters or 2 lines of caption before "… more".
      fold: 125,
      fold_lines: 2,
      fold_label: "… more",
      # Instagram captions never make a URL a link (same source's caption
      # field takes plain text; the app renders it as text).
      links_clickable?: false,
      hashtag_cap: 30,
      # Same source: images 4:5 to 1.91:1; Reels recommended 9:16.
      media_ratio: "4:5",
      video_ratio: "9:16"
    },
    "youtube" => %{
      label: "YouTube",
      # https://support.google.com/youtube/answer/57404 (read 2026-10-23):
      # description 5,000, title 100.
      max_body: 5000,
      max_title: 100,
      title_required?: true,
      # ASSUMED (read 2026-10-23, no official source): a Short's description
      # panel shows about 100 characters before "…more".
      fold: 100,
      fold_lines: 2,
      fold_label: "…more",
      # ASSUMED: YouTube stopped making links in Shorts descriptions
      # clickable in 2023.
      links_clickable?: false,
      # https://support.google.com/youtube/answer/6390658 (read 2026-10-23):
      # more than 60 hashtags and every one is ignored.
      hashtag_cap: 60,
      media_ratio: "9:16"
    },
    "tiktok" => %{
      label: "TikTok",
      # https://developers.tiktok.com/doc/content-posting-api-reference-direct-post
      # (read 2026-10-23): "The maximum length is 2200 in UTF-16 runes."
      max_body: 2200,
      # ASSUMED (read 2026-10-23, no official source): the caption overlay
      # shows about 80 characters or 2 lines before "more".
      fold: 80,
      fold_lines: 2,
      fold_label: "more",
      # ASSUMED: TikTok captions render URLs as plain text.
      links_clickable?: false,
      hashtag_cap: nil,
      media_ratio: "9:16"
    }
  }

  @url_re ~r{https?://[^\s]+}iu
  @hashtag_re ~r/(?:^|\s)#[\p{L}\p{N}_]+/u

  @doc "Platforms with limits (the same set as `Platform.Social.Account.platforms/0`)."
  @spec platforms() :: [platform()]
  def platforms, do: ~w(linkedin x instagram youtube tiktok)

  @doc "The limits map for `platform`, or nil for an unknown platform."
  @spec get(platform()) :: map() | nil
  def get(platform), do: Map.get(@limits, platform)

  @doc "The platform's display label (`\"LinkedIn\"`), or the raw value when unknown."
  @spec label(platform()) :: String.t()
  def label(platform), do: (get(platform) || %{label: to_string(platform)}).label

  # ── Counting ─────────────────────────────────────────────────────────

  @doc """
  The length the platform counts. X weighs every URL as 23 and a wide
  character (emoji, CJK) as 2; every other platform counts graphemes.
  """
  @spec count(platform(), String.t() | nil) :: non_neg_integer()
  def count(_platform, nil), do: 0
  def count("x", text), do: x_length(text)
  def count(_platform, text), do: String.length(text)

  defp x_length(text) do
    @url_re
    |> Regex.split(text, include_captures: true)
    |> Enum.with_index()
    |> Enum.reduce(0, fn
      {_url, i}, acc when rem(i, 2) == 1 ->
        acc + @limits["x"].url_weight

      {plain, _}, acc ->
        acc + (plain |> String.graphemes() |> Enum.map(&x_weight/1) |> Enum.sum())
    end)
  end

  # twitter-text v3: weight 1 for code points in these ranges, 2 otherwise.
  defp x_weight(grapheme) do
    if grapheme |> String.to_charlist() |> Enum.all?(&light?/1), do: 1, else: 2
  end

  defp light?(cp),
    do:
      cp in 0..4351 or cp in 8192..8205 or cp in 8208..8223 or cp in 8242..8247 or
        cp in [0xFE0F, 0x200D]

  @doc "Hashtags in `text` (`#word`), in order."
  @spec hashtags(String.t() | nil) :: [String.t()]
  def hashtags(nil), do: []

  def hashtags(text),
    do: @hashtag_re |> Regex.scan(text) |> Enum.map(fn [tag] -> String.trim(tag) end)

  @doc "URLs written in `text`."
  @spec urls(String.t() | nil) :: [String.t()]
  def urls(nil), do: []
  def urls(text), do: @url_re |> Regex.scan(text) |> Enum.map(&hd/1)

  # ── The fold ─────────────────────────────────────────────────────────

  @doc """
  `{visible, truncated?}`: what the reader sees before the platform's
  "…more". Cut at the platform's `fold` characters or `fold_lines` lines,
  whichever comes first; a cut inside a word backs off to the word's start
  when that loses at most 20 characters. `visible` is never longer than
  `fold`.
  """
  @spec fold(platform(), String.t() | nil) :: {String.t(), boolean()}
  def fold(_platform, nil), do: {"", false}

  def fold(platform, text) do
    case get(platform) do
      nil -> {text, false}
      %{fold: fold} = limits -> fold_text(String.trim_trailing(text), fold, limits[:fold_lines])
    end
  end

  defp fold_text(text, fold, lines) do
    {by_lines, cut_by_lines?} = cut_lines(text, lines)

    cond do
      String.length(by_lines) > fold ->
        {cut_chars(by_lines, fold), true}

      cut_by_lines? ->
        {String.trim_trailing(by_lines), true}

      true ->
        {text, false}
    end
  end

  defp cut_lines(text, nil), do: {text, false}

  defp cut_lines(text, lines) do
    parts = String.split(text, "\n")

    if length(parts) > lines,
      do: {parts |> Enum.take(lines) |> Enum.join("\n"), true},
      else: {text, false}
  end

  defp cut_chars(text, fold) do
    head = String.slice(text, 0, fold)
    next = String.at(text, fold)

    cut =
      if next in [nil, " ", "\n"] do
        head
      else
        case Regex.run(~r/^(.*)\s\S*$/su, head) do
          [_, before] when byte_size(before) > 0 ->
            if String.length(head) - String.length(before) <= 20, do: before, else: head

          _ ->
            head
        end
      end

    String.trim_trailing(cut)
  end

  # ── X threads ────────────────────────────────────────────────────────

  @doc """
  The body as an X thread. A body within 280 is one post with no number. A
  longer one splits at word boundaries into posts that each fit 280
  INCLUDING their `" i/n"` suffix. Each post is
  `%{text, index, total, count, limit}`; `count` is the weighted X length of
  `text`.
  """
  @spec thread(String.t() | nil) :: [map()]
  def thread(body) do
    body = String.trim(body || "")
    limit = @limits["x"].max_body

    if x_length(body) <= limit do
      [%{text: body, index: 1, total: 1, count: x_length(body), limit: limit}]
    else
      chunks = split_thread(body, limit, 2)
      total = length(chunks)

      chunks
      |> Enum.with_index(1)
      |> Enum.map(fn {chunk, i} ->
        text = "#{chunk} #{i}/#{total}"
        %{text: text, index: i, total: total, count: x_length(text), limit: limit}
      end)
    end
  end

  # Packs with a budget that leaves room for " n/n" at the guessed total's
  # width, and repacks if the total turns out to need more digits.
  defp split_thread(body, limit, guess) do
    digits = guess |> Integer.to_string() |> String.length()
    budget = limit - (1 + 2 * digits + 1)
    chunks = pack(body, budget)
    total = length(chunks)

    if total |> Integer.to_string() |> String.length() > digits,
      do: split_thread(body, limit, total),
      else: chunks
  end

  defp pack(body, budget) do
    ~r/\s+/u
    |> Regex.split(body, include_captures: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(&hard_split(&1, budget))
    |> Enum.reduce({[], ""}, fn token, {done, current} ->
      candidate = current <> token

      cond do
        current == "" and String.trim(token) == "" -> {done, current}
        x_length(String.trim_trailing(candidate)) <= budget -> {done, candidate}
        true -> close(current, token, budget, done)
      end
    end)
    |> then(fn {done, current} -> Enum.reverse([String.trim(current) | done]) end)
    |> Enum.reject(&(&1 == ""))
  end

  # Closes the current post. When the post holds a sentence or paragraph
  # end in its last 40%, the cut moves back to it and the tail carries over
  # to the next post, so a post rarely ends mid-sentence.
  defp close(current, token, budget, done) do
    case boundary_split(current, budget) do
      {head, tail} ->
        carried = tail <> token

        if x_length(String.trim(carried)) <= budget,
          do: {[head | done], String.trim_leading(carried)},
          else: {[String.trim(current) | done], String.trim_leading(token)}

      nil ->
        {[String.trim(current) | done], String.trim_leading(token)}
    end
  end

  @boundary_re ~r/[.!?…]["'”’)\]]?\s+|\n\s*/u

  defp boundary_split(current, budget) do
    min = budget * 0.6

    @boundary_re
    |> Regex.scan(current, return: :index)
    |> Enum.map(fn [{start, len}] -> start + len end)
    |> Enum.reverse()
    |> Enum.find_value(fn at ->
      head = current |> binary_part(0, at) |> String.trim()
      tail = binary_part(current, at, byte_size(current) - at)

      if x_length(head) >= min and String.trim(tail) != "", do: {head, tail}
    end)
  end

  # A single word longer than a post is cut by grapheme.
  defp hard_split(token, budget) do
    if x_length(token) <= budget do
      [token]
    else
      token
      |> String.graphemes()
      |> Enum.chunk_while(
        "",
        fn g, acc ->
          if x_length(acc <> g) <= budget, do: {:cont, acc <> g}, else: {:cont, acc, g}
        end,
        fn acc -> {:cont, acc, ""} end
      )
    end
  end

  # ── Flags ────────────────────────────────────────────────────────────

  @doc """
  The deterministic flags for a draft on `platform`. `post` is a map with
  any of `body`, `title`, `link_url`, `media` (the `MediaRules` item shape
  plus `alt`), `account` (`approval_mode`, `status`,
  `platform_account_type`) and `banned` (the profile's banned phrases,
  `profile.voice.banned`). Keys are atoms or strings.

  Flag keys: `account_disconnected`, `posts_by_hand`, `over_limit`,
  `thread_needed`, `missing_title`, `title_over_limit`, `missing_alt`,
  `link_not_clickable`, `too_many_hashtags`, `media_rule`, `banned_phrase`
  (Social authoring 4/11: a warning for a human; an agent's draft with one
  is refused in `Platform.Social.AgentDrafts`).
  """
  @spec flags(platform(), map()) :: [flag()]
  def flags(platform, post) when is_map(post) do
    limits = get(platform)
    body = fetch(post, :body) || ""
    account = fetch(post, :account)
    media = fetch(post, :media) || []

    if limits do
      [
        account_flags(account),
        body_flags(platform, limits, body),
        title_flags(limits, fetch(post, :title)),
        alt_flags(media),
        link_flags(limits, body, fetch(post, :link_url)),
        hashtag_flags(limits, body),
        media_flags(platform, account, media),
        banned_flags(body, fetch(post, :banned))
      ]
      |> List.flatten()
    else
      [%{key: "unsupported_platform", text: "#{inspect(platform)} is not a supported platform"}]
    end
  end

  defp banned_flags(body, banned) when is_list(banned) do
    case Platform.Social.Voice.banned_phrase(body, banned) do
      nil -> []
      phrase -> [%{key: "banned_phrase", text: "Uses a banned phrase: \"#{phrase}\""}]
    end
  end

  defp banned_flags(_body, _banned), do: []

  defp account_flags(nil), do: []

  defp account_flags(account) do
    [
      if(fetch(account, :status) != "connected",
        do: %{key: "account_disconnected", text: "Account disconnected: reconnect it to post"}
      ),
      if(fetch(account, :approval_mode) == "draft_only",
        do: %{key: "posts_by_hand", text: "You post this yourself: copy it into the app"}
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp body_flags("x", _limits, body) do
    case thread(body) do
      [_] ->
        []

      posts ->
        [%{key: "thread_needed", text: "X thread needs #{length(posts)} posts"}]
    end
  end

  defp body_flags(platform, %{max_body: max} = limits, body) do
    count = count(platform, body)

    if count > max,
      do: [
        %{
          key: "over_limit",
          text:
            "#{number(count)} / #{number(max)} characters: #{number(count - max)} over #{limits.label}'s limit"
        }
      ],
      else: []
  end

  defp title_flags(%{title_required?: true, max_title: max}, title) do
    title = String.trim(title || "")
    count = String.length(title)

    cond do
      title == "" -> [%{key: "missing_title", text: "YouTube needs a title"}]
      count > max -> [%{key: "title_over_limit", text: "Title #{count} / #{max} characters"}]
      true -> []
    end
  end

  defp title_flags(_limits, _title), do: []

  defp alt_flags(media) do
    missing = Enum.filter(media, &(String.trim(fetch(&1, :alt) || "") == ""))
    {videos, images} = Enum.split_with(missing, &video?/1)

    [
      alt_flag(length(images), "image", "images"),
      alt_flag(length(videos), "video", "videos")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp alt_flag(0, _one, _many), do: nil
  defp alt_flag(1, one, _many), do: %{key: "missing_alt", text: "1 #{one} without alt text"}
  defp alt_flag(n, _one, many), do: %{key: "missing_alt", text: "#{n} #{many} without alt text"}

  defp link_flags(%{links_clickable?: false, label: label}, body, link_url) do
    if urls(body) != [] or (is_binary(link_url) and link_url != ""),
      do: [%{key: "link_not_clickable", text: "Links can't be clicked on #{label}"}],
      else: []
  end

  defp link_flags(_limits, _body, _link_url), do: []

  defp hashtag_flags(%{hashtag_cap: cap, label: label}, body) when is_integer(cap) do
    count = body |> hashtags() |> length()

    if count > cap,
      do: [%{key: "too_many_hashtags", text: "#{count} hashtags: #{label} allows #{cap}"}],
      else: []
  end

  defp hashtag_flags(_limits, _body), do: []

  defp media_flags(platform, account, media) do
    items = Enum.map(media, &media_item/1)

    case MediaRules.check(platform, account && atomize_account(account), items) do
      :ok -> []
      {:error, messages} -> Enum.map(messages, &%{key: "media_rule", text: &1})
    end
  end

  defp media_item(m) do
    %{
      content_type: fetch(m, :content_type),
      byte_size: fetch(m, :byte_size),
      duration_s: fetch(m, :duration_s),
      width: fetch(m, :width),
      height: fetch(m, :height)
    }
  end

  defp atomize_account(account),
    do: %{platform_account_type: fetch(account, :platform_account_type)}

  @doc "True when a media item is a video (by `content_type`)."
  @spec video?(map()) :: boolean()
  def video?(m), do: String.starts_with?(fetch(m, :content_type) || "", "video/")

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch(_other, _key), do: nil

  defp number(n) when n >= 1000, do: "#{div(n, 1000)},#{n |> rem(1000) |> pad3()}"
  defp number(n), do: Integer.to_string(n)

  defp pad3(n), do: n |> Integer.to_string() |> String.pad_leading(3, "0")
end
