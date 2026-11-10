# Builds Z.erpmore (10 Nov 2026): ONE package of seven timer steps, the rest of
# what the sync scripts did - so it is one import, one Steps dialog and one
# clock dialog on the server instead of seven of each.
#
#     python build_more.py        writes out/Z.erpmore.zip, out/Z.erpmore/<step>/*.xsl and out/Z.erpmore/manifest.json
#
#   Z.erpcustall  Manna    nightly  every customer        -> kind customers  (what an event missed)
#   Z.erpitemall  Manna    nightly  every sales item      -> kind items
#   Z.erpweight   Hi-Tech  30 min   roll figures          -> kind weights
#   Z.erpcredit   Manna    15 min   limit, outstanding... -> kind credit
#   Z.erpinv      Manna    15 min   A/R invoices          -> kind invoices
#   Z.erppay      Manna    5 min    incoming payments     -> kind payments
#   Z.erpprice    both     30 min   the price snapshot    -> kind pricing (two SQL calls, one post)
#
# Steps are made exactly as build_packages.py makes them (same atoms, same HTTP
# call); the SQL is read from ../<sync>/*.sql - comment lines dropped, because
# Call SQL picks how to run a statement by its first word - so the file that was
# run on the local copies is the text B1if runs. A timer step has no sender and
# its schedule is set in Setup (the clock); see SETUP.md.
import json, os, zipfile
from xml.sax.saxutils import escape
import build_packages as bp

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = "Z.erpmore"
MT, HT = bp.MANNA_TEST, bp.HITECH_TEST


def sql_from(rel):
	text = open(os.path.join(HERE, "..", rel), encoding="utf-8").read()
	body = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("--")).strip().rstrip(";").strip()
	assert body.upper().startswith("SELECT"), rel
	return escape(body)


STEPS = [
	dict(step="Z.erpcustall", sys=MT, db="mt", key="customers", extra='"kind":"customers",', sql=bp.CUSTOMERS_SQL, when="nightly 01:10",
		cols=["code", "name", "active", "sales_employee", "phone", "address", "state", "gstin"]),
	dict(step="Z.erpitemall", sys=MT, db="mt", key="items", extra='"kind":"items",', sql=bp.ITEMS_SQL, when="nightly 01:20",
		cols=["code", "name", "active", "uom", "hsn"]),
	dict(step="Z.erpweight", sys=HT, db="ht", key="weights", extra='"kind":"weights",', sql=sql_from("weights/weights.sql"), when="minutes 8,38",
		cols=["code", "wpr", "bpr"]),
	dict(step="Z.erpcredit", sys=MT, db="mt", key="credit", extra='"kind":"credit",', sql=sql_from("credit/credit.sql"), when="minutes 3,18,33,48",
		cols=["code", "limit", "balance", "terms_code", "terms", "b1", "b2", "b3", "b4", "od_amt", "od_days"]),
	dict(step="Z.erpinv", sys=MT, db="mt", key="invoices", extra='"kind":"invoices",', sql=sql_from("invoices/invoices.sql"), when="minutes 4,19,34,49",
		cols=["entry", "num", "code", "date", "due", "total", "paid", "status"]),
	dict(step="Z.erppay", sys=MT, db="mt", key="payments", extra='"kind":"payments",', sql=sql_from("payments/payments.sql"), when="minutes 2,7,...,57",
		cols=["entry", "num", "code", "date", "amount", "on_account", "cancelled", "mode", "reference", "remarks", "invoices"]),
	dict(step="Z.erpprice", sys=MT, db="mt", key="mt", extra='"kind":"pricing",', sql=sql_from("pricing/pricing_manna.sql"), when="minutes 12,42",
		cols=["k"] + ["c%02d" % n for n in range(1, 15)],
		sys2=HT, db2="ht", sql2=sql_from("pricing/pricing_hitech.sql"), cols2=["k"] + ["c%02d" % n for n in range(1, 12)]),
]
for s in STEPS:
	s.update(pkg=PKG, obj=None, keycol=None, endpoint="manna_sap_in")


def array_members(cols):
	return "\n".join(
		"""				<xsl:text>%s"</xsl:text><xsl:call-template name="esc"><xsl:with-param name="s" select="string(*[local-name()='%s'])"/></xsl:call-template><xsl:text>"</xsl:text>""" % ("," if i else "", c)
		for i, c in enumerate(cols))


