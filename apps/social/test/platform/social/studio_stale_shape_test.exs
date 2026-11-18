defmodule Platform.Social.StudioStaleShapeTest do
  @moduledoc """
  Every Studio function answers a stale call with exactly
  `{:error, {:stale, %{state_rev: current, version: current}}}`, the CURRENT
  values and no other key, whichever function and whichever token (state_rev,
  version, fingerprint) was out of date. Nothing is written.
  """
  use Platform.DataCase, async: false

  import Platform.SocialStudioFixtures

  alias Platform.Social.Studio

  setup do
    %{w: studio_world!()}
  end

  # Moves `post` forward with a content edit so the caller's view is old.
  defp bump!(w, post) do
    {:ok, %{post: moved}} =
      Studio.save_version(
        w.org_id,
        post.id,
        {:human, w.approver.id},
        %{body: "moved #{System.unique_integer([:positive])}"},
        expect(post)
      )

    moved
  end

  defp at, do: DateTime.add(DateTime.utc_now(), 3_600, :second)

  defp calls(w) do
    a = w.approver.id
    o = w.org_id

    [
      approve_version: {"needs_approval", fn p, ex -> Studio.approve_version(o, p.id, a, ex) end},
      plan_post: {"approved", fn p, ex -> Studio.plan_post(o, p.id, a, ex, at()) end},
      replan: {"planned", fn p, ex -> Studio.plan_post(o, p.id, a, ex, at()) end},
      cancel_plan: {"planned", fn p, ex -> Studio.cancel_plan(o, p.id, a, ex) end},
      revoke_approval:
        {"approved",
         fn p, ex ->
           Studio.revoke_approval(
             o,
             p.id,
             a,
             Map.put(ex, :approval_id, Ecto.UUID.generate()),
             "x"
           )
         end},
      request_changes:
        {"needs_approval", fn p, ex -> Studio.request_changes(o, p.id, a, ex, "fix it") end},
      resubmit: {"rejected", fn p, ex -> Studio.resubmit(o, p.id, a, ex, "ok") end},
      save_version_edit:
        {"needs_approval",
         fn p, ex -> Studio.save_version(o, p.id, {:human, a}, %{body: "late"}, ex) end},
      save_version_retarget:
        {"needs_approval",
         fn p, ex -> Studio.save_version(o, p.id, {:human, a}, %{account_id: w.tiktok.id}, ex) end},
      save_version_agent:
        {"needs_approval",
         fn p, ex -> Studio.save_version(o, p.id, {:agent, w.agent.id}, %{body: "late"}, ex) end}
    ]
  end

  defp in_state(w, "rejected") do
    post = studio_post!(w, w.x, "needs_approval")
    {:ok, rejected} = Studio.request_changes(w.org_id, post.id, w.approver.id, expect(post), "no")
    rejected
  end

  defp in_state(w, status), do: studio_post!(w, w.x, status)

  test "an old state_rev is stale with the current rev and version, for every function", %{w: w} do
    for {name, {status, call}} <- calls(w) do
      post = in_state(w, status)
      old = expect(post)
      current = bump!(w, post)
      before = write_counts()

      assert {:error, {:stale, shape}} = call.(post, old), "#{name}"
      assert shape == %{state_rev: current.state_rev, version: current.version}, "#{name}"
      assert Map.keys(shape) |> Enum.sort() == [:state_rev, :version], "#{name}"
      assert write_counts() == before, "#{name} wrote"
      assert fresh(current) == current, "#{name} changed the post"
    end
  end

  test "a right state_rev with an old version is stale in the same shape", %{w: w} do
    post = in_state(w, "needs_approval")
    current = bump!(w, post)

    # the rev a later transition would have, the version still the old one
    forged = %{state_rev: current.state_rev, version: post.version}

    assert {:error, {:stale, %{state_rev: r, version: v}}} =
             Studio.approve_version(w.org_id, post.id, w.approver.id, forged)

    assert {r, v} == {current.state_rev, current.version}
  end

  test "an old fingerprint is stale in the same shape", %{w: w} do
    post = in_state(w, "needs_approval")

    assert {:error, {:stale, shape}} =
             Studio.approve_version(
               w.org_id,
               post.id,
               w.approver.id,
               expect(post, %{fingerprint: "not-the-fingerprint"})
             )

    assert shape == %{state_rev: post.state_rev, version: post.version}
  end
end
