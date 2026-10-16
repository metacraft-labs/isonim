"""Explicit native source-worker opt-in for an owned disposable GRIP copy."""
import os
from pathlib import Path
import shutil

REPO = Path(__file__).resolve().parents[2]


def register_disposable_grip_source_bridge(project):
    """Opt in only the private copy using its real public GRIP story producer.

    The live prototype owns a browser write bridge, not this native source
    worker interface. This explicit acceptance fixture compiles the original
    project registry and SSR hooks; it does not copy another project's catalog.
    """
    protected = Path(os.environ.get("ISONIM_SOURCE_PROVIDER_PROJECT",
        REPO.parent / "web-site-prototypes/grip/isonim")).resolve()
    if project.resolve() == protected:
        raise ValueError("Source registration requires a disposable copy.")
    if os.path.lexists(project / "tools/build_editor_catalog.py"):
        raise FileExistsError("Refusing to replace a project-owned catalog producer.")
    fixture = REPO / "tests/fixtures/grip_source_bridge"
    metadata = project / ".isonim"
    metadata.mkdir(exist_ok=False)
    shutil.copyfile(fixture / "source-project.json", metadata / "source-project.json")
    shutil.copyfile(fixture / "catalog.nim", metadata / "catalog.nim")
    shutil.copyfile(fixture / "build_editor_catalog.py", project / "tools/build_editor_catalog.py")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    register_disposable_grip_source_bridge(parser.parse_args().project)
