import ./types
export types
proc first*(): Cta = useExperiment[Cta]()
proc color*(): Color = useExperiment[Color]()
