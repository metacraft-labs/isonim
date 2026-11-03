"""Inspection and independently reviewed admission for one finite JS artifact.

Candidate inspection is intentionally not authorization. The compiler harness
binds source/config/parser inputs and actual compiler dependency rows; Acorn
catalogs the entire output. Final qualification requires a separate reviewed
manifest matching that entire catalog and input/output identity. This mechanism
makes no general JavaScript or security-type claim.
"""
from pathlib import Path
import hashlib
import json


class AdmissionError(ValueError):
    """A fixed-artifact identity, provenance or operation was not admitted."""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def site_key(kind, row):
    """Exact source-site identity; offsets alone do not establish provenance."""
    return kind, row.get('owner', '<module-init>'), row['sha256']


PRODUCTION_CREATION_OWNERS = ('createInternalClientElement__',
                              'createInternalClientTargetElement__')


def is_production_creation_owner(owner):
    return owner.startswith(PRODUCTION_CREATION_OWNERS)


def unadmitted_operation(kind, owner):
    return not ((kind == 'createElement' and is_production_creation_owner(owner)) or
                (kind == 'clearChildrenEmpty' and owner.startswith('clearChildren__')))


CREATION_MEMBERS = frozenset(('createElement', 'createElementNS', 'cloneNode',
    'innerHTML', 'outerHTML', 'insertAdjacentHTML', 'createContextualFragment',
    'importNode', 'adoptNode', 'write', 'DOMParser', 'eval', 'Function'))


def violations(catalog, finite_reference):
    """Enumerate every refusal, including unknown functions/init/dynamic sites.

    The reference is a previously captured, explicitly review-pending positive
    artifact, not an arbitrary application's inferred safety proof. A function
    record's owner is its enclosing scope; its name is the scope of its children.
    Full final catalog identity is checked separately during qualification.
    """
    result = []
    known_types = set(finite_reference['node_types'])
    for node in catalog['nodes']:
        if node['type'] not in known_types:
            result.append(('unknown-syntax', node))
    for category in ('functions', 'initializers', 'calls', 'constructors'):
        known = {site_key(category, row) for row in finite_reference[category]}
        for row in catalog[category]:
            if site_key(category, row) not in known:
                result.append(('unknown-' + category, row))
    known_dynamic = {site_key('dynamic-member', row) for row in finite_reference['members']
                     if row['property'] is None}
    for row in catalog['members']:
        kind = row['property']
        if kind is None:
            if site_key('dynamic-member', row) not in known_dynamic:
                result.append(('unknown-dynamic-member', row))
        elif kind in CREATION_MEMBERS:
            if kind == 'innerHTML' and row['empty_assignment']:
                kind = 'clearChildrenEmpty'
            if unadmitted_operation(kind, row['owner']):
                result.append(('unadmitted-native-operation:' + kind, row))
    # Bare aliases to constructors/evaluation are references too, even if they
    # later use an innocuous local variable as their callee.
    known_refs = {site_key('global-reference', row) for row in finite_reference['identifiers']}
    for row in catalog['identifiers']:
        if row['name'] in ('DOMParser', 'eval', 'Function', 'Reflect') and site_key('global-reference', row) not in known_refs:
            result.append(('unreviewed-global-reference', row))
    return result


def refuse_site(reason, row):
    """Actual narrow refusal guard, independently removable per exact site."""
    return True


def inspect_candidate(bundle, catalog, actual_inputs, bound_inputs, finite_reference, actual_build=None, bound_build=None):
    if not actual_build or not bound_build:
        raise AdmissionError('missing-build-descriptor')
    if actual_build != bound_build:
        raise AdmissionError('unknown-build-descriptor')
    if not actual_inputs or not bound_inputs:
        raise AdmissionError('missing-source-closure')
    if actual_inputs != bound_inputs:
        raise AdmissionError('unknown-source-input')
    raw = Path(bundle).read_bytes()
    if digest(raw) != catalog['output_sha256']:
        raise AdmissionError('unknown-compiled-output')
    problems = violations(catalog, finite_reference)
    for reason, row in problems:
        if refuse_site(reason, row):
            raise AdmissionError(reason + ':' + row.get('owner', '<module-init>'))
    if not any(row['property'] == 'createElement' and
               is_production_creation_owner(row['owner']) for row in catalog['members']):
        raise AdmissionError('missing-production-creation-site')
    return {'status': 'candidate-inspected-review-pending',
            'scope': 'Exact fixed source/compiler/config/parser/output only; no arbitrary-JS authorization',
            'output_sha256': digest(raw), 'catalog_sha256': catalog_digest(catalog),
            'inputs_sha256': catalog_digest(actual_inputs),
            'build_sha256': catalog_digest(actual_build),
            'node_count': len(catalog['nodes']), 'function_count': len(catalog['functions']),
            'source_records': len(actual_inputs)}


def catalog_digest(value):
    return digest(json.dumps(value, sort_keys=True, separators=(',', ':')).encode())


def qualify(bundle, catalog, actual_inputs, reviewed_manifest, reviewed_manifest_sha256, actual_resources=None, actual_build=None):
    """Verify an exact artifact against a separately supplied review receipt.

    The trusted caller selects the independently reviewed receipt and its pinned
    digest. This does not authenticate an arbitrary caller/reviewer or fabricate
    approval. The build/candidate harness never generates a reviewed manifest.
    """
    if reviewed_manifest is None:
        raise AdmissionError('independent-review-required')
    manifest_bytes = Path(reviewed_manifest).read_bytes()
    if digest(manifest_bytes) != reviewed_manifest_sha256:
        raise AdmissionError('unknown-review-manifest')
    manifest = json.loads(manifest_bytes)
    if manifest.get('kind') != 'independent-fixed-artifact-review' or not manifest.get('review_receipt_sha256'):
        raise AdmissionError('independent-review-required')
    if not actual_build or manifest.get('build_sha256') != catalog_digest(actual_build):
        raise AdmissionError('unreviewed-build-descriptor')
    if actual_resources is None or manifest.get('resources_sha256') != catalog_digest(actual_resources):
        raise AdmissionError('unreviewed-resource-closure')
    if digest(Path(bundle).read_bytes()) != catalog['output_sha256']:
        raise AdmissionError('unknown-compiled-output')
    if manifest.get('inputs_sha256') != catalog_digest(actual_inputs):
        raise AdmissionError('unknown-source-input')
    if manifest.get('output_sha256') != digest(Path(bundle).read_bytes()):
        raise AdmissionError('unknown-compiled-output')
    if manifest.get('catalog_sha256') != catalog_digest(catalog):
        raise AdmissionError('unreviewed-complete-catalog')
    return {'status': 'qualified-exact-reviewed-artifact',
            'review_manifest_sha256': reviewed_manifest_sha256,
            'scope': 'Only these exact inputs/output/complete AST catalog; no other application'}
