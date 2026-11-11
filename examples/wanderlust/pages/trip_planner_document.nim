## Wanderlust — the Pages / Trip Planner story as a document.
##
## The web page preview shows a page story as a document in its iframe
## (`documentHtml`). Without one it falls back to the story's title and summary
## line. This module writes the planner's document from the same mock data the
## Day View page uses, so the preview shows the itinerary builder and the budget
## summary a user would see.
##
## The document is self-contained HTML: no scripts, no external resources.

import std/strutils

import examples/wanderlust/components/viewmodels
import examples/wanderlust/mock_data

func htmlEscape(text: string): string =
  text.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"),
    ("\"", "&quot;"))

proc tripPlannerDocument*(): string =
  ## The planner for the active trip: the day's itinerary builder (its slots,
  ## booked or still to book, with prices) and the budget summary (the trip's
  ## budget, what is spent, what remains, and the day's total).
  let trip = activeTrip()
  let activities = moroccoDay3Activities()
  var dayTotal = 0
  var slots = ""
  for activity in activities:
    dayTotal += activity.price
    let state = if activity.isBooked: "Booked" else: "To book"
    slots.add "<li class=\"slot\"><span class=\"time\">" &
      htmlEscape(activity.time) & "</span><span class=\"name\">" &
      htmlEscape(activity.name) & "</span><span class=\"where\">" &
      htmlEscape(activity.location) & "</span><span class=\"state\">" &
      state & "</span><span class=\"price\">$" & $activity.price &
      "</span></li>\n"
  let remaining = trip.totalBudget - trip.spentBudget
  result = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Trip Planner</title>
<style>
body { margin: 0; padding: 24px; background: #F8FAFC; color: #111827;
  font: 14px/1.5 system-ui, sans-serif; }
h1 { margin: 0; font-size: 24px; }
h2 { margin: 0 0 12px; font-size: 16px; }
.meta { margin: 4px 0 20px; color: #4B5563; }
.planner { display: flex; gap: 24px; align-items: flex-start; }
.itinerary { flex: 2; background: #FFFFFF; border: 1px solid #E2E8F0;
  border-radius: 8px; padding: 16px; }
.budget { flex: 1; background: #FFFFFF; border: 1px solid #E2E8F0;
  border-radius: 8px; padding: 16px; }
ol { margin: 0; padding: 0; list-style: none; }
.slot { display: grid; grid-template-columns: 56px 1fr 1fr 80px 64px;
  gap: 8px; padding: 8px 0; border-top: 1px solid #F1F5F9; }
.state { color: #4B5563; }
.price { text-align: right; font-variant-numeric: tabular-nums; }
dl { display: grid; grid-template-columns: 1fr auto; gap: 8px 16px; margin: 0; }
dd { margin: 0; text-align: right; font-variant-numeric: tabular-nums; }
</style>
</head>
<body>
<header>
<h1>""" & htmlEscape(trip.name) & """</h1>
<p class="meta">""" & htmlEscape(trip.destination) & " - " &
    htmlEscape(trip.startDate) & " to " & htmlEscape(trip.endDate) & " - " &
    $trip.travelerCount & """ travelers</p>
</header>
<main class="planner">
<section class="itinerary" aria-label="Itinerary builder">
<h2>Itinerary builder</h2>
<p>Day 3 of """ & $trip.dayCount & """</p>
<ol>
""" & slots & """</ol>
</section>
<section class="budget" aria-label="Budget summary">
<h2>Budget summary</h2>
<dl>
<dt>Trip budget</dt><dd>$""" & $trip.totalBudget & """</dd>
<dt>Spent so far</dt><dd>$""" & $trip.spentBudget & """</dd>
<dt>Remaining</dt><dd>$""" & $remaining & """</dd>
<dt>Day 3 total</dt><dd>$""" & $dayTotal & """</dd>
</dl>
</section>
</main>
</body>
</html>
"""
