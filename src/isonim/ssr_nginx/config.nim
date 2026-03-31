## isonim/ssr_nginx/config.nim
##
## Configuration directive parsing for the nginx IsoNim module.
## Handles `isonim_ssr` directive in nginx.conf to configure
## which routes are handled by the SSR module.

type
  IsoNimLocConf* = object
    ## Per-location configuration for the IsoNim nginx module.
    enabled*: bool
    appName*: string
    ## Max response buffer size in bytes (0 = unlimited).
    maxBufferSize*: int
    ## Whether to include hydration script in SSR output.
    hydrationEnabled*: bool
    ## Nonce for inline scripts (CSP support).
    scriptNonce*: string

proc defaultLocConf*(): IsoNimLocConf =
  ## Returns the default per-location configuration.
  IsoNimLocConf(
    enabled: false,
    appName: "",
    maxBufferSize: 0,
    hydrationEnabled: true,
    scriptNonce: "",
  )

proc parseLocConf*(enabled: bool; appName: string = "";
    maxBufferSize: int = 0; hydrationEnabled: bool = true;
    scriptNonce: string = ""): IsoNimLocConf =
  ## Parses location configuration from directive arguments.
  ## In a real nginx module, this would be called from the
  ## ngx_command_t set handler.
  IsoNimLocConf(
    enabled: enabled,
    appName: appName,
    maxBufferSize: maxBufferSize,
    hydrationEnabled: hydrationEnabled,
    scriptNonce: scriptNonce,
  )

proc isValid*(conf: IsoNimLocConf): bool =
  ## Validates the configuration.
  if not conf.enabled:
    return true  # Disabled config is always valid
  if conf.appName.len == 0:
    return false  # Must have an app name when enabled
  if conf.maxBufferSize < 0:
    return false
  return true
