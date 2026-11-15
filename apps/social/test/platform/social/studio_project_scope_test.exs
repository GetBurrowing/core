defmodule Platform.Social.StudioProjectScopeTest do
  @moduledoc """
  Social Studio slice A: Studio writes need a live project in the profile's
  org, and `social.use` is decided on that project (design owner's decision).

  `Grants` accepts no org resource, so the permission target is the profile's
  project. The project is validated (live, same org) BEFORE it is used as the
  target, so a foreign or archived project can never stand in for the org.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Post, PostEvent, Profile, Studio}

  setup do
    %{w: studio_world!()}
  end

  defp deny_on_project!(user, project_id) do
    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, user.id},
        permission: "social.use",
        resource: {:project, project_id}
      })
  end

  defp set_project!(w, project_id) do
    Repo.update_all(from(p in Profile, where: p.id == ^w.profile.id),
      set: [project_id: project_id]
    )

    :ok
  end

  defp counts, do: {Repo.aggregate(Post, :count), Repo.aggregate(PostEvent, :count)}
  defp enabled?(w), do: Repo.get!(Profile, w.profile.id).studio_enabled

  defp refused_everywhere(w, reason) do
    before = counts()
    assert {:error, ^reason} = Studio.create_post(w.org_id, w.x.id, w.approver.id, %{body: "x"})
    assert counts() == before

    # Enabling is refused too (start from off).
    Repo.update_all(from(p in Profile, where: p.id == ^w.profile.id),
      set: [studio_enabled: false]
    )

    assert {:error, ^reason} = Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, true)
    refute enabled?(w)
  end

  describe "controls" do
    test "an approver with no deny on a valid project creates and enables", %{w: w} do
      assert {:ok, %Post{}} = Studio.create_post(w.org_id, w.x.id, w.approver.id, %{body: "ok"})
      assert {:ok, _} = Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)

      assert {:ok, %Profile{studio_enabled: true}} =
               Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, true)
    end

    test "a deny on ANOTHER project does not refuse", %{w: w} do
      deny_on_project!(w.approver, project!(w.org_id).id)
      assert {:ok, %Post{}} = Studio.create_post(w.org_id, w.x.id, w.approver.id, %{body: "ok"})
    end
  end

  describe "a project-level deny of social.use" do
    test "refuses create and enable while the module stays visible, writing nothing", %{w: w} do
      deny_on_project!(w.approver, w.profile.project_id)

      # Positive control: the module itself is still visible to this user.
      assert Platform.Access.module_access?(
               Platform.Access.Scope.for_user(w.approver),
               :social,
               "social.use"
             )

      assert :ok = Social.approver_check(w.org_id, w.profile, w.approver.id)

      before = counts()

      assert {:error, :no_social_access} =
               Studio.create_post(w.org_id, w.x.id, w.approver.id, %{body: "denied"})

      assert counts() == before

      Repo.update_all(from(p in Profile, where: p.id == ^w.profile.id),
        set: [studio_enabled: false]
      )

      assert {:error, :no_social_access} =
               Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, true)

      refute enabled?(w)
    end

    test "also refuses switching Studio off", %{w: w} do
      deny_on_project!(w.approver, w.profile.project_id)

      assert {:error, :no_social_access} =
               Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)

      assert enabled?(w)
    end
  end

  describe "a profile with no project" do
    setup %{w: w} do
      :ok = set_project!(w, nil)
      :ok
    end

    test "enabling and creating are refused with :studio_needs_project, writing nothing", %{
      w: w
    } do
      refused_everywhere(w, :studio_needs_project)
    end

    test "switching Studio OFF still works for an approver", %{w: w} do
      assert {:ok, %Profile{studio_enabled: false}} =
               Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
    end

    test "a non-approver is still refused first, with the approver vocabulary", %{w: w} do
      assert {:error, reason} = Studio.create_post(w.org_id, w.x.id, w.outsider.id, %{body: "x"})
      refute reason == :studio_needs_project
    end
  end

  describe "a project that is not valid for the profile's org" do
    test "another org's project is refused", %{w: w} do
      :ok = set_project!(w, project!(w.other_org_id).id)
      refused_everywhere(w, :studio_needs_project)
    end

    test "an archived project is refused", %{w: w} do
      {:ok, _} = Platform.Tasks.update_project(w.project, %{archived_at: DateTime.utc_now()})
      refused_everywhere(w, :studio_needs_project)
    end

    test "a project scheduled for deletion is refused", %{w: w} do
      {:ok, _} =
        Platform.Tasks.update_project(w.project, %{deletion_scheduled_at: DateTime.utc_now()})

      refused_everywhere(w, :studio_needs_project)
    end

    test "a deny on a foreign project is never used as the target", %{w: w} do
      foreign = project!(w.other_org_id)
      :ok = set_project!(w, foreign.id)
      deny_on_project!(w.approver, foreign.id)
      refused_everywhere(w, :studio_needs_project)
    end

    test "switching Studio OFF still works with an invalid project", %{w: w} do
      {:ok, _} = Platform.Tasks.update_project(w.project, %{archived_at: DateTime.utc_now()})

      assert {:ok, %Profile{studio_enabled: false}} =
               Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
    end
  end

  describe "the module lock keeps its place" do
    test "with a missing project the module lock does not mask the project refusal", %{w: w} do
      :ok = set_project!(w, nil)

      {:ok, _} =
        Platform.Access.Grants.deny(%{
          principal: {:user, w.approver.id},
          permission: "social",
          resource: {:module, w.org_id}
        })

      assert {:error, :studio_needs_project} =
               Studio.create_post(w.org_id, w.x.id, w.approver.id, %{body: "x"})
    end
  end

  # Moves the profile's project exactly once, AFTER the call's first plain
  # (unlocked) read of the profile row and BEFORE it takes the profile lock:
  # the window in which `Social.update_profile/3` can race a Studio write.
  defp with_project_moved_before_lock(w, project_id, fun) do
    id = "move-project-#{System.unique_integer([:positive])}"
    key = {__MODULE__, id}
    Process.put(key, false)
    owner = self()

    :telemetry.attach(
      id,
      [:platform, :repo, :query],
      fn _event, _measure, %{query: query}, _config ->
        if self() == owner and Process.get(key) == false and
             String.contains?(query, ~s(FROM "social_profiles")) and
             not String.contains?(query, " FOR ") do
          Process.put(key, true)
          set_project!(w, project_id)
        end
      end,
      nil
    )

    try do
      result = fun.()
      assert Process.get(key) == true, "the profile was never read before the lock"
      result
    after
      :telemetry.detach(id)
      Process.delete(key)
    end
  end

  describe "the decision follows the locked row, not the pre-lock read" do
    test "create_post: project moved to one the approver is denied", %{w: w} do
      other = project!(w.org_id)
      deny_on_project!(w.approver, other.id)
      before = counts()

      assert {:error, :no_social_access} =
               with_project_moved_before_lock(w, other.id, fn ->
                 Studio.create_post(w.org_id, w.x.id, w.approver.id, %{body: "x"})
               end)

      assert counts() == before
    end

    test "create_post: project moved to nil", %{w: w} do
      before = counts()

      assert {:error, :studio_needs_project} =
               with_project_moved_before_lock(w, nil, fn ->
                 Studio.create_post(w.org_id, w.x.id, w.approver.id, %{body: "x"})
               end)

      assert counts() == before
    end

    test "create_post: a stale-invalid read with a now-valid row succeeds", %{w: w} do
      valid = w.profile.project_id
      :ok = set_project!(w, nil)

      assert {:ok, %Post{}} =
               with_project_moved_before_lock(w, valid, fn ->
                 Studio.create_post(w.org_id, w.x.id, w.approver.id, %{body: "x"})
               end)
    end

    test "set_enabled(true): project moved to a denied project or nil", %{w: w} do
      other = project!(w.org_id)
      deny_on_project!(w.approver, other.id)

      Repo.update_all(from(p in Profile, where: p.id == ^w.profile.id),
        set: [studio_enabled: false]
      )

      assert {:error, :no_social_access} =
               with_project_moved_before_lock(w, other.id, fn ->
                 Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, true)
               end)

      refute enabled?(w)
      :ok = set_project!(w, w.profile.project_id)

      assert {:error, :studio_needs_project} =
               with_project_moved_before_lock(w, nil, fn ->
                 Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, true)
               end)

      refute enabled?(w)
    end

    test "set_enabled(true): a stale-invalid read with a now-valid row succeeds", %{w: w} do
      valid = w.profile.project_id
      :ok = set_project!(w, nil)

      Repo.update_all(from(p in Profile, where: p.id == ^w.profile.id),
        set: [studio_enabled: false]
      )

      assert {:ok, %Profile{studio_enabled: true}} =
               with_project_moved_before_lock(w, valid, fn ->
                 Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, true)
               end)
    end
  end

  describe "switching off: the documented exception" do
    test "allowed with no project, allowed with an invalid project", %{w: w} do
      :ok = set_project!(w, nil)

      assert {:ok, %Profile{studio_enabled: false}} =
               Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)

      Repo.update_all(from(p in Profile, where: p.id == ^w.profile.id),
        set: [studio_enabled: true]
      )

      :ok = set_project!(w, project!(w.other_org_id).id)

      assert {:ok, %Profile{studio_enabled: false}} =
               Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
    end

    test "refused for a non-approver, even with no project", %{w: w} do
      :ok = set_project!(w, nil)
      assert {:error, reason} = Studio.set_enabled(w.org_id, w.profile.id, w.outsider.id, false)
      refute reason == :studio_needs_project
      assert enabled?(w)
    end

    test "refused when the module is locked, even with no project", %{w: w} do
      :ok = set_project!(w, nil)

      {:ok, _} =
        Platform.Access.Grants.deny(%{
          principal: {:user, w.approver.id},
          permission: "social",
          resource: {:module, w.org_id}
        })

      assert {:error, :no_social_access} =
               Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)

      assert enabled?(w)
    end
  end

  describe "the public helpers" do
    test "require_studio_project/1 and require_social_use/2", %{w: w} do
      profile = Repo.get!(Profile, w.profile.id)
      assert {:ok, pid} = Studio.require_studio_project(profile)
      assert pid == profile.project_id
      assert :ok = Studio.require_social_use(w.approver.id, profile)
      assert :ok = Studio.authorize_studio_actor(profile, w.approver.id)

      deny_on_project!(w.approver, profile.project_id)
      assert {:error, :no_social_access} = Studio.require_social_use(w.approver.id, profile)
      assert {:error, :no_social_access} = Studio.authorize_studio_actor(profile, w.approver.id)

      nil_profile = %{profile | project_id: nil}
      assert {:error, :studio_needs_project} = Studio.require_studio_project(nil_profile)

      assert {:error, :studio_needs_project} =
               Studio.require_social_use(w.approver.id, nil_profile)
    end
  end
end