def two_set_json_xsl(p):
	"""atom3 for a step with two result sets: {"kind":..,"dry_run":..,"mt":[[k,c01..]],"ht":[[k,c01..]]} - each row an array, values as text."""
	base = bp.json_xsl(p)
	a = base.index('		<xsl:variable name="rows"')
	b = base.index("	</xsl:template>", a)
	body = """		<xsl:variable name="one" select="/vpf:Msg/vpf:Body/vpf:Payload[@id='atom2']//*[local-name()='Row']"/>
		<xsl:variable name="two" select="/vpf:Msg/vpf:Body/vpf:Payload[@id='atom7']//*[local-name()='Row']"/>
		<Http xmlns="">
			<Endpoint>/api/method/manna_sap_in</Endpoint>
			<ContentType>application/json</ContentType>
			<Count><xsl:value-of select="count($one) + count($two)"/></Count>
			<Body>
				<xsl:text>{%s"dry_run":</xsl:text><xsl:value-of select="$dryRun"/><xsl:text>,"mt":[</xsl:text>
				<xsl:for-each select="$one">
				<xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
				<xsl:text>[</xsl:text>
%s
				<xsl:text>]</xsl:text>
				</xsl:for-each>
				<xsl:text>],"ht":[</xsl:text>
				<xsl:for-each select="$two">
				<xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
				<xsl:text>[</xsl:text>
%s
				<xsl:text>]</xsl:text>
				</xsl:for-each>
				<xsl:text>]}</xsl:text>
			</Body>
		</Http>
""" % (p["extra"], array_members(p["cols"]), array_members(p["cols2"]))
	return base[:a] + body + base[b:]


def flow(p):
	f = bp.bfd(p)
	if not p.get("sql2"):
		return f
	# The second query: atom6 writes it, atom7 runs it on the other company - a copy of atom2's call.
	a = f.index('<include name="atom2"')
	b = f.index("</include>", a) + len("</include>")
	call2 = (f[a:b].replace('name="atom2"', 'name="atom7"').replace('bfxp_value="#atom2"', 'bfxp_value="#atom7"')
		.replace("#%s" % p["sys"], "#%s" % p["sys2"]).replace("@id=&apos;atom1&apos;", "@id=&apos;atom6&apos;"))
	assert "#%s" % p["sys2"] in call2 and "atom6" in call2
	return f[:b] + bp.xform("atom6", "Build the second query") + call2 + f[b:]


def main():
	src = zipfile.ZipFile(os.path.join(HERE, "..", "exports", "Z.mannaic-step1-2026-11-05.zip"))
	base = "com.sap.b1i.vplatform.scenarios.design/vBIU.Z.mannaicmtpo/"
	atom0, vvar = src.read(base + "atom0.xsl"), src.read(base + "vVar.xsl")
	atom5 = open(os.path.join(HERE, "atom5_http.xsl"), "rb").read()
	out = os.path.join(bp.OUT, PKG)
	os.makedirs(out, exist_ok=True)
	z = zipfile.ZipFile(os.path.join(bp.OUT, PKG + ".zip"), "w", zipfile.ZIP_DEFLATED)
	z.writestr("b1ifident/b1ifident/b1ifident.xml", '<?xml version="1.0" encoding="UTF-8"?><b1ifident xmlns:bfa="urn:com.sap.b1i.bizprocessor:bizatoms"><id>%s</id><type>vPac</type><ver>1.0.0</ver></b1ifident>' % PKG)
	manifest = []
	for p in STEPS:
		d = os.path.join(out, p["step"])
		os.makedirs(d, exist_ok=True)
		files = {"atom1.xsl": bp.sql_xsl(p), "atom3.xsl": two_set_json_xsl(p) if p.get("sql2") else bp.json_xsl(p)}
		if p.get("sql2"):
			files["atom6.xsl"] = bp.sql_xsl(dict(p, sql=p["sql2"], cols=p["cols2"]))
		folder = "com.sap.b1i.vplatform.scenarios.design/vBIU.%s/" % p["step"]
		for n, text in files.items():
			assert "&#" not in text, n
			open(os.path.join(d, n), "w", encoding="utf-8").write(text)
			z.writestr(folder + n, text.encode("utf-8"))
		z.writestr(folder + "atom0.xsl", atom0)
		z.writestr(folder + "atom5.xsl", atom5)
		z.writestr(folder + "vBIU.bfd", flow(p))
		z.writestr(folder + "vBIU.xml", bp.vbiu(p))
		z.writestr(folder + "vVar.xsl", vvar)
		manifest.append({"step": p["step"], "db": p["db"], "db2": p.get("db2", ""), "when": p["when"]})
		print("step", p["step"], "sender", p["sys"], ("+ " + p["sys2"]) if p.get("sys2") else "", "-", p["when"])
	steps = "".join('<vBIU Id="%s"></vBIU>' % p["step"] for p in STEPS)
	one = bp.vpac(dict(pkg=PKG, step="X", desc="The rest of the SAP -> ERPNext syncs, on timers: nightly customers and items, roll figures, credit, invoices, payments, the price snapshot"))
	z.writestr("com.sap.b1i.vplatform.scenarios.design/vPac.%s/vPac.xml" % PKG, one.replace('<vBIU Id="X"></vBIU>', steps))
	z.close()
	json.dump(manifest, open(os.path.join(out, "manifest.json"), "w"), indent=1)
	print("built", os.path.join(bp.OUT, PKG + ".zip"))


if __name__ == "__main__":
	main()
