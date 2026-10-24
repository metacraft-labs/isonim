## Must NOT compile: a cacheOverrides policy weaker than the entry's cache
## (tests/routing/t_manifest_negotiation.nim).
import isonim/routing/manifest

type
  SecretRequest = object
    id: int
  SecretResponse = object
    id: int

routeManifest WeakRoute:
  page rSecret, "/secret/:id", SecretRequest, SecretResponse,
       cache = cpPrivateNoStore, cacheOverrides = [cpPrivateRevalidate]
