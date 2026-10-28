defmodule Platform.SocialFixtures do
  @moduledoc """
  Fixtures for Social's tests: real core rows (orgs, users, agents,
  projects, tasks, meetings, files) built through core's own contexts and
  test helpers, plus Social rows inserted through `Platform.Social`.
  """

  alias Platform.Repo

  def render_id!(clip) do
    import Ecto.Query

    Repo.one!(
      from(r in Platform.Social.ClipRender,
        where: r.clip_id == ^clip.id and r.file_id == ^clip.render_file_id,
        order_by: [desc: r.rev],
        limit: 1,
        select: r.id
      )
    )
  end

  def unique, do: System.unique_integer([:positive])

  @doc "A changeset's errors as `%{field => [message]}`."
  def errors_on(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc """
  The Burrow brand's token colours (primary, secondary, accent, info, both
  themes), read from core's app.css, upcased. A customer's clip must carry
  none of them (design canvas 01a140fc-14a9, node subject).
  """
  def suite_token_colours do
    "../../../platform/assets/css/app.css"
    |> Path.expand(__DIR__)
    |> File.read!()
    |> then(&Regex.scan(~r/--color-(?:primary|secondary|accent|info):\s*(#[0-9a-fA-F]{6})/, &1))
    |> Enum.map(fn [_, hex] -> String.upcase(hex) end)
    |> Enum.uniq()
  end

  @doc "A fresh tenant org id (one per call)."
  def org_id!, do: Platform.TenancyFixtures.tenant_org_id("social-org-#{unique()}")

  def user! do
    n = unique()

    %Platform.Accounts.User{}
    |> Platform.Accounts.User.changeset(%{
      email: "social-user-#{n}@example.com",
      name: "Social User #{n}",
      oidc_sub: "social-user-#{n}"
    })
    |> Repo.insert!()
  end

  @doc "A real `agents` row, so a test proves agent-not-user, not merely id-not-found."
  def agent! do
    n = unique()
    Repo.insert!(%Platform.Agents.Agent{slug: "social-agent-#{n}", name: "Social Agent #{n}"})
  end

  @doc "A real `agents` row pinned to `org_id` (core's home-org rule reads `metadata[\"org_id\"]`)."
  def pinned_agent!(org_id) do
    n = unique()

    Repo.insert!(%Platform.Agents.Agent{
      slug: "social-pinned-#{n}",
      name: "Social Pinned #{n}",
      metadata: %{"org_id" => org_id}
    })
  end

  def project!(org_id) do
    {:ok, project} = Platform.Tasks.create_project(%{name: "Social #{unique()}", org_id: org_id})
    project
  end

  def task!(org_id) do
    {:ok, task} =
      Platform.Tasks.create_task(%{project_id: project!(org_id).id, title: "Social task"})

    task
  end

  def meeting!(org_id) do
    {:ok, meeting} =
      Platform.Meetings.create_meeting(%{project_id: project!(org_id).id, name: "Social meet"})

    meeting
  end

  def file!(org_id) do
    project = project!(org_id)

    {:ok, file} =
      Platform.Files.create_file(%{
        project_id: project.id,
        name: "clip.mp4",
        original_filename: "clip.mp4",
        content_type: "video/mp4",
        byte_size: 1024,
        storage_key: "files/#{project.id}/#{unique()}/clip.mp4",
        content_hash: String.duplicate("a", 64)
      })

    file
  end

  # ── Publisher fixtures (Social 2/7) ───────────────────────────────────

  @doc "A platform file in `org_id` with the given content type and size."
  def media_file!(org_id, content_type, byte_size \\ 1024) do
    project = project!(org_id)
    ext = content_type |> String.split("/") |> List.last()

    {:ok, file} =
      Platform.Files.create_file(%{
        project_id: project.id,
        name: "media.#{ext}",
        original_filename: "media.#{ext}",
        content_type: content_type,
        byte_size: byte_size,
        storage_key: "files/#{project.id}/#{unique()}/media.#{ext}",
        content_hash: String.duplicate("b", 64)
      })

    file
  end

  @doc "A profile and one account on `platform` in `org_id`."
  def social_account!(org_id, platform, attrs \\ %{}) do
    {:ok, profile} =
      Platform.Social.create_profile(org_id, %{
        name: "Pub #{unique()}",
        space_id: channel!(org_id).id
      })

    {:ok, account} =
      Platform.Social.create_account(org_id, profile, Map.merge(%{platform: platform}, attrs))

    {profile, account}
  end

  # ── Approval fixtures (Social 3/7) ────────────────────────────────────

  @doc "A channel space in `org_id`, through core's Chat context."
  def channel!(org_id, attrs \\ %{}) do
    n = unique()

    default = %{
      name: "Social chan #{n}",
      slug: "social-chan-#{n}",
      kind: "channel",
      org_id: org_id
    }

    {:ok, space} = Platform.Chat.create_space(Map.merge(default, attrs))
    space
  end

  @doc "Adds a user (`:user`) or agent (`:agent`) participant to a space."
  def join!(space_id, type, id) when type in [:user, :agent] do
    {:ok, participant} =
      Platform.Chat.add_participant(space_id, %{
        participant_type: Atom.to_string(type),
        participant_id: id,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  @doc "A post on `account`, approved by a real user through `approve_post/3`."
  def approved_post!(org_id, account, attrs \\ %{}, approver \\ nil) do
    approver = make_approver!(org_id, account, approver || user!())
    {:ok, post} = Platform.Social.create_post(org_id, account, Map.merge(%{body: "hello"}, attrs))
    {:ok, post} = Platform.Social.approve_post(org_id, post, approver.id)
    post
  end

  # ── Social 5/7: the clip pipeline ────────────────────────────────────

  @doc "Gives `user` a plain member row in `org_id`."
  def member!(user, org_id) do
    %Platform.Tenancy.OrgMembership{}
    |> Platform.Tenancy.OrgMembership.changeset(%{
      user_id: user.id,
      org_id: org_id,
      role: "member"
    })
    |> Repo.insert!()

    user
  end

  @doc "Bytes stored in core's Files under `project` (no ingest)."
  def stored_file!(project, bytes, filename, content_type) do
    {:ok, file, _dedup?} =
      Platform.Files.add_bytes(project, bytes, filename, content_type, ingest: false)

    file
  end

  @doc """
  A 20s, five-sentence VTT transcript with known cue times:

      0-4   "Welcome back to the show everyone."
      4-8   "Today we talk about the supply chain."
      8-12  "It cost them $3.5 million last year."
      12-16 "Dr. Smith joined us at 10:30 sharp."
      16-20 "That is the whole story for today."
  """
  def vtt_fixture do
    """
    WEBVTT

    NOTE fixture #{unique()}

    00:00:00.000 --> 00:00:04.000
    Welcome back to the show everyone.

    00:00:04.000 --> 00:00:08.000
    Today we talk about the supply chain.

    00:00:08.000 --> 00:00:12.000
    It cost them $3.5 million last year.

    00:00:12.000 --> 00:00:16.000
    Dr. Smith joined us at 10:30 sharp.

    00:00:16.000 --> 00:00:20.000
    That is the whole story for today.
    """
  end

  @doc "A VTT of `n` 4-second sentences (for long clips)."
  def long_vtt_fixture(n) do
    cues =
      Enum.map_join(0..(n - 1), "\n", fn i ->
        "#{ts(i * 4)} --> #{ts(i * 4 + 4)}\nSentence number #{i} is here.\n"
      end)

    "WEBVTT\n\n" <> cues
  end

  defp ts(s) do
    h = div(s, 3600)
    m = s |> rem(3600) |> div(60)
    sec = rem(s, 60)

    :io_lib.format("~2..0B:~2..0B:~2..0B.000", [h, m, sec]) |> IO.iodata_to_binary()
  end

  @doc """
  A whole clip-pipeline world: an org with a project; a profile on that
  project with TikTok and X accounts; an approver who is a member of the
  org; an outsider who is a member of ANOTHER org only; a tenant agent
  pinned to the org (scope `{:tenant, org_id}`); and a video plus a VTT
  transcript stored in Files under the profile's project.
  """
  def render_world!(opts \\ []) do
    org_id = org_id!()
    project = project!(org_id)
    approver = member!(user!(), org_id)
    other_org_id = org_id!()
    outsider = member!(user!(), other_org_id)

    {:ok, profile} =
      Platform.Social.create_profile(org_id, %{
        name: "Clip show #{unique()}",
        project_id: project.id,
        home_url: "https://www.youtube.com/@clipshow",
        approver_user_ids: [approver.id],
        space_id: channel!(org_id).id
      })

    {:ok, tiktok} =
      Platform.Social.create_account(org_id, profile, %{platform: "tiktok", handle: "@show"})

    {:ok, x} = Platform.Social.create_account(org_id, profile, %{platform: "x", handle: "@show"})

    video =
      stored_file!(
        project,
        Keyword.get(opts, :video_bytes, "fake video #{unique()}"),
        "episode.mp4",
        "video/mp4"
      )

    transcript =
      stored_file!(project, Keyword.get(opts, :vtt, vtt_fixture()), "episode.vtt", "text/vtt")

    %{
      org_id: org_id,
      other_org_id: other_org_id,
      project: project,
      approver: approver,
      outsider: outsider,
      profile: profile,
      tiktok: tiktok,
      x: x,
      agent: pinned_agent!(org_id),
      scope: {:tenant, org_id},
      video: video,
      transcript: transcript
    }
  end

  @doc "A candidate clip on the world's file source."
  def file_clip!(world, start_s, end_s, attrs \\ %{}) do
    {:ok, clip} =
      Platform.Social.AgentDrafts.propose_clip(
        world.scope,
        world.profile.id,
        Map.merge(
          %{
            "source_file_id" => world.video.id,
            "transcript_file_id" => world.transcript.id,
            "start_s" => start_s,
            "end_s" => end_s
          },
          attrs
        )
      )

    clip
  end

  @doc """
  Makes `user` a live approver of `account`'s (or the profile's) profile
  (Social 3/7): a member of the profile's org and on its approver list.
  Returns the user.
  """
  def make_approver!(org_id, account_or_profile, user) do
    profile =
      case account_or_profile do
        %Platform.Social.Profile{} = profile -> profile
        %Platform.Social.Account{profile_id: id} -> Repo.get!(Platform.Social.Profile, id)
      end

    unless Enum.any?(Platform.Tenancy.list_user_memberships(user), &(&1.org_id == profile.org_id)) do
      member!(user, profile.org_id)
    end

    ids = Enum.uniq((profile.approver_user_ids || []) ++ [user.id])
    {:ok, _} = Platform.Social.update_profile(org_id, profile, %{approver_user_ids: ids})
    user
  end
end
