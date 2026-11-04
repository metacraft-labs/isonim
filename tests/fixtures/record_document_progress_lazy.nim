import std/jsffi
import isonim/core/private/record_document_progress
proc deliberate(w,r,o:JsObject) {.exportc:"dpDeliberateUncalled".} = attachInternalRecordDocumentProgress(w,r,o)
echo "record-document-progress-lazy PASS"
