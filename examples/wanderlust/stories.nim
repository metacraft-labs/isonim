## Wanderlust — Storyboard definitions
##
## Ordered by importance (progressive disclosure):
## User Flows → Pages → Components → Patterns → Foundations → Guidelines

import std/strutils

import isonim/editor/types

const WanderlustSource* = "examples/wanderlust/stories.nim"

func storyRefFromItem*(item: StoryItem; index: int): StoryRef =
  StoryRef(group: item.group, name: item.name, kind: item.kind, index: index)

func renderKind(kind: StoryKind): string =
  case kind
  of skFoundation: "foundation"
  of skComponent: "component"
  of skPattern: "pattern"
  of skPage: "page"
  of skFlow: "flow"
  of skGuideline: "guideline"
  of skVectorSymbol: "vector-symbol"

func flowStepScreen(group, name: string): StoryRef =
  case group
  of "Plan a Trip":
    case name
    of "Browses trending destinations on home":
      StoryRef(group: "Pages", name: "Home / Discover", kind: skPage)
    of "Taps Santorini card to see details":
      StoryRef(group: "Pages", name: "Destination Detail", kind: skPage)
    of "Taps 'Plan Trip' to start building":
      StoryRef(group: "Pages", name: "Trip Planner", kind: skPage)
    of "Adds activities to Day 1":
      StoryRef(group: "Pages", name: "Day View", kind: skPage)
    of "Reviews budget and confirms trip":
      StoryRef(group: "Pages", name: "Trip Planner", kind: skPage)
    else:
      StoryRef()
  of "Discover & Save":
    case name
    of "Types 'beach' in search bar":
      StoryRef(group: "Pages", name: "Home / Discover", kind: skPage)
    of "Applies Beach and Budget filters":
      StoryRef(group: "Pages", name: "Search Results", kind: skPage)
    of "Taps heart icon to save Lisbon":
      StoryRef(group: "Pages", name: "Search Results", kind: skPage)
    else:
      StoryRef()
  of "Travel Day":
    case name
    of "Opens active trip from home":
      StoryRef(group: "Pages", name: "Home / Discover", kind: skPage)
    of "Views Day 3 itinerary":
      StoryRef(group: "Pages", name: "Day View", kind: skPage)
    of "Checks off Jardin Majorelle visit":
      StoryRef(group: "Pages", name: "Day View", kind: skPage)
    of "Adds spontaneous souk shopping":
      StoryRef(group: "Pages", name: "Day View", kind: skPage)
    else:
      StoryRef()
  else:
    StoryRef()

func flowStepsForGroup*(group: StoryGroup): seq[FlowStep] =
  for item in group.items:
    result.add FlowStep(
      screenRef: flowStepScreen(group.name, item.name),
      action: item.name,
      description: item.description)

func wanderlustFlowSteps*(groups: seq[StoryGroup]): seq[FlowStep] =
  for group in groups:
    if group.kind == skFlow:
      result.add group.flowStepsForGroup()

func wanderlustCanvasItems*(groups: seq[StoryGroup]): seq[CanvasItem] =
  var index = 0
  for group in groups:
    if group.kind == skPage:
      for item in group.items:
        let story = item.storyRefFromItem(index)
        result.add CanvasItem(
          storyRef: story,
          x: float(index mod 3) * 360.0,
          y: float(index div 3) * 240.0,
          width: 320.0,
          height: 200.0,
          label: item.name)
        inc index

