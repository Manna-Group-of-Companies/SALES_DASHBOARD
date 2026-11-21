"""The 10-day payment commitment ladder's Server Script rules, against the shared fixture.

Runs the text between each script's '# ---- rule' and '# ---- end rule ----' markers:
payment_commitment.py (needs, route, the GM lock, an approval, the order stage),
payment_commitment_order.py (its copy of needs, route and the GM lock) and
payment_commitment_watch.py (tracking).

    python app/server/test_payment_commitment.py
"""

import json
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FX = json.load(open(os.path.join(HERE, "..", "..", "shared", "fixtures", "payment_commitment.json"), encoding="utf-8"))


def load_rule(script):
    text = open(os.path.join(HERE, script), encoding="utf-8").read()
    names = {}
    exec(compile(text[text.index("# ---- rule:"):text.index("# ---- end rule ----")], script, "exec"), names)
    return names


R = load_rule("payment_commitment.py")
W = load_rule("payment_commitment_watch.py")
O = load_rule("payment_commitment_order.py")


class PaymentCommitmentRule(unittest.TestCase):
    def test_limits(self):
        self.assertEqual(R["MAX_DAYS"], FX["limits"]["max_days"])
        self.assertEqual(R["OVERDUE_DAYS"], FX["limits"]["overdue_days_trigger"])

    def test_needs(self):
        for c in FX["needs"]:
            with self.subTest(c["why"]):
                self.assertEqual(R["needs_of"](c["customer"], c["order_total"]), c["expect"])

    def test_backstop_copy(self):
        # manna_payment_commitment_order carries its own copy (a Server Script
        # cannot import another): it must decide exactly as the API does.
        for c in FX["needs"]:
            with self.subTest(c["why"]):
                self.assertEqual(O["needs_of"](c["customer"], c["order_total"]), c["expect"])
        for c in FX["route"]:
            with self.subTest(c["why"]):
                self.assertEqual(O["route_of"](c["needs"], c["over_limit"], c["excess"], c["authority"], c["gm_lock"],
                                               c["cap_reached"]), c["expect"])
        for c in FX["gm_lock"]:
            with self.subTest(c["why"]):
                self.assertEqual(O["gm_lock_of"](c["commitments"]), c["expect"])

    def test_route(self):
        for c in FX["route"]:
            with self.subTest(c["why"]):
                self.assertEqual(R["route_of"](c["needs"], c["over_limit"], c["excess"], c["authority"], c["gm_lock"],
                                               c["cap_reached"]), c["expect"])

    def test_gm_lock(self):
        for c in FX["gm_lock"]:
            with self.subTest(c["why"]):
                self.assertEqual(R["gm_lock_of"](c["commitments"]), c["expect"])

    def test_approval(self):
        for c in FX["approval"]:
            with self.subTest(c["why"]):
                self.assertEqual(R["check_approval"](c["approved_on"], c["commitment"], c["remarks"]) or None, c["expect"])

    def test_track(self):
        for c in FX["track"]:
            with self.subTest(c["why"]):
                self.assertEqual(W["track"](c["status"], c["approved_on"], c["commitment"], c["today"], c["overdue_now"],
                                            c["synced_at"]), c["expect"])

    def test_order_stage(self):
        for c in FX["order_status"]:
            with self.subTest(c["why"]):
                self.assertEqual(R["order_stage"](c["po_status"], c["pushed"], c["commitment"]), c["expect"])


if __name__ == "__main__":
    unittest.main()
