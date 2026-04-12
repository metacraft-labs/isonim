## IsoNim Editor — AI Assistant Chat Panel.
##
## Ever-present panel on the right side of every screen.
## Shows a realistic conversation about Wanderlust design.

import isonim/core/computation
import isonim/dsl/ui
import isonim/editor/viewmodels

const
  bgBase = "#0B1120"
  bgSurface = "#1E293B"
  bgSidebar = "#111827"
  bgInput = "#0F172A"
  border = "#334155"
  borderFaint = "#1E293B"
  textPrimary = "#F1F5F9"
  textSecondary = "#94A3B8"
  textMuted = "#64748B"
  textDim = "#475569"
  accent = "#3B82F6"
  gold = "#F59E0B"
  green = "#22C55E"

type ChatBubble = object
  isUser: bool
  text: string

proc mockConversation(): seq[ChatBubble] =
  @[
    ChatBubble(isUser: true,
      text: "Can you make the destination cards feel warmer? The gradients are nice but the overall palette still feels a bit cold."),
    ChatBubble(isUser: false,
      text: "I'll adjust the card gradients to lean more into the terracotta and amber tones from your token palette. I'll also warm up the tag chip backgrounds from teal to a softer peach."),
    ChatBubble(isUser: true,
      text: "Perfect. Also, the price should be more prominent \xE2\x80\x94 it's the first thing travelers look at."),
    ChatBubble(isUser: false,
      text: "Done \xE2\x80\x94 I've increased the price font size to 20px bold and moved it above the rating. The change applies to all 6 DestinationCard variants. Want me to update the TripCard pricing too?"),
    ChatBubble(isUser: true,
      text: "Yes, and add a \xE2\x80\x9Cfrom\xE2\x80\x9D prefix so it reads \xE2\x80\x9Cfrom $185/night\xE2\x80\x9D."),
  ]

proc renderChatPanel*[R, E](r: R; vm: EditorVM): E =
  let messages = mockConversation()

  let panel = ui(r):
    tdiv(class = "editor-chat",
         width = "280px", min_width = "280px",
         display = "flex", flex_direction = "column",
         height = "100%",
         background_color = bgSidebar,
         border_left = "1px solid " & border)

  # Header
  let header = ui(r):
    tdiv(display = "flex", align_items = "center",
         justify_content = "space-between",
         padding = "10px 12px",
         border_bottom = "1px solid " & border,
         min_height = "40px"):
      tdiv(display = "flex", align_items = "center", gap = "8px"):
        span(font_size = "13px"):
          text "\xE2\x9C\xA8"
        span(font_size = "11px", font_weight = "600",
             color = textSecondary, text_transform = "uppercase",
             letter_spacing = "0.5px"):
          text "AI Assistant"
      # Status dot (connected)
      tdiv(display = "flex", align_items = "center", gap = "4px"):
        tdiv(width = "6px", height = "6px", border_radius = "3px",
             background_color = green)
        span(font_size = "9px", color = textDim):
          text "Online"
  r.appendChild(panel, header)

  # Messages area
  let messagesArea = ui(r):
    tdiv(flex = "1", overflow_y = "auto", padding = "12px",
         display = "flex", flex_direction = "column", gap = "10px")

  for msg in messages:
    let isUser = msg.isUser
    let msgText = msg.text
    let bubble = ui(r):
      tdiv(display = "flex", flex_direction = "column",
           align_items = (if isUser: "flex-end" else: "flex-start")):
        # Sender label
        span(font_size = "9px", color = textDim, margin_bottom = "3px",
             font_weight = "500"):
          text(if isUser: "You" else: "AI Designer")
        # Bubble
        tdiv(max_width = "92%", padding = "8px 10px",
             border_radius = (if isUser: "10px 10px 2px 10px" else: "10px 10px 10px 2px"),
             background_color = (if isUser: accent else: bgSurface),
             font_size = "11px", line_height = "1.5",
             color = (if isUser: textPrimary else: textSecondary)):
          text msgText
    r.appendChild(messagesArea, bubble)

  r.appendChild(panel, messagesArea)

  # Input area
  let inputArea = ui(r):
    tdiv(padding = "8px 12px 12px 12px",
         border_top = "1px solid " & borderFaint):
      tdiv(display = "flex", align_items = "center", gap = "8px"):
        input(class = "editor-input",
              flex = "1", height = "34px",
              background_color = bgInput,
              border = "1px solid " & border,
              border_radius = "8px", padding = "0 10px",
              font_size = "12px", color = textPrimary,
              outline = "none",
              placeholder = "Ask the AI\xE2\x80\xA6")
        tdiv(display = "flex", align_items = "center",
             justify_content = "center",
             width = "34px", height = "34px",
             border_radius = "8px", font_size = "16px", font_weight = "700",
             background_color = accent, color = textPrimary,
             cursor = "pointer"):
          text "\xE2\x86\x91"
  r.appendChild(panel, inputArea)

  panel
