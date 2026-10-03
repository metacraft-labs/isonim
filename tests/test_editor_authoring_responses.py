"""Synthetic response JSON tests isolate strict shared host codec/schema only.

No mock object/provider/transport. These intentional fixture values cannot prove
workflow sequencing; the official real browser/compiler scenario suite does that.
"""
import json
from pathlib import Path
import tempfile
import unittest
from helpers.editor_authoring_responses import validate_responses

class Responses(unittest.TestCase):
    def test_exact_literal_booleans(self):
        with tempfile.TemporaryDirectory() as root:
            path=Path(root)/'checks.json'
            good={'contextOnlyNonce':True,'actualHtmlDescription':True}
            path.write_text(json.dumps(good));self.assertEqual(validate_responses(path),good)
            cases=[{},[],None,{**good,'extra':True},{'contextOnlyNonce':True}]
            for key in good:
                for value in (False,1,'true',None,[],{}): cases.append({**good,key:value})
            for value in cases:
                with self.subTest(value=value):
                    path.write_text(json.dumps(value))
                    with self.assertRaises(AssertionError):validate_responses(path)
            path.write_text('{')
            with self.assertRaises(json.JSONDecodeError):validate_responses(path)
if __name__=='__main__':unittest.main()
