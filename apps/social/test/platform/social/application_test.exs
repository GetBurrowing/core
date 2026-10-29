defmodule Platform.Social.ApplicationTest do
  @moduledoc """
  Social's web-role partition (task 01a155a6): every child Social's
  application starts is classified by child id, and the web role never starts
  the render queue, which re-queues clips from the DB when it starts.
  """

  use ExUnit.Case, async: true

  alias Platform.Social.Application, as: App

  test "every child is classified, and the two sets are disjoint" do
    ids = Enum.map(App.children(:full), &Platform.Role.child_id/1)
    unclassified = ids -- (App.web_ids() ++ App.background_ids())
    assert unclassified == [], "unclassified Social children: #{inspect(unclassified)}"
    assert MapSet.disjoint?(MapSet.new(App.web_ids()), MapSet.new(App.background_ids()))
  end

  test "the web role starts only the ETS owners" do
    ids = Enum.map(App.children(:web), &Platform.Role.child_id/1)
    assert ids == [Platform.Social.Publisher.Fake, Platform.Social.RateLimit]
    refute Platform.Social.RenderQueue in ids
    refute Platform.Social.RenderTaskSupervisor in ids
    refute Platform.Social.PublishRetry in ids
    refute Platform.Social.ClipPublish in ids
    refute Platform.Social.EpisodeDiscovery in ids
    refute Platform.Social.AnalyticsSync in ids
  end

  test ":full keeps today's children in today's order" do
    assert Enum.map(App.children(:full), &Platform.Role.child_id/1) == [
             Platform.Social.Publisher.Fake,
             Platform.Social.RateLimit,
             Platform.Social.RenderTaskSupervisor,
             Platform.Social.RenderQueue,
             Platform.Social.PublishRetry,
             Platform.Social.ClipPublish,
             Platform.Social.EpisodeDiscovery,
             Platform.Social.AnalyticsSync
           ]
  end
end
