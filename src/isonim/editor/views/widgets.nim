## TBAR-M2 — façade for reusable editor toolbar widgets.
##
## This module exists so the editor shell can ``import
## isonim/editor/views/widgets`` once and pick up every reusable
## toolbar widget. New widgets land under
## ``isonim/editor/views/widgets/<name>.nim`` and gain a single
## ``export`` line here.

import isonim/editor/views/widgets/choice_group
export choice_group

import isonim/editor/views/widgets/property_row
export property_row
