#!/usr/bin/env python3
"""Validate synthetic visual DTOs with the optional sibling's real REST type.
This checks the protocol boundary, not Harbor/provider execution. No service or
Harbor binary is built. Its normal pinned shell compiles only the small owning
IsoNim validator and the production contract crates it imports.
"""
import os,pathlib,subprocess,sys
from isonim_review.workspace_roles import source_role
repo=pathlib.Path(__file__).resolve().parents[1]
harbor=source_role(repo, 'agent-harbor',
                   override=os.environ.get('ISONIM_AGENT_HARBOR_SIBLING'),
                   required=False)
if not os.path.lexists(harbor):
    print('Optional private Harbor absent: production Rust DTO validation unavailable. Checked-in corpus provenance remains explicit.')
    raise SystemExit(0)
if not (harbor/'crates/ah-rest-api-contract/Cargo.toml').is_file():
    raise RuntimeError('Present declared Harbor lacks its production REST contract crate')
env=os.environ.copy()
for key in ['IN_NIX_SHELL','CARGO_TARGET_DIR']:env.pop(key,None)
launcher=harbor/'dev-bin/just'
command=[str(launcher),'--command','cargo','run','--locked','--offline','--manifest-path',str(repo/'tests/helpers/harbor_event_validator/Cargo.toml'),'--',str(repo/'tests/scenarios/chat-activity/public-session-events.json')]
raise SystemExit(subprocess.run(command,cwd=harbor,env=env).returncode)
