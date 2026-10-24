defmodule Platform.Chat.LinkSites do
  @moduledoc """
  Turns an outside URL into a readable preview with no network fetch (link
  previews stage 1; mockup canvas 01a16ed5, options 2 and 3).

  `describe/1` matches the host against eighteen known sites and parses the
  path into a page kind and a title ("Pull request #1365", "Issue ENG-482",
  "Post by @handle"); where the URL carries a slug it becomes the title
  ("Checkout redesign"). Any other host gets the last path slug prettified,
  or the bare host, and a monogram letter whose colour slot is a hash of the
  host, so one site always gets the same tile.

  Pure: no database, no network, no rendering. The glyphs and brand colours
  live in `PlatformWeb.Components.LinkSiteGlyphs`.
  """

  @type site ::
          :github
          | :gitlab
          | :youtube
          | :vimeo
          | :loom
          | :gdocs
          | :gsheets
          | :gslides
          | :figma
          | :linear
          | :notion
          | :x
          | :slack
          | :jira
          | :stackoverflow
          | :wikipedia
          | :dropbox
          | :zoom

  @type preview :: %{
          site: site() | nil,
          site_name: String.t(),
          kind: String.t() | nil,
          title: String.t(),
          meta: String.t(),
          video?: boolean(),
          monogram: String.t() | nil,
          slot: String.t() | nil
        }

  @sites [
    github: "GitHub",
    gitlab: "GitLab",
    youtube: "YouTube",
    vimeo: "Vimeo",
    loom: "Loom",
    gdocs: "Google Docs",
    gsheets: "Google Sheets",
    gslides: "Google Slides",
    figma: "Figma",
    linear: "Linear",
    notion: "Notion",
    x: "X",
    slack: "Slack",
    jira: "Jira",
    stackoverflow: "Stack Overflow",
    wikipedia: "Wikipedia",
    dropbox: "Dropbox",
    zoom: "Zoom"
  ]

  # The rung-3 agent colour slots a monogram may take. Orange is left out:
  # it reads as Burrow's own accent.
  @slots ~w(teal green amber blue purple brick rose indigo lime)

  @doc "The known sites, in legend order, with their display names."
  @spec sites() :: [{site(), String.t()}]
  def sites, do: @sites

  @doc "The colour slots a monogram can take."
  @spec slots() :: [String.t()]
  def slots, do: @slots

  @doc "The display name of a known site."
  @spec site_name(site()) :: String.t()
  def site_name(site), do: Keyword.fetch!(@sites, site)

  @doc """
  The preview of `url`: `site` (nil for an unknown host), `kind` (nil when
  nothing is known), `title`, a one-line `meta` ("GitHub · acme/api"),
  `video?`, and for an unknown host a `monogram` letter and colour `slot`.
  """
  @spec describe(String.t()) :: preview()
  def describe(url) when is_binary(url) do
    uri = URI.parse(url)
    host = (uri.host || "") |> String.downcase() |> String.replace_prefix("www.", "")
    segs = segments(uri.path)
    query = URI.decode_query(uri.query || "")

    case host |> site_of() |> refine(segs) do
      nil -> unknown(host, segs)
      site -> known(site, parse(site, host, segs, query))
    end
  end

  @doc "The monogram slot for `host`: the same host always gets the same slot."
  @spec slot_for(String.t()) :: String.t()
  def slot_for(host), do: Enum.at(@slots, :erlang.phash2(host, length(@slots)))

  @doc """
  A URL slug as words: `onboarding-checklist_v2` -> "Onboarding checklist v2".
  A trailing id (Notion's 32 hex, a numeric id) and a file extension are
  dropped. Returns nil when the segment is an opaque id, not words.
  """
  @spec prettify(String.t() | nil) :: String.t() | nil
  def prettify(nil), do: nil

  def prettify(seg) do
    words =
      seg
      |> decode()
      |> String.replace(~r/\.(html?|php|aspx?)\z/i, "")
      |> String.replace(~r/[-_](?=[0-9a-f]*[0-9])[0-9a-f]{12,}\z/i, "")
      |> String.replace(~r/\A[0-9a-f]{32}\z/i, "")
      |> String.split(~r/[-_+\s]+/, trim: true)

    cond do
      words == [] -> nil
      not Enum.any?(words, &Regex.match?(~r/\p{L}{2,}/u, &1)) -> nil
      length(words) == 1 and opaque?(hd(words)) -> nil
      true -> words |> Enum.join(" ") |> capitalize() |> clip(80)
    end
  end

  # ── hosts ────────────────────────────────────────────────────────────

  defp site_of("github.com"), do: :github
  defp site_of("gitlab.com"), do: :gitlab
  defp site_of(h) when h in ["youtube.com", "m.youtube.com", "youtu.be"], do: :youtube
  defp site_of(h) when h in ["vimeo.com", "player.vimeo.com"], do: :vimeo
  defp site_of("loom.com"), do: :loom
  defp site_of("docs.google.com"), do: :gdocs
  defp site_of("figma.com"), do: :figma
  defp site_of("linear.app"), do: :linear
  defp site_of(h) when h in ["notion.so", "notion.site"], do: :notion
  defp site_of(h) when h in ["x.com", "twitter.com", "mobile.twitter.com"], do: :x
  defp site_of("stackoverflow.com"), do: :stackoverflow
  defp site_of(h) when h in ["dropbox.com", "dl.dropboxusercontent.com"], do: :dropbox
  defp site_of("zoom.us"), do: :zoom

  defp site_of(host) do
    cond do
      String.ends_with?(host, ".notion.site") -> :notion
      String.ends_with?(host, ".slack.com") or host == "slack.com" -> :slack
      String.ends_with?(host, ".atlassian.net") -> :jira
      String.ends_with?(host, ".wikipedia.org") -> :wikipedia
      String.ends_with?(host, ".zoom.us") -> :zoom
      true -> nil
    end
  end

  # One Google host serves three products; the path says which.
  defp refine(:gdocs, ["spreadsheets" | _]), do: :gsheets
  defp refine(:gdocs, ["presentation" | _]), do: :gslides
  defp refine(site, _segs), do: site

  # ── per-site paths: {kind, title, context} ───────────────────────────

  defp parse(:github, _h, [o, r, "pull", n | _], _q),
    do: {"Pull request", "Pull request ##{n}", "#{o}/#{r}"}

  defp parse(:github, _h, [o, r, "issues", n | _], _q), do: {"Issue", "Issue ##{n}", "#{o}/#{r}"}

  defp parse(:github, _h, [o, r, "discussions", n | _], _q),
    do: {"Discussion", "Discussion ##{n}", "#{o}/#{r}"}

  defp parse(:github, _h, [o, r, "commit", sha | _], _q),
    do: {"Commit", "Commit #{String.slice(sha, 0, 7)}", "#{o}/#{r}"}

  defp parse(:github, _h, [o, r, "releases", "tag", tag | _], _q),
    do: {"Release", "Release #{decode(tag)}", "#{o}/#{r}"}

  defp parse(:github, _h, [o, r, kind, _ref | rest], _q)
       when kind in ["blob", "tree"] and rest != [],
       do: {if(kind == "blob", do: "File", else: "Folder"), decode(List.last(rest)), "#{o}/#{r}"}

  defp parse(:github, _h, [o, r | _], _q), do: {"Repository", "#{o}/#{r}", nil}
  defp parse(:github, _h, [o], _q), do: {"Profile", o, nil}

  defp parse(:gitlab, _h, segs, _q) do
    {project, rest} = Enum.split_while(segs, &(&1 != "-"))
    repo = Enum.join(project, "/")

    case rest do
      ["-", "merge_requests", n | _] -> {"Merge request", "Merge request !#{n}", repo}
      ["-", "issues", n | _] -> {"Issue", "Issue ##{n}", repo}
      _ when length(project) >= 2 -> {"Repository", repo, nil}
      _ -> {nil, nil, nil}
    end
  end

  defp parse(:youtube, "youtu.be", [_id | _], _q), do: {"Video", "YouTube video", nil}
  defp parse(:youtube, _h, ["shorts", _ | _], _q), do: {"Video", "YouTube Short", nil}
  defp parse(:youtube, _h, ["watch"], %{"v" => _}), do: {"Video", "YouTube video", nil}
  defp parse(:youtube, _h, ["live", _ | _], _q), do: {"Video", "YouTube live video", nil}
  defp parse(:youtube, _h, ["playlist"], _q), do: {"Playlist", "YouTube playlist", nil}

  defp parse(:youtube, _h, ["@" <> handle | _], _q), do: {"Channel", "@" <> handle, nil}

  defp parse(:vimeo, _h, segs, _q) do
    if Enum.any?(segs, &Regex.match?(~r/\A\d+\z/, &1)),
      do: {"Video", "Vimeo video", nil},
      else: {nil, nil, nil}
  end

  defp parse(:loom, _h, [kind, slug | _], _q) when kind in ["share", "embed"],
    do: {"Video", prettify(slug) || "Loom video", nil}

  defp parse(:gdocs, _h, ["document" | _], _q), do: {"Doc", "Google Doc", nil}
  defp parse(:gsheets, _h, _segs, _q), do: {"Sheet", "Google Sheet", nil}
  defp parse(:gslides, _h, _segs, _q), do: {"Slides", "Google Slides deck", nil}
  defp parse(:gdocs, _h, ["forms" | _], _q), do: {"Form", "Google Form", nil}

  defp parse(:figma, _h, [kind, _key | rest], q)
       when kind in ["file", "design", "proto", "board"] do
    label =
      case kind do
        "proto" -> "Prototype"
        "board" -> "FigJam board"
        _ -> "Design file"
      end

    frame =
      case q do
        %{"node-id" => node} when node != "" -> "frame " <> node
        _ -> nil
      end

    {label, prettify(List.first(rest)) || "Figma #{String.downcase(label)}", frame}
  end

  defp parse(:linear, _h, [_team, "issue", id | rest], _q) do
    id = String.upcase(id)

    case prettify(List.first(rest)) do
      nil -> {"Issue", "Issue #{id}", nil}
      words -> {"Issue", words, id}
    end
  end

  defp parse(:linear, _h, [_team, "project", slug | _], _q),
    do: {"Project", prettify(slug) || "Linear project", nil}

  defp parse(:notion, _h, segs, _q) when segs != [],
    do: {"Page", prettify(List.last(segs)) || "Notion page", nil}

  defp parse(:x, _h, [handle, "status", _id | _], _q), do: {"Post", "Post by @#{handle}", nil}

  defp parse(:x, _h, [handle], _q)
       when handle not in ["home", "explore", "search", "i", "settings", "notifications"],
       do: {"Profile", "@" <> handle, nil}

  defp parse(:slack, _h, ["archives", _channel, "p" <> _ | _], _q),
    do: {"Message", "Slack message", nil}

  defp parse(:slack, _h, ["archives", _channel | _], _q), do: {"Channel", "Slack channel", nil}

  defp parse(:jira, _h, segs, _q) do
    case Enum.find(segs, &Regex.match?(~r/\A[A-Z][A-Z0-9]+-\d+\z/, &1)) do
      nil -> {nil, nil, nil}
      key -> {"Issue", "Issue " <> key, nil}
    end
  end

  defp parse(:stackoverflow, _h, ["questions", n | rest], _q),
    do: {"Question", prettify(List.first(rest)) || "Question #{n}", nil}

  defp parse(:wikipedia, _h, ["wiki", title | _], _q),
    do: {"Article", title |> decode() |> String.replace("_", " ") |> clip(80), nil}

  defp parse(:dropbox, _h, ["scl", "fo" | _], _q), do: {"Folder", "Dropbox folder", nil}

  defp parse(:dropbox, _h, [first | _] = segs, _q) when first in ["s", "scl", "sh"],
    do: {"File", segs |> List.last() |> decode() |> clip(80), nil}

  defp parse(:zoom, _h, ["j", _ | _], _q), do: {"Meeting", "Zoom meeting", nil}
  defp parse(:zoom, _h, ["rec" | _], _q), do: {"Recording", "Zoom recording", nil}

  defp parse(_site, _h, _segs, _q), do: {nil, nil, nil}

  # ── assembling ───────────────────────────────────────────────────────

  defp known(site, {kind, title, context}) do
    name = site_name(site)
    title = title || name

    meta =
      [name, kind && not contains?(title, kind) && kind, context]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.join(" · ")

    %{
      site: site,
      site_name: name,
      kind: kind,
      title: title,
      meta: meta,
      video?: kind == "Video",
      monogram: nil,
      slot: nil
    }
  end

  defp unknown(host, segs) do
    words = segs |> Enum.reverse() |> Enum.find_value(&prettify/1)

    parent =
      case segs do
        [p, _last] -> prettify(p)
        _ -> nil
      end

    %{
      site: nil,
      site_name: host,
      kind: nil,
      title: words || host,
      meta:
        if(words, do: Enum.join(Enum.reject([host, parent], &is_nil/1), " · "), else: "Website"),
      video?: false,
      monogram: monogram(host),
      slot: slot_for(host)
    }
  end

  defp monogram(""), do: "?"

  defp monogram(host) do
    case Regex.run(~r/[\p{L}\p{N}]/u, host) do
      [ch] -> String.upcase(ch)
      _ -> "?"
    end
  end

  defp segments(nil), do: []
  defp segments(path), do: String.split(path, "/", trim: true)

  defp decode(seg) do
    URI.decode(seg)
  rescue
    ArgumentError -> seg
  end

  # An opaque token rather than a word: long, and mixing letters and digits.
  defp opaque?(word),
    do: String.length(word) >= 8 and Regex.match?(~r/\d/, word) and Regex.match?(~r/\p{L}/u, word)

  defp contains?(title, kind), do: String.contains?(String.downcase(title), String.downcase(kind))

  defp capitalize(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp capitalize(s), do: s

  defp clip(s, n) do
    if String.length(s) > n, do: String.slice(s, 0, n - 1) <> "…", else: s
  end
end
