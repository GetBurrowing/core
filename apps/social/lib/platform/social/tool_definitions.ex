defmodule Platform.Social.ToolDefinitions do
  @moduledoc """
  Definitions of the `social` bundle's agent tools (task 01a140a9-4c70,
  Social 4/7), in `Platform.Federation.ToolSurface`'s rubric shape (Play's
  `Platform.Federation.PlayTools` is the model). The behaviour lives in
  `Platform.Social.Tools`.

  ## There is no publish tool and no approve tool

  Nine tools: read profiles, draft and edit posts up to `needs_approval`,
  list posts (with why a human rejected one), propose clips, (Social 5/7)
  queue a clip's render and list clips with their render state, and (Social
  6/7) file a social task for an ask heard in a meeting or chat. Every description
  carries `human_approves/0` verbatim. A human approves in Suite and the
  platform publishes.

  ## Grantable, not a default grant

  Like `play`, `social` is grantable (`AgentRuntime.valid_bundles/0` appends
  every extension bundle) but absent from `@default_allowed_bundles`: an
  admin grants it per runtime, as data in `allowed_bundles`.
  """

  @human_approves "A human approves this in Suite and the platform publishes it; agents cannot approve or publish."

  @names ~w(social_profile_list social_profile_get social_draft_create social_draft_update
            social_post_list social_clip_propose social_clip_render social_clip_list
            social_task_request)

  @doc "The sentence every tool's description carries."
  @spec human_approves() :: String.t()
  def human_approves, do: @human_approves

  @doc "Every tool name this bundle defines."
  @spec names() :: [String.t()]
  def names, do: @names

  @post_fields %{
    body: %{type: "string", required: false, description: "The post text."},
    media_file_ids: %{
      type: "array",
      required: false,
      description: "Ids of files (Suite Files) in the profile's org to attach.",
      schema: %{type: "array", items: %{type: "string"}}
    },
    link_url: %{
      type: "string",
      required: false,
      description:
        "The link to post. Omit it and the profile's home_url (or the YouTube episode at start_s, with t=<seconds>) is used and appended to the body."
    },
    scheduled_at: %{
      type: "string",
      required: false,
      description:
        "ISO-8601 time to publish at, in the future. It only takes effect once a human approves."
    },
    status: %{
      type: "string",
      required: false,
      description:
        "draft or needs_approval (default needs_approval). Any other status is refused."
    },
    task_id: %{
      type: "string",
      required: false,
      description: "Source task id, in the profile's org."
    },
    meeting_id: %{
      type: "string",
      required: false,
      description: "Source meeting id, in the profile's org."
    },
    segment_ids: %{
      type: "array",
      required: false,
      description: "Source meeting transcript segment ids.",
      schema: %{type: "array", items: %{type: "string"}}
    },
    episode_url: %{
      type: "string",
      required: false,
      description:
        "Source episode URL. A YouTube video URL becomes the link when link_url is unset."
    },
    start_s: %{
      type: "number",
      required: false,
      description: "Source start, in seconds into the episode."
    },
    end_s: %{type: "number", required: false, description: "Source end, in seconds."}
  }

  @clip_row "%{id, profile_id, status, error, source_url, source_file_id, transcript_file_id, requested_start_s, requested_end_s, start_s, end_s, caption, speaker, crop_x, platforms, render_file_id, duration_s, width, height, byte_size, attempts, rendered_at}"

  @post_row "post: %{id, account_id, status, body, link_url, media_file_ids, scheduled_at, error, rejection_reason, rejected_at, approved_at, task_id, meeting_id, segment_ids, episode_url, start_s, end_s, inserted_at, updated_at}"

  @doc "The tool definitions, in the ToolSurface rubric shape."
  @spec definitions() :: [map()]
  def definitions do
    [
      %{
        name: "social_profile_list",
        description:
          "List the social profiles (brands or shows) you may draft for, each with a summary of its platform accounts. " <>
            @human_approves,
        parameters: %{
          org_id: %{
            type: "string",
            required: false,
            description:
              "Narrow to one org. A tenant agent may pass only its own org (or omit it); another org is refused as unauthorized."
          }
        },
        returns:
          "%{profiles: [%{id, org_id, name, home_url, default_hashtags, accounts: [%{id, platform, handle, approval_mode, status}]}], total, has_more}",
        limitations:
          "Only profiles in your own org (an unpinned agent sees every org). Archived accounts are omitted. The org comes from your agent, never from org_id.",
        when_to_use: "First, to find the profile_id and account_ids to draft for."
      },
      %{
        name: "social_profile_get",
        description:
          "Read one social profile: its accounts, home_url, voice notes and default hashtags. " <>
            @human_approves,
        parameters: %{
          profile_id: %{type: "string", required: true, description: "The profile id."}
        },
        returns:
          "%{id, org_id, name, home_url, voice_notes, default_hashtags, accounts: [%{id, platform, handle, approval_mode, status}]}",
        limitations:
          "not_found for a profile outside your org, exactly as for a missing id. No credential or secret is ever returned.",
        when_to_use: "Before drafting, to match the profile's voice and hashtags."
      },
      %{
        name: "social_draft_create",
        description:
          "Draft a post for one or more of a profile's accounts (one post per account, all or none). It lands in needs_approval (or draft). " <>
            @human_approves,
        parameters:
          Map.merge(@post_fields, %{
            profile_id: %{type: "string", required: true, description: "The profile id."},
            account_ids: %{
              type: "array",
              required: true,
              description: "Ids of the profile's accounts to post on.",
              schema: %{type: "array", items: %{type: "string"}}
            }
          }),
        returns: "%{posts: [#{@post_row}], count}",
        limitations:
          "status approved, scheduled, published or failed is refused (status_not_allowed), as is any approval, publisher or rejection field (field_not_allowed). Every account must belong to the profile and not be archived. Refs must exist in the profile's org.",
        when_to_use:
          "When you have post copy ready for a human to review. With no link_url, home_url is appended."
      },
      %{
        name: "social_draft_update",
        description:
          "Edit a post you drafted while it is still draft or needs_approval; draft may move to needs_approval, never back. " <>
            @human_approves,
        parameters:
          Map.merge(@post_fields, %{
            post_id: %{type: "string", required: true, description: "The post id."}
          }),
        returns: "%{post: #{@post_row}}",
        limitations:
          "A post past needs_approval (approved, scheduled, published, failed) is refused with post_locked and left unchanged. Rejection fields cannot be written.",
        when_to_use: "To revise a draft, for example after a human rejected it with a reason."
      },
      %{
        name: "social_post_list",
        description:
          "List a profile's posts, optionally by status, with each post's status, publisher error and the reason a human rejected it. " <>
            @human_approves,
        parameters: %{
          profile_id: %{type: "string", required: true, description: "The profile id."},
          status: %{
            type: "string",
            required: false,
            description: "One of draft, needs_approval, approved, scheduled, published, failed."
          },
          limit: %{type: "integer", required: false, description: "Page size (default 50)."},
          offset: %{type: "integer", required: false, description: "Rows to skip (default 0)."}
        },
        returns: "%{posts: [#{@post_row}], total, has_more, limit, offset}",
        limitations: "not_found for a profile outside your org. Oldest first.",
        when_to_use: "To see what is waiting, what shipped, and what was rejected and why."
      },
      %{
        name: "social_clip_propose",
        description:
          "Propose a clip candidate from one of a profile's episodes: EITHER a YouTube source_url OR a video plus its transcript already in Suite Files (source_file_id + transcript_file_id), start and end seconds, caption and speaker. It is created with status candidate; social_clip_render renders it. " <>
            @human_approves,
        parameters: %{
          profile_id: %{type: "string", required: true, description: "The profile id."},
          source_url: %{
            type: "string",
            required: false,
            description:
              "http(s) URL of the source episode. Give this OR source_file_id + transcript_file_id."
          },
          source_file_id: %{
            type: "string",
            required: false,
            description: "Id of the episode video in Suite Files, in the profile's project."
          },
          transcript_file_id: %{
            type: "string",
            required: false,
            description:
              "Id of the episode's transcript (VTT, SRT or JSON) in Suite Files, in the profile's project. Required with source_file_id."
          },
          start_s: %{
            type: "number",
            required: true,
            description:
              "Start, in seconds (>= 0). The render moves it to the nearest sentence start."
          },
          end_s: %{
            type: "number",
            required: true,
            description:
              "End, in seconds (> start_s). The render moves it to the nearest sentence end."
          },
          caption: %{type: "string", required: false, description: "Suggested caption."},
          speaker: %{type: "string", required: false, description: "Who is speaking."},
          crop_x: %{
            type: "number",
            required: false,
            description:
              "Where the 9:16 crop is centred across the frame, 0 (left) to 1 (right). Default 0.5."
          },
          platforms: %{
            type: "array",
            required: false,
            description:
              "Platforms to check the render against (x, tiktok, instagram, youtube, linkedin); each must be one of the profile's accounts. Default: all of them.",
            schema: %{type: "array", items: %{type: "string"}}
          }
        },
        returns: "%{clip: #{@clip_row}}",
        limitations:
          "invalid_range unless 0 <= start_s < end_s (numbers). invalid_source for both source kinds at once or a file without its transcript. source_not_in_project when a file is not in the profile's project; profile_needs_project when the profile has no project in its org.",
        when_to_use: "When a moment in an episode would make a good short clip."
      },
      %{
        name: "social_clip_render",
        description:
          "Queue a clip's render: a 1080x1920 captioned video with an end card, stored in Suite Files. Returns at once with status rendering; poll social_clip_list until it is rendered or failed. Attach the render_file_id to a draft with social_draft_create. " <>
            @human_approves,
        parameters: %{
          clip_id: %{type: "string", required: true, description: "The clip id."},
          platforms: %{
            type: "array",
            required: false,
            description:
              "Platforms whose length and size limits the render must meet; each must be one of the profile's accounts. Default: all of them.",
            schema: %{type: "array", items: %{type: "string"}}
          },
          force: %{
            type: "boolean",
            required: false,
            description: "Render again a clip that is already rendered. Default false."
          }
        },
        returns: "%{clip: #{@clip_row}}",
        limitations:
          "Only a candidate or failed clip renders (rendered needs force; rendering is refused with already_rendering). not_found for a clip outside your org. profile_needs_project when the profile has no project in its org. Failures (no ffmpeg, a range past the source, a platform's length limit, YouTube refusing this node) end the clip as failed with a readable error.",
        when_to_use: "After social_clip_propose, when the clip should be cut and captioned."
      },
      %{
        name: "social_clip_list",
        description:
          "List a profile's clips with their render state: status, error, render_file_id, duration_s, width and height. " <>
            @human_approves,
        parameters: %{
          profile_id: %{type: "string", required: true, description: "The profile id."},
          status: %{
            type: "string",
            required: false,
            description: "One of candidate, rendering, rendered, failed."
          },
          limit: %{type: "integer", required: false, description: "Page size (default 50)."},
          offset: %{type: "integer", required: false, description: "Rows to skip (default 0)."}
        },
        returns: "%{clips: [#{@clip_row}], total, has_more, limit, offset}",
        limitations: "not_found for a profile outside your org. Oldest first.",
        when_to_use: "To follow a render, or to find a rendered clip's render_file_id."
      },
      %{
        name: "social_task_request",
        description:
          "File a social task for an ask heard in a meeting or chat (\"clip the doomsday clock bit\", \"post the episode to LinkedIn\"): a task in the profile's project, carrying the profile, the source refs and the target platforms, assigned to you. Cite EITHER meeting_id with segment_ids OR episode_url with start_s and end_s. Once every draft linked to the task is published, failed or rejected, the task records the post URLs. " <>
            @human_approves,
        parameters: %{
          profile_id: %{type: "string", required: true, description: "The profile id."},
          platforms: %{
            type: "array",
            required: true,
            description: "Target platforms; each needs a live account on the profile.",
            schema: %{type: "array", items: %{type: "string"}}
          },
          ask: %{
            type: "string",
            required: true,
            description: "What the human asked for, in their words (at most 2000 characters)."
          },
          meeting_id: %{
            type: "string",
            required: false,
            description: "The meeting the ask was heard in (in the profile's project)."
          },
          segment_ids: %{
            type: "array",
            required: false,
            description: "1 to 50 transcript segment ids of that meeting the ask cites.",
            schema: %{type: "array", items: %{type: "string"}}
          },
          episode_url: %{
            type: "string",
            required: false,
            description: "Instead of a meeting: the episode's http or https URL."
          },
          start_s: %{
            type: "number",
            required: false,
            description: "With episode_url: start, seconds, >= 0."
          },
          end_s: %{
            type: "number",
            required: false,
            description: "With episode_url: end, seconds, after start_s."
          },
          space_id: %{
            type: "string",
            required: false,
            description:
              "The chat space the ask was heard in. Recorded only when you are a participant of it."
          }
        },
        returns:
          "%{task_id, created, status, profile_id, platforms, hint}: created is false when the same profile, refs and platforms were already filed (or the live meeting pipeline already filed a task for those segments, which is adopted).",
        limitations:
          "Refused for segments classed off-topic (segment_off_topic), retracted or vetoed (segment_retracted), or not yet classified (segment_unclassified, recoverable: retry, or cite the episode by URL and time). The task is assigned to YOU: draft its posts with social_draft_create task_id=<returned task_id>. No post is published without a human. not_found for a profile outside your org, exactly as for a missing id; meeting_not_found for a meeting outside the profile's project.",
        when_to_use: "When a human in a meeting or chat asks for a post or a clip for a profile."
      }
    ]
  end
end
