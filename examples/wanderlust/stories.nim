## Wanderlust — Storyboard definitions
##
## Builds the complete design system: foundations, components,
## patterns, pages, flows, and guidelines.

import isonim/editor/types
import examples/wanderlust/components/viewmodels
import examples/wanderlust/mock_data

proc buildWanderlustStoryboard*(): seq[StoryGroup] =
  var groups: seq[StoryGroup]

  # =======================================================================
  # Foundations
  # =======================================================================
  groups.add StoryGroup(
    name: "Foundations", kind: skFoundation, expanded: true,
    description: "Design tokens for the Wanderlust travel app",
    items: @[
      StoryItem(name: "Colors", description: "Terracotta primary, teal secondary, amber accent, neutral scale",
                kind: skFoundation, group: "Foundations"),
      StoryItem(name: "Typography", description: "Playfair Display headings, Inter body, JetBrains Mono code",
                kind: skFoundation, group: "Foundations"),
      StoryItem(name: "Spacing & Radii", description: "4-80px scale, sm/md/lg/xl/full radii",
                kind: skFoundation, group: "Foundations"),
      StoryItem(name: "Elevation", description: "Four shadow levels: sm, md, lg, xl",
                kind: skFoundation, group: "Foundations"),
      StoryItem(name: "Motion", description: "Duration scale (0.1-0.5s), easing curves",
                kind: skFoundation, group: "Foundations"),
    ])

  # =======================================================================
  # Components
  # =======================================================================
  groups.add StoryGroup(
    name: "DestinationCard", kind: skComponent, expanded: true,
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
      StoryItem(name: "Cancelled", description: "Cancelled trip, muted state",
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
      StoryItem(name: "Transport", description: "Airport transfer",
                kind: skComponent, group: "ActivityItem"),
    ])

  groups.add StoryGroup(
    name: "ReviewCard", kind: skComponent, expanded: false,
    description: "User review with stars, text, helpful count",
    items: @[
      StoryItem(name: "5-star", description: "Glowing review, fully expanded",
                kind: skComponent, group: "ReviewCard"),
      StoryItem(name: "4-star", description: "Positive with caveats",
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
      StoryItem(name: "With query", description: "User has typed 'bali'",
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
    description: "Compact weather indicator for destinations",
    items: @[
      StoryItem(name: "Sunny", description: "26°C clear skies",
                kind: skComponent, group: "WeatherBadge"),
      StoryItem(name: "Cloudy", description: "18°C overcast",
                kind: skComponent, group: "WeatherBadge"),
      StoryItem(name: "Rain", description: "14°C with rain",
                kind: skComponent, group: "WeatherBadge"),
    ])

  # =======================================================================
  # Patterns
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
      StoryItem(name: "Photo Gallery", description: "Grid of destination photos with lightbox",
                kind: skPattern, group: "Patterns"),
    ])

  # =======================================================================
  # Pages
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
  # User Flows
  # =======================================================================
  groups.add StoryGroup(
    name: "Plan a Trip", kind: skFlow, expanded: false,
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
    name: "Discover & Save", kind: skFlow, expanded: false,
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
    name: "Travel Day", kind: skFlow, expanded: false,
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
  # Guidelines
  # =======================================================================
  groups.add StoryGroup(
    name: "Guidelines", kind: skGuideline, expanded: false,
    description: "Design rules and standards",
    items: @[
      StoryItem(name: "Do / Don't", description: "Component usage rules with visual examples",
                kind: skGuideline, group: "Guidelines"),
      StoryItem(name: "Content & Voice", description: "Warm, inspiring, practical — never pushy or generic",
                kind: skGuideline, group: "Guidelines"),
      StoryItem(name: "Photography", description: "Authentic travel photos, not stock. Warm tones preferred",
                kind: skGuideline, group: "Guidelines"),
      StoryItem(name: "Motion", description: "Gentle transitions, parallax on scroll, card hover lifts",
                kind: skGuideline, group: "Guidelines"),
      StoryItem(name: "Accessibility", description: "Color contrast, touch targets, screen reader flows",
                kind: skGuideline, group: "Guidelines"),
      StoryItem(name: "Responsive", description: "Mobile-first: 1 col → 2 col → 3 col grid breakpoints",
                kind: skGuideline, group: "Guidelines"),
    ])

  groups