func buildWanderlustStoryboard*(): seq[StoryGroup] =
  var groups: seq[StoryGroup]

  # =======================================================================
  # 1. USER FLOWS — most important, shown first, expanded by default
  # =======================================================================
  groups.add StoryGroup(
    name: "Plan a Trip", kind: skFlow, expanded: true,
    description: "User discovers a destination and builds an itinerary",
    items: @[
      StoryItem(name: "Browses trending destinations on home",
                description: "Home page with destination cards",
                kind: skFlow, group: "Plan a Trip"),
      StoryItem(name: "Taps Santorini card to see details",
                description: "Destination detail with photos and reviews",
                kind: skFlow, group: "Plan a Trip"),
      StoryItem(name: "Taps 'Plan Trip' to start building",
                description: "Empty trip planner with date picker",
                kind: skFlow, group: "Plan a Trip"),
      StoryItem(name: "Adds activities to Day 1",
                description: "Day view with activity search",
                kind: skFlow, group: "Plan a Trip"),
      StoryItem(name: "Reviews budget and confirms trip",
                description: "Trip summary with budget breakdown",
                kind: skFlow, group: "Plan a Trip"),
    ])

  groups.add StoryGroup(
    name: "Discover & Save", kind: skFlow, expanded: true,
    description: "User searches for destinations and saves favorites",
    items: @[
      StoryItem(name: "Types 'beach' in search bar",
                description: "Search active with suggestions",
                kind: skFlow, group: "Discover & Save"),
      StoryItem(name: "Applies Beach and Budget filters",
                description: "Filtered results grid",
                kind: skFlow, group: "Discover & Save"),
      StoryItem(name: "Taps heart icon to save Lisbon",
                description: "Card shows saved state",
                kind: skFlow, group: "Discover & Save"),
    ])

  groups.add StoryGroup(
    name: "Travel Day", kind: skFlow, expanded: true,
    description: "User follows their itinerary during an active trip",
    items: @[
      StoryItem(name: "Opens active trip from home",
                description: "Morocco trip card highlighted",
                kind: skFlow, group: "Travel Day"),
      StoryItem(name: "Views Day 3 itinerary",
                description: "Timeline with 6 activities",
                kind: skFlow, group: "Travel Day"),
      StoryItem(name: "Checks off Jardin Majorelle visit",
                description: "Activity marked as complete",
                kind: skFlow, group: "Travel Day"),
      StoryItem(name: "Adds spontaneous souk shopping",
                description: "New activity added to timeline",
                kind: skFlow, group: "Travel Day"),
    ])

  # =======================================================================
  # 2. PAGES — full screen compositions
  # =======================================================================
  groups.add StoryGroup(
    name: "Pages", kind: skPage, expanded: true,
    description: "Full screens with realistic data",
    items: @[
      StoryItem(name: "Home / Discover", description: "Hero destination + trending + saved places",
                kind: skPage, group: "Pages"),
      StoryItem(name: "Search Results", description: "Grid of destinations with active filters",
                kind: skPage, group: "Pages"),
      StoryItem(name: "Destination Detail", description: "Santorini: photos, overview, reviews, weather",
                kind: skPage, group: "Pages"),
      StoryItem(name: "Trip Planner", description: "Morocco trip: day-by-day itinerary builder",
                kind: skPage, group: "Pages"),
      StoryItem(name: "Day View", description: "Day 3 in Marrakech: timeline of activities",
                kind: skPage, group: "Pages"),
      StoryItem(name: "Profile", description: "User profile: trips, countries, saved destinations",
                kind: skPage, group: "Pages"),
    ])

  # =======================================================================
  # 3. COMPONENTS — individual UI elements with states
  # =======================================================================
  groups.add StoryGroup(
    name: "DestinationCard", kind: skComponent, expanded: false,
    description: "Hero card showing a travel destination with image, rating, price",
    items: @[
      StoryItem(name: "Default", description: "Santorini — beach destination, saved",
                kind: skComponent, group: "DestinationCard"),
      StoryItem(name: "Unsaved", description: "Kyoto — culture destination, not saved",
                kind: skComponent, group: "DestinationCard"),
      StoryItem(name: "Budget", description: "Marrakech — affordable, adventure tags",
                kind: skComponent, group: "DestinationCard"),
      StoryItem(name: "Premium", description: "Reykjavik — high price, nature destination",
                kind: skComponent, group: "DestinationCard"),
      StoryItem(name: "Hover", description: "Card with hover state active",
                kind: skComponent, group: "DestinationCard"),
    ])

  groups.add StoryGroup(
    name: "TripCard", kind: skComponent, expanded: false,
    description: "Trip summary card showing status, budget, dates",
    items: @[
      StoryItem(name: "Planning", description: "Trip in planning phase",
                kind: skComponent, group: "TripCard"),
      StoryItem(name: "Upcoming", description: "Booked trip, 20 days away",
                kind: skComponent, group: "TripCard"),
      StoryItem(name: "Active", description: "Currently on Day 3",
                kind: skComponent, group: "TripCard"),
      StoryItem(name: "Completed", description: "Past trip with full budget",
                kind: skComponent, group: "TripCard"),
    ])

  groups.add StoryGroup(
    name: "ActivityItem", kind: skComponent, expanded: false,
    description: "Single activity in a day itinerary",
    items: @[
      StoryItem(name: "Sightseeing", description: "Jardin Majorelle visit, booked",
                kind: skComponent, group: "ActivityItem"),
      StoryItem(name: "Food", description: "Lunch at Nomad, not booked",
                kind: skComponent, group: "ActivityItem"),
      StoryItem(name: "Rest", description: "Hammam spa session, booked",
                kind: skComponent, group: "ActivityItem"),
    ])

  groups.add StoryGroup(
    name: "ReviewCard", kind: skComponent, expanded: false,
    description: "User review with stars, text, helpful count",
    items: @[
      StoryItem(name: "5-star", description: "Glowing review, fully expanded",
                kind: skComponent, group: "ReviewCard"),
      StoryItem(name: "Collapsed", description: "Long review, truncated",
                kind: skComponent, group: "ReviewCard"),
    ])

  groups.add StoryGroup(
    name: "SearchBar", kind: skComponent, expanded: false,
    description: "Search input with suggestions dropdown",
    items: @[
      StoryItem(name: "Empty", description: "Placeholder visible",
                kind: skComponent, group: "SearchBar"),
      StoryItem(name: "Active", description: "Focused with suggestions",
                kind: skComponent, group: "SearchBar"),
    ])

  groups.add StoryGroup(
    name: "FilterChip", kind: skComponent, expanded: false,
    description: "Toggleable filter tag",
    items: @[
      StoryItem(name: "Unselected", description: "Default state",
                kind: skComponent, group: "FilterChip"),
      StoryItem(name: "Selected", description: "Active filter",
                kind: skComponent, group: "FilterChip"),
    ])

  groups.add StoryGroup(
    name: "WeatherBadge", kind: skComponent, expanded: false,
    description: "Compact weather indicator",
    items: @[
      StoryItem(name: "Sunny", description: "26°C clear skies",
                kind: skComponent, group: "WeatherBadge"),
      StoryItem(name: "Cloudy", description: "18°C overcast",
                kind: skComponent, group: "WeatherBadge"),
    ])

  # =======================================================================
  # 4. PATTERNS — common compositions
  # =======================================================================
  groups.add StoryGroup(
    name: "Patterns", kind: skPattern, expanded: false,
    description: "Common UI compositions across the app",
    items: @[
      StoryItem(name: "Destination Grid", description: "2-column card grid with responsive layout",
                kind: skPattern, group: "Patterns"),
      StoryItem(name: "Day Itinerary", description: "Timeline of activities with time markers",
                kind: skPattern, group: "Patterns"),
      StoryItem(name: "Budget Progress", description: "Spent vs total with category breakdown",
                kind: skPattern, group: "Patterns"),
      StoryItem(name: "Empty State", description: "No trips yet — illustration + CTA",
                kind: skPattern, group: "Patterns"),
      StoryItem(name: "Loading Skeleton", description: "Shimmer placeholders for cards and lists",
                kind: skPattern, group: "Patterns"),
    ])

  # =======================================================================
  # 5. FOUNDATIONS — design tokens
  # =======================================================================
  groups.add StoryGroup(
    name: "Foundations", kind: skFoundation, expanded: false,
    description: "Design tokens for the Wanderlust travel app",
    items: @[
      StoryItem(name: "Colors", description: "Terracotta primary, teal secondary, amber accent",
                kind: skFoundation, group: "Foundations"),
      StoryItem(name: "Typography", description: "Playfair Display headings, Inter body",
                kind: skFoundation, group: "Foundations"),
      StoryItem(name: "Spacing & Radii", description: "4-80px scale, sm/md/lg/xl radii",
                kind: skFoundation, group: "Foundations"),
      StoryItem(name: "Elevation", description: "Four shadow levels",
                kind: skFoundation, group: "Foundations"),
      StoryItem(name: "Motion", description: "Durations and easing curves",
                kind: skFoundation, group: "Foundations"),
    ])

  # =======================================================================
  # 6. GUIDELINES — usage rules (least urgent, last)
  # =======================================================================
  groups.add StoryGroup(
    name: "Guidelines", kind: skGuideline, expanded: false,
    description: "Design rules and standards",
    items: @[
      StoryItem(name: "Do / Don't", description: "Component usage rules with visual examples",
                kind: skGuideline, group: "Guidelines"),
      StoryItem(name: "Content & Voice", description: "Warm, inspiring, practical tone",
                kind: skGuideline, group: "Guidelines"),
      StoryItem(name: "Photography", description: "Authentic travel photos, warm tones",
                kind: skGuideline, group: "Guidelines"),
      StoryItem(name: "Motion", description: "Gentle transitions, parallax on scroll",
                kind: skGuideline, group: "Guidelines"),
      StoryItem(name: "Accessibility", description: "Color contrast, touch targets, screen readers",
                kind: skGuideline, group: "Guidelines"),
    ])

  groups

