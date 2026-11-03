# Real concatenated emission: each literal need not contain a complete function.
# Compile and syntax-check the whole output; the privacy scanner sees a prefix.
{.emit: """var privacyPartialEmit = (function() {
  const field = document.createElement("input");
  field.value = "privacy fixture";
  return {""" & "answer: 42" & """};
})();""".}
