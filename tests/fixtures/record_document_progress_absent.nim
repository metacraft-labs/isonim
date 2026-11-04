## Common-module import must omit the private operation on JS and native.
import isonim/core/private/record_document_progress
static: doAssert not declared(attachInternalRecordDocumentProgress)
echo "record-document-progress-common-omission PASS"