func findStoryItem(groups: seq[StoryGroup]; story: StoryRef;
    itemOut: var StoryItem; indexOut: var int): bool =
  for group in groups:
    if group.name == story.group and group.kind == story.kind:
      for i, item in group.items:
        if item.name == story.name and item.kind == story.kind:
          itemOut = item
          indexOut = i
          return true

func storyMetadata*(story: StoryRef): StoryRenderMetadata =
  let groups = buildWanderlustStoryboard()
  var item: StoryItem
  var itemIndex = -1
  if groups.findStoryItem(story, item, itemIndex):
    return StoryRenderMetadata(
      story: StoryRef(group: item.group, name: item.name, kind: item.kind,
        index: itemIndex),
      title: item.group & " / " & item.name,
      sourceFile: WanderlustSource,
      sourceLine: 1,
      fixtureName: item.group & "." & item.name,
      renderKind: story.kind.renderKind)

func pagePreviewBody(story: StoryRef): string =
  case story.name
  of "Home / Discover":
    "Hero destination Santorini, trending destinations, saved Morocco trip"
  of "Search Results":
    "Filtered destination grid with Lisbon, Banff, Santorini, and budget chips"
  of "Destination Detail":
    "Santorini detail with reviews, weather, photos, and plan trip action"
  of "Trip Planner":
    "Morocco trip planner with itinerary builder and budget summary"
  of "Day View":
    "Day 3 Marrakech timeline including Jardin Majorelle and souk shopping"
  of "Profile":
    "Profile dashboard with trips, countries visited, and saved destinations"
  else:
    ""

proc wanderlustPreviewHook*(story: StoryRef;
                            platform: Platform): ProjectPreview =
  let metadata = story.storyMetadata()
  if metadata.title.len == 0:
    return ProjectPreview(status: ppsUnsupportedStory, story: story)

  let body =
    case story.kind
    of skPage:
      pagePreviewBody(story)
    of skComponent:
      "Component fixture using " & story.group & " state " & story.name
    of skPattern:
      "Pattern fixture for " & story.name.toLowerAscii()
    of skFoundation:
      "Foundation fixture for Wanderlust " & story.name.toLowerAscii()
    of skGuideline:
      "Guideline fixture for " & story.name.toLowerAscii()
    of skFlow:
      let screen = flowStepScreen(story.group, story.name)
      "Flow action renders project screen " & screen.group & " / " & screen.name
    of skVectorSymbol:
      "Vector symbol fixture for " & story.name.toLowerAscii()

  ProjectPreview(
    status: ppsRendered,
    story: StoryRef(group: story.group, name: story.name, kind: story.kind,
      index: metadata.story.index),
    title: metadata.title,
    bodyText: body,
    metadata: metadata)
