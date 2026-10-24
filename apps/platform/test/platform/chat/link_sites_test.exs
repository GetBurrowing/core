defmodule Platform.Chat.LinkSitesTest do
  @moduledoc """
  Link previews stage 1: an outside URL becomes a title, a page kind and one
  meta line with no fetch. One case per known site, then the unknown-host
  fallback and its monogram.
  """
  use ExUnit.Case, async: true

  alias Platform.Chat.LinkSites

  defp d(url), do: LinkSites.describe(url)

  # {url, site, kind, title, meta}
  @cases [
    {"https://github.com/acme/api-gateway/pull/1365", :github, "Pull request",
     "Pull request #1365", "GitHub · acme/api-gateway"},
    {"https://github.com/acme/api-gateway/issues/1352", :github, "Issue", "Issue #1352",
     "GitHub · acme/api-gateway"},
    {"https://github.com/acme/rate-kit", :github, "Repository", "acme/rate-kit",
     "GitHub · Repository"},
    {"https://gitlab.com/acme/api/-/merge_requests/12", :gitlab, "Merge request",
     "Merge request !12", "GitLab · acme/api"},
    {"https://www.youtube.com/watch?v=Qm7dT2xk9sE", :youtube, "Video", "YouTube video",
     "YouTube"},
    {"https://youtu.be/Qm7dT2xk9sE", :youtube, "Video", "YouTube video", "YouTube"},
    {"https://vimeo.com/123456", :vimeo, "Video", "Vimeo video", "Vimeo"},
    {"https://www.loom.com/share/Retry-storm-walkthrough-8c2e41d09b7a4f11", :loom, "Video",
     "Retry storm walkthrough", "Loom · Video"},
    {"https://docs.google.com/document/d/1x8KfP2vQ7rT0mWc/edit", :gdocs, "Doc", "Google Doc",
     "Google Docs"},
    {"https://docs.google.com/spreadsheets/d/1Qp0LmN4cX/edit", :gsheets, "Sheet", "Google Sheet",
     "Google Sheets"},
    {"https://docs.google.com/presentation/d/1Ab/edit", :gslides, "Slides", "Google Slides deck",
     "Google Slides"},
    {"https://www.figma.com/design/k3PZq9/Checkout-redesign?node-id=12-480", :figma,
     "Design file", "Checkout redesign", "Figma · Design file · frame 12-480"},
    {"https://linear.app/acme/issue/ENG-482/webhook-retries-stop-after-first-timeout", :linear,
     "Issue", "Webhook retries stop after first timeout", "Linear · Issue · ENG-482"},
    {"https://linear.app/acme/issue/abc-123", :linear, "Issue", "Issue ABC-123", "Linear"},
    {"https://www.notion.so/acme/Onboarding-checklist-for-new-hires-8f3a2b91c4d04e7a", :notion,
     "Page", "Onboarding checklist for new hires", "Notion · Page"},
    {"https://x.com/ops_daily/status/1849203311", :x, "Post", "Post by @ops_daily", "X"},
    {"https://twitter.com/ops_daily/status/1849203311", :x, "Post", "Post by @ops_daily", "X"},
    {"https://acme.slack.com/archives/C024BE91L/p1700000000000", :slack, "Message",
     "Slack message", "Slack"},
    {"https://acme.atlassian.net/browse/ABC-123", :jira, "Issue", "Issue ABC-123", "Jira"},
    {"https://stackoverflow.com/questions/123/how-to-rate-limit-a-queue", :stackoverflow,
     "Question", "How to rate limit a queue", "Stack Overflow · Question"},
    {"https://en.wikipedia.org/wiki/Token_bucket", :wikipedia, "Article", "Token bucket",
     "Wikipedia · Article"},
    {"https://www.dropbox.com/scl/fi/abc123/Q3-plan.pdf?dl=0", :dropbox, "File", "Q3-plan.pdf",
     "Dropbox · File"},
    {"https://zoom.us/j/123456789", :zoom, "Meeting", "Zoom meeting", "Zoom"}
  ]

  for {url, site, kind, title, meta} <- @cases do
    test "#{site}: #{url}" do
      assert %{
               site: unquote(site),
               kind: unquote(kind),
               title: unquote(title),
               meta: unquote(meta)
             } =
               d(unquote(url))
    end
  end

  test "every one of the eighteen known sites has a case above" do
    covered = @cases |> Enum.map(&elem(&1, 1)) |> MapSet.new()
    known = LinkSites.sites() |> Keyword.keys() |> MapSet.new()
    assert MapSet.size(known) == 18
    assert covered == known
  end

  test "a known site's unparsed path falls back to the site name, no monogram" do
    assert %{site: :github, title: "GitHub", meta: "GitHub", monogram: nil, slot: nil} =
             d("https://github.com/")
  end

  test "only video pages are video" do
    assert d("https://www.youtube.com/watch?v=x").video?
    assert d("https://www.loom.com/share/8c2e41d09b7a").video?
    refute d("https://github.com/acme/rate-kit").video?
    refute d("https://example.com/watch").video?
  end

  describe "unknown hosts" do
    test "the last slug is the title, host and parent the meta" do
      assert %{site: nil, title: "Office orders", meta: "example.com · Catering"} =
               d("https://example.com/catering/office-orders")

      assert %{title: "Harbour ferry route approved after two year review", meta: "example.com"} =
               d(
                 "https://www.example.com/2026/10/22/harbour-ferry-route-approved-after-two-year-review"
               )
    end

    test "no slug: the bare host, 'Website'" do
      assert %{title: "example.com", meta: "Website"} = d("https://www.example.com/")
      assert %{title: "example.com"} = d("https://example.com/2026/10/22")
    end

    test "the monogram is the host's first letter on a slot hashed from the host" do
      a = d("https://example.com/a")
      b = d("https://example.com/somewhere/else")
      assert a.monogram == "E"
      assert a.slot == b.slot
      assert a.slot in LinkSites.slots()
      assert a.slot == LinkSites.slot_for("example.com")
    end

    test "the slot is deterministic and spreads across hosts" do
      hosts = for i <- 1..60, do: "host#{i}.example"
      slots = Enum.map(hosts, &LinkSites.slot_for/1)
      assert slots == Enum.map(hosts, &LinkSites.slot_for/1)
      assert slots |> Enum.uniq() |> length() >= 6
      refute "orange" in LinkSites.slots()
    end
  end

  describe "prettify/1" do
    test "words, extensions and trailing ids" do
      assert LinkSites.prettify("onboarding-checklist_v2") == "Onboarding checklist v2"
      assert LinkSites.prettify("pricing.html") == "Pricing"
      assert LinkSites.prettify("Notes-8f3a2b91c4d04e7a8f3a2b91c4d04e7a") == "Notes"
      assert LinkSites.prettify("caf%C3%A9-menu") == "Café menu"
    end

    test "opaque ids are not words" do
      assert LinkSites.prettify("8c2e41d09b7a") == nil
      assert LinkSites.prettify("1849203311") == nil
      assert LinkSites.prettify("a1b2c3d4e5") == nil
    end
  end
end
