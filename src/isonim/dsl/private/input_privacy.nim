## Privileged qualification facade. Ordinary imports intentionally expose no
## policy API; ui uses the internal pure implementation directly.
when defined(isonimInternalInputPrivacy):
  import ./input_privacy_policy
  export input_privacy_policy
