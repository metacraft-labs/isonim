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

import isonim/editor/views/widgets/variable_chip
export variable_chip

import isonim/editor/views/widgets/variable_picker
export variable_picker

import isonim/editor/views/widgets/variable_inline_editor
export variable_inline_editor

import isonim/editor/views/widgets/section_position
export section_position

import isonim/editor/views/widgets/section_layout
export section_layout

import isonim/editor/views/widgets/section_appearance
export section_appearance

import isonim/editor/views/widgets/section_fill
export section_fill

import isonim/editor/views/widgets/section_stroke
export section_stroke

import isonim/editor/views/widgets/section_effects
export section_effects

import isonim/editor/views/widgets/section_typography
export section_typography

import isonim/editor/views/widgets/section_selection_colors
export section_selection_colors

import isonim/editor/views/widgets/section_source
export section_source

import isonim/editor/views/widgets/section_component_props
export section_component_props

import isonim/editor/views/widgets/section_state
export section_state

import isonim/editor/views/widgets/section_export
export section_export

import isonim/editor/views/widgets/comment_overlay
export comment_overlay
