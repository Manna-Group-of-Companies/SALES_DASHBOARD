"""The manna_credit_period_request Server Script's rule, against the shared fixture.

The script runs inside Frappe's safe_exec and cannot be imported, so this
runs the text between its '# ---- rule' and '# ---- end rule ----' markers -
the leaf functions every action and every can_* flag is decided by - on every
case of shared/fixtures/credit_period_request.json, the same cases the phone
and the dashboard test.

    python app/server/test_credit_period_request.py
"""

import json
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(HERE, "..", "..", "shared", "fixtures", "credit_period_request.json")
SCRIPT = os.path.join(HERE, "credit_period_request.py")


def load_rule():
    text = open(SCRIPT, encoding="utf-8").read()
    start = text.index("# ---- rule:")
    end = text.index("# ---- end rule ----")
    names = {}
    exec(compile(text[start:end], SCRIPT, "exec"), names)
    return names


RULE = load_rule()
FX = json.load(open(FIXTURE, encoding="utf-8"))


class CreditPeriodRule(unittest.TestCase):
    def test_transitions(self):
        for c in FX["transitions"]:
            with self.subTest(c["why"]):
                got = RULE["next_status"](c["action"], c["from"], c["days"], c["actor"])
                self.assertEqual(got or "REFUSED", c["expect"])

    def test_submit(self):
        for c in FX["submit"]:
            with self.subTest(c["why"]):
                self.assertEqual(RULE["submit_status"](c["days"]) or "REFUSED", c["expect"])

    def test_bands(self):
        # The band is what the transitions imply: who may approve With Manager.
        for c in FX["bands"]:
            with self.subTest(c["why"]):
                mgr = RULE["next_status"]("approve", "With Manager", c["days"], "manager")
                gm = RULE["next_status"]("approve", "With Manager", c["days"], "gm")
                band = "manager" if mgr else ("gm" if gm else "refused")
                self.assertEqual(band, c["band"])

    def test_offered(self):
        o = FX["offered"]
        got = [t["code"] for t in RULE["offered_terms"](o["terms"], o["current_code"])]
        self.assertEqual(got, o["expect_codes"])

    def test_limits(self):
        self.assertEqual(FX["limits"], {"manager_max_days": 30, "gm_max_days": 40})


if __name__ == "__main__":
    unittest.main()
