## Transfer a completed render's experiment assignment through hydration data.
import ../experiments
import ./serializer
export experiments
proc serializeExperiments*(assignment: ExperimentAssignment): string =
  ## Escape script terminators in host-provided keys/day before embedding.
  serializeResources([("$exp", experimentResource(assignment))])
