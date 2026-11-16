"""The manna_credit_extension Server Script's rules, against the shared fixture.

Runs the text between the script's '# ---- rule' and '# ---- end rule ----'
markers on every case of shared/fixtures/credit_extension.json that the
server decides: routing, the manager's and the GM's approval checks, the
status moves, the payment status and the commitment's outcome. The SAP job's
cases (payments, sap_raise, sap_restore) are sap-credit-sync/Test-CreditExtensions.ps1's.

    python app/server/test_credit_extension.py
"""

import json
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FX = json.load(open(os.path.join(HERE, "..", "..", "shared", "fixtures", "credit_extension.json"), encoding="utf-8"))


def load_rule():
    text = open(os.path.join(HERE, "credit_extension.py"), encoding="utf-8").read()
    names = {}
    exec(compile(text[text.index("# ---- rule:"):text.index("# ---- end rule ----")], "credit_extension.py", "exec"), names)
    return names


R = load_rule()


class CreditExtensionRule(unittest.TestCase):
    def test_routing(self):
        for c in FX["routing"]:
            with self.subTest(c["why"]):
                self.assertEqual(R["route_status"](c["missed_before"], c["open_extension"]), c["expect"])

    def test_manager_approval(self):
        for c in FX["manager_approval"]:
            with self.subTest(c["why"]):
                got = R["check_manager"](c["amount"], c["authority"], c["approved_on"], c["commitment"], c["reason"], c["remarks"])
                self.assertEqual(got or None, c["expect"])

    def test_gm_approval(self):
        for c in FX["gm_approval"]:
            with self.subTest(c["why"]):
                self.assertEqual(R["check_gm"](c["amount"], c["today"], c["commitment"], c["remarks"]) or None, c["expect"])

    def test_transitions(self):
        for c in FX["transitions"]:
            with self.subTest(c["why"]):
                self.assertEqual(R["next_status"](c["action"], c["from"], c["actor"]) or "REFUSED", c["expect"])

    def test_payment_status(self):
        for c in FX["payment_status"]:
            with self.subTest(c["why"]):
                got = R["payment_status"](c["amount"], c["paid"])
                self.assertEqual((got["status"], got["remaining"]), (c["expect"], c["remaining"]))

    def test_outcome(self):
        for c in FX["outcome"]:
            with self.subTest(c["why"]):
                self.assertEqual(R["outcome"](c["amount"], c["paid"], c["today"], c["commitment"]), c["expect"])

    def test_month_ends_count_calendar_days(self):
        # 10 calendar days across a month and a year end.
        self.assertEqual(R["check_manager"](1, 5, "2026-12-27", "2027-01-06", "r", "r"), "")
        self.assertEqual(R["check_manager"](1, 5, "2026-12-27", "2027-01-07", "r", "r"), "too_long")
        self.assertEqual(R["check_manager"](1, 5, "2028-02-25", "2028-03-06", "r", "r"), "")


if __name__ == "__main__":
    unittest.main()
