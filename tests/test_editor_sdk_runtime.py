"""Actual owning closure validation with explicit synthetic manifest mutations.

No mocked executable/package/process. Deliberately wrong private declarations
exercise rederivation rather than trusted JSON. Native receipt is tested by the
separate real zero-user controls; these tests make no inference/runtime ACK claim.
"""
import json
from pathlib import Path
import tempfile
import unittest
from helpers.editor_sdk_runtime import ROOT,resolve,authenticate

class RuntimeManifest(unittest.TestCase):
    def test_actual_closure_and_reject_manifest_mutations(self):
        actual=resolve()
        self.assertEqual(authenticate(ROOT/'build/editor-sdk-runtime.json'),actual)
        with tempfile.TemporaryDirectory() as root:
            filename=Path(root)/'runtime.json'
            filename.write_text(json.dumps(actual));self.assertEqual(authenticate(filename),actual)
            variants=[]
            for group,key in [('files',actual['paths']['sdk']),('paths','converter'),('versions','sdk')]:
                wrong=json.loads(json.dumps(actual));wrong[group][key]='incorrect';variants.append(wrong)
            wrong=json.loads(json.dumps(actual));wrong['extra']='untrusted';variants.append(wrong)
            for wrong in variants:
                filename.write_text(json.dumps(wrong))
                with self.subTest(wrong=wrong),self.assertRaises(AssertionError):authenticate(filename,actual['paths']['provider'])
            with self.assertRaises((FileNotFoundError,AssertionError)):resolve('/missing-actual-provider')
if __name__=='__main__':unittest.main()
