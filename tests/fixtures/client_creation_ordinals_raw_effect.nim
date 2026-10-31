## Include the actual renderer to qualify its nonexported direct assignment
## binding, separately from the inferred exported creation wrapper.
include ../../src/isonim/web/web_renderer
when defined(rejectAssignment):
  proc limited(c:InternalClientCreationOrdinals;e:Element):Element {.tags:[].} =
    assignInternalClientCreationOrdinal(c,e)
else:
  proc limited(c:InternalClientCreationOrdinals;e:Element):Element {.tags:[RawNondet].} =
    assignInternalClientCreationOrdinal(c,e)
discard limited(newInternalClientCreationOrdinals(),nil)
