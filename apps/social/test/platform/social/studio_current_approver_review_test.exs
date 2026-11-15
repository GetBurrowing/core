defmodule Platform.Social.StudioCurrentApproverReviewTest do
  use Platform.DataCase, async: false
  import Platform.SocialStudioFixtures
  alias Platform.Social
  alias Platform.Social.{Post, PostEvent, Studio}

  for {change, refusal} <- [
        {:approver, :not_an_approver},
        {:owner, :not_the_owner},
        {:archive, :account_archived}
      ] do
    @change change
    @refusal refusal
    test "create rechecks #{@change} changed between initial load and lock" do
      w = studio_world!()
      before = {Repo.aggregate(Post, :count), Repo.aggregate(PostEvent, :count)}
      assert :ok = Social.post_approver_check(w.org_id, w.profile, w.x, w.approver.id)
      handler = {__MODULE__, make_ref()}
      parent = self()
      Process.put(handler, false)

      :ok =
        :telemetry.attach(
          handler,
          [:platform, :repo, :query],
          fn _, _, meta, _ ->
            query = meta[:query] || ""

            if self() == parent and Process.get(handler, false) == false and
                 String.contains?(query, ~s(FROM "social_profiles")) and
                 not String.contains?(query, " FOR ") do
              Process.put(handler, true)

              changed =
                case @change do
                  :approver ->
                    Social.update_profile(w.org_id, w.profile, %{approver_user_ids: []})

                  :owner ->
                    Social.set_account_owner(w.org_id, w.x, w.outsider.id)

                  :archive ->
                    Social.archive_account(w.org_id, w.x)
                end

              assert {:ok, _} = changed
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      result = Studio.create_post(w.org_id, w.x.id, w.approver.id, %{body: "revoked"})
      assert Process.get(handler) == true, "the authority change must actually run"
      profile = Social.get_profile(w.org_id, w.profile.id)

      account = Social.get_account(w.org_id, w.x.id)

      case @change do
        :approver ->
          assert {:error, :not_an_approver} =
                   Social.post_approver_check(w.org_id, profile, account, w.approver.id)

        :owner ->
          assert {:error, :not_the_owner} =
                   Social.post_approver_check(w.org_id, profile, account, w.approver.id)

        :archive ->
          assert account.archived_at
      end

      assert {:error, @refusal} = result
      assert {Repo.aggregate(Post, :count), Repo.aggregate(PostEvent, :count)} == before
    end
  end
end
