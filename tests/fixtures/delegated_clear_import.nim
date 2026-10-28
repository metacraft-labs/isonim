## Windowless import probe. Retain an exported reference without invoking it;
## any existing platform bootstrap behavior is compared to published baseline.
import isonim/web/events
proc clearLater() {.exportc: "dcClearLater".} = clearDelegatedEvents()
