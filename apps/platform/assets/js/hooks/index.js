// Build-time modules' hooks (ADR 0055, task 01a0ee08 stage 3). `@extensions`
// is an esbuild alias: core's `platform` profile points it at
// js/extensions/none.js (an empty map), and a with-modules release host points
// it at the entry `mix platform.extensions.assets` generates from its
// configured modules. Core never imports a module's hook by name.
import extensionHooks from "@extensions"
import AppBadge from "./app_badge"
import ButtonLoading from "./button_loading"
import CandidateClock, { SheetHandleClock } from "./candidate_clock"
import CanvasRoomBridge from "./canvas_room_bridge"
import CanvasSidebarResize from "./canvas_sidebar_resize"
import ChannelMembershipDrag from "./channel_membership_drag"
import ChannelPicker from "./channel_picker"
import ChatScrollToMessage from "./chat_scroll_to_message"
import MessageContextPopover from "./message_context_popover"
import CodeBlock from "./code_block"
import ComposeInput from "./compose_input"
import CopyToClipboard from "./copy_to_clipboard"
import DoneColumnState from "./done_column_state"
import DragDropUpload from "./drag_drop_upload"
import DrawerSearchFocus from "./drawer_search_focus"
import EmbedCanvasScale from "./embed_canvas_scale"
import PrototypeFullscreen from "./prototype_fullscreen"
import ExecutionLogScroll from "./execution_log_scroll"
import FilePreviewScale from "./file_preview_scale"
import HexField from "./hex_field"
import InfiniteScroll from "./infinite_scroll"
import InlineEdit from "./inline_edit"
import LargeUpload, { LargeUploadTimeline } from "./large_upload"
import InlineFocus from "./inline_focus"
import InlineThread from "./inline_thread"
import KanbanDragDrop from "./kanban_drag_drop"
import LazyInlineCanvas from "./lazy_inline_canvas"
import LastProject from "./last_project"
import LongpressMenu from "./longpress_menu"
import MarkdownEditor from "./markdown_editor"
import LocalTime from "./local_time"
import MeetingAskFloorVeil from "./meeting_ask_floor_veil"
import MeetingBar from "./meeting_bar"
import MessageLift from "./message_lift"
import MeetingCaptions, { MeetingCaptionsPersist } from "./meeting_captions"
import MeetingClient from "./meeting_client"
import MeetingLobbyPreview from "./meeting_lobby_preview"
import MeetingPushToTalk from "./meeting_push_to_talk"
import MeetingRoom from "./meeting_room"
import MeetingScreenShare from "./meeting_screen_share"
import MeetingShareButton from "./meeting_share_button"
import MeetingSoundboard from "./meeting_soundboard"
import MeetingTimer from "./meeting_timer"
import MeetingTranscript from "./meeting_transcript"
import MeetingVideoTile from "./meeting_video_tile"
import MeetingVoiceWaveform from "./meeting_voice_waveform"
import MeetingWatchdog from "./meeting_watchdog"
import MeetingWhiteboard from "./meeting_whiteboard"
import MermaidDiagram from "./mermaid_diagram"
import MessageEditor from "./message_editor"
import NativeInstallSwitch from "./native_install_switch"
import PushSubscribe from "./push_subscribe"
import ReactionPicker from "./reaction_picker"
import ReactorPopover from "./reactor_popover"
import ResizableSidebar from "./resizable_sidebar"
import RouteResume from "./route_resume"
import RowReorderTouch from "./row_reorder_touch"
import ScrollToBottom from "./scroll_to_bottom"
import SectionReorder from "./section_reorder"
import SectionReorderTouch from "./section_reorder_touch"
import Sheet from "./sheet"
import SidebarCollapse from "./sidebar_collapse"
import TasksStatusFilter from "./tasks_status_filter"
import ThemeToggle from "./theme_toggle"
import UploadButton from "./upload_button"
import ViewportBreakpoint from "./viewport_breakpoint"

export default {
  // First, so a core hook of the same name wins over a module's.
  ...extensionHooks,
  AppBadge,
  ButtonLoading,
  CandidateClock,
  CanvasRoomBridge,
  CanvasSidebarResize,
  ChannelMembershipDrag,
  ChannelPicker,
  ChatScrollToMessage,
  MessageContextPopover,
  CodeBlock,
  ComposeInput,
  CopyToClipboard,
  DoneColumnState,
  DragDropUpload,
  DrawerSearchFocus,
  EmbedCanvasScale,
  PrototypeFullscreen,
  ExecutionLogScroll,
  FilePreviewScale,
  HexField,
  InfiniteScroll,
  InlineEdit,
  LazyInlineCanvas,
  LargeUpload,
  LargeUploadTimeline,
  InlineFocus,
  InlineThread,
  KanbanDragDrop,
  LastProject,
  LocalTime,
  LongpressMenu,
  MarkdownEditor,
  MeetingAskFloorVeil,
  MeetingBar,
  MeetingCaptions,
  MeetingCaptionsPersist,
  MeetingClient,
  MeetingLobbyPreview,
  MeetingPushToTalk,
  MeetingRoom,
  MeetingScreenShare,
  MeetingShareButton,
  MeetingSoundboard,
  MeetingTimer,
  MeetingTranscript,
  MeetingVideoTile,
  MeetingVoiceWaveform,
  MeetingWatchdog,
  MeetingWhiteboard,
  MermaidDiagram,
  MessageEditor,
  MessageLift,
  NativeInstallSwitch,
  PushSubscribe,
  ReactionPicker,
  ReactorPopover,
  ResizableSidebar,
  RouteResume,
  RowReorderTouch,
  ScrollToBottom,
  SectionReorder,
  SectionReorderTouch,
  Sheet,
  SheetHandleClock,
  SidebarCollapse,
  TasksStatusFilter,
  ThemeToggle,
  UploadButton,
  ViewportBreakpoint,
}
