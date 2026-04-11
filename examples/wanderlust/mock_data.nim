## Wanderlust — Mock Data Providers
##
## Realistic travel data for all editor states and user flows.

import examples/wanderlust/components/viewmodels

# ===========================================================================
# Destinations
# ===========================================================================

proc santoriniDest*(): Destination =
  Destination(
    id: 1, name: "Santorini", country: "Greece",
    tagline: "Whitewashed cliffs and legendary sunsets",
    rating: 4.8, reviewCount: 2847, pricePerNight: 185,
    tags: @["Beach", "Romance", "Photography"],
    isSaved: true)

proc kyotoDest*(): Destination =
  Destination(
    id: 2, name: "Kyoto", country: "Japan",
    tagline: "Ancient temples meet cherry blossom gardens",
    rating: 4.9, reviewCount: 3201, pricePerNight: 142,
    tags: @["Culture", "Nature", "History"],
    isSaved: false)

proc marrakechDest*(): Destination =
  Destination(
    id: 3, name: "Marrakech", country: "Morocco",
    tagline: "Vibrant souks and desert adventures",
    rating: 4.5, reviewCount: 1893, pricePerNight: 78,
    tags: @["Adventure", "Culture", "Food"],
    isSaved: false)

proc reykjavikDest*(): Destination =
  Destination(
    id: 4, name: "Reykjavik", country: "Iceland",
    tagline: "Northern lights and volcanic landscapes",
    rating: 4.7, reviewCount: 1654, pricePerNight: 210,
    tags: @["Adventure", "Nature", "Photography"],
    isSaved: true)

proc lisbonDest*(): Destination =
  Destination(
    id: 5, name: "Lisbon", country: "Portugal",
    tagline: "Tiled facades, pastéis de nata, and fado music",
    rating: 4.6, reviewCount: 2456, pricePerNight: 95,
    tags: @["Culture", "Food", "Budget"],
    isSaved: false)

proc banffDest*(): Destination =
  Destination(
    id: 6, name: "Banff", country: "Canada",
    tagline: "Turquoise lakes and Rocky Mountain peaks",
    rating: 4.8, reviewCount: 1987, pricePerNight: 165,
    tags: @["Nature", "Adventure", "Photography"],
    isSaved: false)

proc allDestinations*(): seq[Destination] =
  @[santoriniDest(), kyotoDest(), marrakechDest(),
    reykjavikDest(), lisbonDest(), banffDest()]

# ===========================================================================
# Trips
# ===========================================================================

proc planningTrip*(): Trip =
  Trip(id: 1, name: "Santorini Escape",
       destination: "Santorini, Greece",
       startDate: "2026-06-15", endDate: "2026-06-22",
       status: tsPlanning, dayCount: 7,
       totalBudget: 3200, spentBudget: 0, travelerCount: 2)

proc upcomingTrip*(): Trip =
  Trip(id: 2, name: "Japan Golden Week",
       destination: "Kyoto & Tokyo, Japan",
       startDate: "2026-05-01", endDate: "2026-05-12",
       status: tsUpcoming, dayCount: 20,
       totalBudget: 5800, spentBudget: 2400, travelerCount: 1)

proc activeTrip*(): Trip =
  Trip(id: 3, name: "Morocco Discovery",
       destination: "Marrakech & Sahara",
       startDate: "2026-04-08", endDate: "2026-04-15",
       status: tsActive, dayCount: 3,
       totalBudget: 2100, spentBudget: 890, travelerCount: 2)

proc completedTrip*(): Trip =
  Trip(id: 4, name: "Iceland Ring Road",
       destination: "Reykjavik & Beyond",
       startDate: "2025-08-10", endDate: "2025-08-20",
       status: tsCompleted, dayCount: 10,
       totalBudget: 4500, spentBudget: 4280, travelerCount: 3)

proc allTrips*(): seq[Trip] =
  @[activeTrip(), upcomingTrip(), planningTrip(), completedTrip()]

# ===========================================================================
# Itinerary (Day 3 of Morocco trip)
# ===========================================================================

proc moroccoDay3Activities*(): seq[Activity] =
  @[
    Activity(id: 1, name: "Breakfast at Riad",
             location: "Riad Yasmine", time: "08:00", duration: "1h",
             category: "Food", notes: "Traditional Moroccan breakfast included",
             isBooked: true, price: 0),
    Activity(id: 2, name: "Jardin Majorelle",
             location: "Rue Yves Saint Laurent", time: "09:30", duration: "2h",
             category: "Sightseeing", notes: "Book tickets online to skip queue",
             isBooked: true, price: 14),
    Activity(id: 3, name: "Lunch at Nomad",
             location: "Derb Aarjan, Medina", time: "12:00", duration: "1.5h",
             category: "Food", notes: "Rooftop terrace with medina views",
             isBooked: false, price: 25),
    Activity(id: 4, name: "Souk Shopping",
             location: "Jemaa el-Fnaa", time: "14:00", duration: "3h",
             category: "Sightseeing", notes: "Bargain! Start at 1/3 of asking price",
             isBooked: false, price: 50),
    Activity(id: 5, name: "Hammam Spa",
             location: "Heritage Spa", time: "17:30", duration: "1.5h",
             category: "Rest", notes: "Traditional hammam + massage",
             isBooked: true, price: 45),
    Activity(id: 6, name: "Dinner on Rooftop",
             location: "Le Jardin Secret", time: "20:00", duration: "2h",
             category: "Food", notes: "Sunset views, reserve table",
             isBooked: false, price: 40),
  ]

# ===========================================================================
# Reviews
# ===========================================================================

proc santoriniReviews*(): seq[Review] =
  @[
    Review(authorName: "Sarah Chen", rating: 5.0,
           text: "Absolutely magical. The sunset from Oia was everything we dreamed of. The caldera views from our hotel were breathtaking every morning.",
           date: "2026-03-15", helpfulCount: 24),
    Review(authorName: "Marco Rossi", rating: 4.5,
           text: "Beautiful island but very crowded in peak season. Go in May or October for the best experience. The food was incredible.",
           date: "2026-02-28", helpfulCount: 18),
    Review(authorName: "Aiko Tanaka", rating: 5.0,
           text: "The most photogenic place I've ever visited. Every corner is a postcard. The wine tasting at Santo Wines was a highlight.",
           date: "2026-01-12", helpfulCount: 31),
  ]

# ===========================================================================
# Search suggestions
# ===========================================================================

proc trendingSearches*(): seq[string] =
  @["Bali", "Patagonia", "Amalfi Coast", "New Zealand",
    "Maldives", "Swiss Alps", "Costa Rica"]

# ===========================================================================
# Weather
# ===========================================================================

proc santoriniWeather*(): seq[WeatherInfo] =
  @[
    WeatherInfo(temp: 26, condition: "Sunny", icon: "\xE2\x98\x80"),
    WeatherInfo(temp: 24, condition: "Partly Cloudy", icon: "\xE2\x9B\x85"),
    WeatherInfo(temp: 25, condition: "Sunny", icon: "\xE2\x98\x80"),
    WeatherInfo(temp: 22, condition: "Cloudy", icon: "\xE2\x98\x81"),
    WeatherInfo(temp: 27, condition: "Sunny", icon: "\xE2\x98\x80"),
  ]
