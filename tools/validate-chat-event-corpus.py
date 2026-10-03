#!/usr/bin/env python3
"""Validate synthetic visual DTOs with the optional sibling's real REST type.
This checks the protocol boundary, not Harbor/provider execution. No service or
Harbor binary is built. Its normal pinned shell compiles only the small owning
IsoNim validator and the production contract crates it imports.
"""
import os,pathlib,subprocess,sys
repo=pathlib.Path(__file__).resolve().parents[1]
harbor=repo.parent/'agent-harbor'
if not (harbor/'crates/ah-rest-api-contract/Cargo.toml').is_file():
    print('Optional private Harbor absent: production Rust DTO validation unavailable. Checked-in corpus provenance remains explicit.')
    raise SystemExit(0)
env=os.environ.copy()
for key in ['IN_NIX_SHELL','CARGO_TARGET_DIR']:env.pop(key,None)
launcher=harbor/'dev-bin/just'
command=[str(launcher),'--command','cargo','run','--locked','--offline','--manifest-path',str(repo/'tests/helpers/harbor_event_validator/Cargo.toml'),'--',str(repo/'tests/scenarios/chat-activity/public-session-events.json')]
raise SystemExit(subprocess.run(command,cwd=harbor,env=env).returncode)
