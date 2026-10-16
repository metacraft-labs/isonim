"""Use the exact owning production workspace-role parser in acceptance tests."""
import importlib.util
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[2] / 'tools/isonim_review/workspace_roles.py'
SPEC = importlib.util.spec_from_file_location('isonim_workspace_roles', SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
source_role = MODULE.source_role
declared_role = MODULE.declared_role
workspace_root = MODULE.workspace_root
workspace_report = MODULE.workspace_report
