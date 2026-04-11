## Wanderlust — Component ViewModels
##
## Pure state machines for all travel app components.
## No CSS, no colors — only signals and data types.

import isonim/core/[signals, computation]
import isonim/viewmodel

# ===========================================================================
# Data types
# ===========================================================================

type
  Destination* = object
    id*: int
    name*: string
    country*: string
    tagline*: string
    imageUrl*: string       # placeholder URL
    rating*: float          # 0.0 - 5.0
    reviewCount*: int
    pricePerNight*: int     # USD
    tags*: seq[string]      # e.g. "Beach", "Culture", "Adventure"
    isSaved*: bool

  TripStatus* = enum
    tsPlanning    ## Still assembling the itinerary
    tsUpcoming    ## Booked, departure approaching
    tsActive      ## Currently traveling
    tsCompleted   ## Trip is over
    tsCancelled

  Trip* = object
    id*: int
    name*: string
    destination*: string
    startDate*: string      # "2026-06-15"
    endDate*: string
    coverImageUrl*: string
    status*: TripStatus
    dayCount*: int
    totalBudget*: int
    spentBudget*: int
    travelerCount*: int

  Activity* = object
    id*: int
    name*: string
    location*: string
    time*: string           # "09:00"
    duration*: string       # "2h"
    category*: string       # "Sightseeing", "Food", "Transport", "Rest"
    notes*: string
    isBooked*: bool
    price*: int

  Review* = object
    authorName*: string
    authorAvatar*: string
    rating*: float
    text*: string
    date*: string
    helpfulCount*: int

  WeatherInfo* = object
    temp*: int              # Celsius
    condition*: string      # "Sunny", "Cloudy", "Rain"
    icon*: string

  SearchFilter* = object
    minPrice*: int
    maxPrice*: int
    minRating*: float
    tags*: seq[string]
    sortBy*: string         # "price", "rating", "popular"

# ===========================================================================
# Component ViewModels
# ===========================================================================

type
  DestinationCardVM* = ref object of ViewModel
    destination*: Signal[Destination]
    isHovered*: Signal[bool]
    displayPrice*: Memo[string]
    displayRating*: Memo[string]

  TripCardVM* = ref object of ViewModel
    trip*: Signal[Trip]
    daysUntil*: Memo[string]
    budgetPercent*: Memo[int]
    statusLabel*: Memo[string]

  ItineraryDayVM* = ref object of ViewModel
    dayNumber*: Signal[int]
    date*: Signal[string]
    activities*: Signal[seq[Activity]]
    totalCost*: Memo[int]
    isExpanded*: Signal[bool]

  ActivityItemVM* = ref object of ViewModel
    activity*: Signal[Activity]
    categoryIcon*: Memo[string]

  ReviewCardVM* = ref object of ViewModel
    review*: Signal[Review]
    isExpanded*: Signal[bool]
    starsDisplay*: Memo[string]

  SearchBarVM* = ref object of ViewModel
    query*: Signal[string]
    isActive*: Signal[bool]
    suggestions*: Signal[seq[string]]
    hasSuggestions*: Memo[bool]

  FilterChipVM* = ref object of ViewModel
    label*: Signal[string]
    isSelected*: Signal[bool]

  ProfileVM* = ref object of ViewModel
    name*: Signal[string]
    avatarUrl*: Signal[string]
    tripsCount*: Signal[int]
    countriesVisited*: Signal[int]
    savedDestinations*: Signal[seq[Destination]]
    pastTrips*: Signal[seq[Trip]]

# ===========================================================================
# Factory functions
# ===========================================================================

proc createDestinationCardVM*(dest: Destination): DestinationCardVM =
  let destSig = createSignal(dest)
  let isHovered = createSignal(false)
  let displayPrice = createMemo[string](proc(): string =
    "$" & $destSig.val.pricePerNight & "/night")
  let displayRating = createMemo[string](proc(): string =
    $destSig.val.rating & " (" & $destSig.val.reviewCount & ")")
  DestinationCardVM(destination: destSig, isHovered: isHovered,
                     displayPrice: displayPrice, displayRating: displayRating)

proc createTripCardVM*(trip: Trip): TripCardVM =
  let tripSig = createSignal(trip)
  let daysUntil = createMemo[string](proc(): string =
    case tripSig.val.status
    of tsPlanning: "Planning"
    of tsUpcoming: "In " & $tripSig.val.dayCount & " days"
    of tsActive: "Day " & $tripSig.val.dayCount
    of tsCompleted: "Completed"
    of tsCancelled: "Cancelled")
  let budgetPercent = createMemo[int](proc(): int =
    let t = tripSig.val
    if t.totalBudget > 0: (t.spentBudget * 100) div t.totalBudget else: 0)
  let statusLabel = createMemo[string](proc(): string =
    case tripSig.val.status
    of tsPlanning: "Planning"
    of tsUpcoming: "Upcoming"
    of tsActive: "In Progress"
    of tsCompleted: "Completed"
    of tsCancelled: "Cancelled")
  TripCardVM(trip: tripSig, daysUntil: daysUntil,
              budgetPercent: budgetPercent, statusLabel: statusLabel)

proc createSearchBarVM*(): SearchBarVM =
  let query = createSignal("")
  let isActive = createSignal(false)
  let suggestions = createSignal[seq[string]](@[])
  let hasSuggestions = createMemo[bool](proc(): bool =
    suggestions.val.len > 0 and isActive.val)
  SearchBarVM(query: query, isActive: isActive,
               suggestions: suggestions, hasSuggestions: hasSuggestions)
