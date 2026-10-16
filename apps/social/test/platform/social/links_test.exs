defmodule Platform.Social.LinksTest do
  use ExUnit.Case, async: true

  alias Platform.Social.Links

  @channel "https://www.youtube.com/@htc"

  describe "effective_link/4" do
    test "an explicit link_url is returned unchanged, whatever else is set" do
      assert Links.effective_link("https://x.test/a?si=1", @channel, "https://youtu.be/abc123", 9) ==
               "https://x.test/a?si=1"
    end

    test "no link and no YouTube episode: the profile's home_url, unchanged" do
      assert Links.effective_link(nil, @channel, nil, nil) == @channel
      assert Links.effective_link("", @channel, "https://podcast.test/ep/1", 30) == @channel
    end

    test "a channel home_url with a start_s gets no t param (it is not a video)" do
      assert Links.effective_link(nil, @channel, nil, 125.7) == @channel
    end

    test "youtu.be with si= tracking and a start_s normalises to watch?v=ID&t=<trunc>" do
      assert Links.effective_link(nil, @channel, "https://youtu.be/abc123?si=x", 125.7) ==
               "https://www.youtube.com/watch?v=abc123&t=125"
    end

    test "watch?v= with t=99 already present gets exactly one t, the new one" do
      link =
        Links.effective_link(nil, @channel, "https://www.youtube.com/watch?v=abc123&t=99", 30)

      assert link == "https://www.youtube.com/watch?v=abc123&t=30"
      assert length(Regex.scan(~r/[?&]t=/, link)) == 1
    end

    test "m.youtube.com and bare youtube.com forms normalise to www, si dropped" do
      for url <- [
            "https://m.youtube.com/watch?v=abc123&si=zz",
            "http://youtube.com/watch?si=zz&v=abc123",
            "https://www.youtu.be/abc123"
          ] do
        assert Links.effective_link(nil, nil, url, 5) ==
                 "https://www.youtube.com/watch?v=abc123&t=5"
      end
    end

    test "a YouTube video home_url gets the t param when there is no episode" do
      assert Links.effective_link(nil, "https://youtu.be/home99", nil, 12) ==
               "https://www.youtube.com/watch?v=home99&t=12"
    end

    test "a YouTube video with no start_s is returned unchanged" do
      assert Links.effective_link(nil, @channel, "https://youtu.be/abc123?si=x", nil) ==
               "https://youtu.be/abc123?si=x"
    end

    test "nothing to link: nil" do
      assert Links.effective_link(nil, nil, nil, 3) == nil
      assert Links.effective_link(nil, "  ", "https://podcast.test/1", 3) == nil
    end
  end

  describe "append_to_body/2" do
    test "appends on a new line" do
      assert Links.append_to_body("Watch this", "https://l.test") == "Watch this\nhttps://l.test"
    end

    test "never double-appends a link the body already contains" do
      body = "Watch https://l.test now"
      assert Links.append_to_body(body, "https://l.test") == body
      once = Links.append_to_body("Hi", "https://l.test")
      assert Links.append_to_body(once, "https://l.test") == once
    end

    test "no body: the link alone; no link: the body unchanged" do
      assert Links.append_to_body(nil, "https://l.test") == "https://l.test"
      assert Links.append_to_body("Hi", nil) == "Hi"
    end
  end
end
