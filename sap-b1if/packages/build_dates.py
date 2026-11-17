# Builds Z.mannaicdt (13 Nov 2026): the delivery-date step, as a zip B1if imports.
#
#     python build_dates.py        writes out/Z.mannaicdt.zip and out/Z.mannaicdt/*.xsl
#
# One timer step, Z.mannaicdate, every minute: read what Hi-Tech promises
# (../step6-dates/sql-ht.xsl), compare it in SQL with Manna Treads' purchase
# order and sales order (sql-mt.xsl), and update the one pair whose dates
# differ (final.xsl), each document through its own B1 Object atom.
#
#   atom1  sql-ht.xsl   xform    the Hi-Tech statement
#   atom2               Call SQL on Hi-Tech
#   atom3  sql-mt.xsl   xform    the Manna Treads statement, Hi-Tech's rows carried in it
#   atom4               Call SQL on Manna Treads
#   atom5  final.xsl    xform    the decision
#   atom6  bom.xsl      xform    the sales order's update, for atom7
#   atom7               B1 Object on Manna Treads (update object 17, or a read)
#   atom8  bom.xsl      xform    the purchase order's update, for atom9
#   atom9               B1 Object on Manna Treads (update object 22, or a read)
#   atom0               B1if's own final atom
#
# The flow's XML is the pick-list step's, as B1if itself exported it
# (../exports/Z.mannaicpk-2026-11-13.zip): the same Call SQL and B1 Object
# includes with other atoms named in them. Named Z.mannaic..., so that
# retarget_package.py's "--rename Z.mannaic=Z.LIVEmannaic" makes the live copy
# of this one as it made the others.
#
# Built against the TEST companies' SLD ids. Nothing in it writes until BOTH
# companies' @MANNA_IC say ENABLED = Y and Manna Treads' says DATE_SYNC = Y -
# a setting of this step's own, so the order flow can be on with this off.
import os, zipfile
from xml.sax.saxutils import escape
import build_packages as bp

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "step6-dates")
PKG, STEP = "Z.mannaicdt", "Z.mannaicdate"
MT, HT = bp.MANNA_TEST, bp.HITECH_TEST
NSLIST = escape(bp.NS, {"'": "&apos;"})


def callsql(atom, sys_id, sql_atom):
	# throwexception true: a statement SQL Server refuses must show as a failed
	# message, not as "the query returned nothing".
	return ('<include name="%s" nslist="%s"><description>SQL Call to Database</description><subflow optional="false">'
		'<intended bfxp_href="#/com.sap.b1i.vplatform.runtime/vCall/callsql.bfd"></intended><propertylist>'
		'<property name="bpc.maxDumpSize" bfxp_value="#!bpc.b1ifDumpSize_"></property><property name="atom" bfxp_value="#%s"></property>'
		'<property name="sessionid" bfxp_value="#!sessionid_"></property><property name="userid" bfxp_value="#!userid_"></property>'
		'<property name="vbiu" bfxp_value="#!vBIU_"></property><property name="SysId" bfxp_value="#%s"></property>'
		'<property name="SQL" bfxp_value="/vpf:Msg/vpf:Body/vpf:Payload[@id=&apos;%s&apos;]/Sql/Statement"></property>'
		'<property name="SQLH" bfxp_value="#"></property><property name="method" bfxp_value="#Automatic detection by key word"></property>'
		'<property name="mode" bfxp_value="#Single Processing"></property><property name="blockdeli" bfxp_value="#;"></property>'
		'<property name="throwexception" bfxp_value="#true"></property><property name="committype" bfxp_value="#2PC"></property>'
		'</propertylist></subflow></include>') % (atom, NSLIST, atom, sys_id, sql_atom)


def callb1(atom, sys_id, part, payload_atom):
	d = "/vpf:Msg/vpf:Body/vpf:Payload[@id=&apos;atom5&apos;]/Decision/%s/" % part
	return ('<include name="%s" nslist="%s"><description>Call SAP Business One Object Using DI API</description><subflow optional="false">'
		'<intended bfxp_href="#/com.sap.b1i.vplatform.runtime/vCall/callb1obj.bfd"></intended><propertylist>'
		'<property name="bpc.maxDumpSize" bfxp_value="#!bpc.b1ifDumpSize_"></property><property name="atom" bfxp_value="#%s"></property>'
		'<property name="sessionid" bfxp_value="#!sessionid_"></property><property name="userid" bfxp_value="#!userid_"></property>'
		'<property name="vbiu" bfxp_value="#!vBIU_"></property><property name="SysId" bfxp_value="#%s"></property>'
		'<property name="Method" bfxp_value="%sCallMethod"></property><property name="Object" bfxp_value="%sCallObject"></property>'
		'<property name="KeyName" bfxp_value="%sCallKeyName"></property><property name="KeyValue" bfxp_value="%sCallKey"></property>'
		'<property name="Payload" bfxp_value="#%s"></property><property name="B1Login" bfxp_value="#Technical User"></property>'
		'<property name="throwException" bfxp_value="#true"></property><property name="Mode" bfxp_value="#"></property>'
		'</propertylist></subflow></include>') % (atom, NSLIST, atom, sys_id, d, d, d, d, payload_atom)


def flow():
	atoms = (bp.xform("atom1", "What Hi-Tech promises") + callsql("atom2", HT, "atom1")
		+ bp.xform("atom3", "Compare with Manna Treads") + callsql("atom4", MT, "atom3")
		+ bp.xform("atom5", "Decide")
		+ bp.xform("atom6", "Predecessor Transformation for b1object Atom") + callb1("atom7", MT, "So", "atom6")
		+ bp.xform("atom8", "Predecessor Transformation for b1object Atom") + callb1("atom9", MT, "Po", "atom8")
		+ bp.xform("atom0", "Invoke XSLT file to convert import object to result object", final=True))
	# The head and tail of bp.bfd(), which are the same for every step.
	shell = bp.bfd(dict(step=STEP, sys=HT))
	a, b = shell.index("<bizatoms>") + len("<bizatoms>"), shell.index("</bizatoms>")
	return shell[:a] + atoms + shell[b:]


def read(name):
	return open(os.path.join(SRC, name), encoding="utf-8").read()


def files():
	bom = read("bom.xsl")
	po = bom.replace("""<xsl:param name="part" select="'So'"/>""", """<xsl:param name="part" select="'Po'"/>""")
	assert po != bom
	return {"atom1.xsl": read("sql-ht.xsl"), "atom3.xsl": read("sql-mt.xsl"), "atom5.xsl": read("final.xsl"), "atom6.xsl": bom, "atom8.xsl": po}


def main():
	src = zipfile.ZipFile(os.path.join(HERE, "..", "exports", "Z.mannaic-step1-2026-11-05.zip"))
	base = "com.sap.b1i.vplatform.scenarios.design/vBIU.Z.mannaicmtpo/"
	atom0, vvar = src.read(base + "atom0.xsl"), src.read(base + "vVar.xsl")
	out = os.path.join(bp.OUT, PKG)
	os.makedirs(out, exist_ok=True)
	p = dict(pkg=PKG, step=STEP, obj=None, cron=("*", "*"),
		desc="Hi-Tech sales order delivery dates -> Manna Treads sales order and purchase order, timer")
	folder = "com.sap.b1i.vplatform.scenarios.design/vBIU.%s/" % STEP
	z = zipfile.ZipFile(os.path.join(bp.OUT, PKG + ".zip"), "w", zipfile.ZIP_DEFLATED)
	z.writestr("b1ifident/b1ifident/b1ifident.xml", '<?xml version="1.0" encoding="UTF-8"?><b1ifident xmlns:bfa="urn:com.sap.b1i.bizprocessor:bizatoms"><id>%s</id><type>vPac</type><ver>1.0.0</ver></b1ifident>' % PKG)
	for n, text in files().items():
		# B1if spoils a character reference in an imported stylesheet (see build_packages.py).
		assert "&#" not in text, n
		open(os.path.join(out, n), "w", encoding="utf-8", newline="").write(text)
		z.writestr(folder + n, text.encode("utf-8"))
	z.writestr(folder + "atom0.xsl", atom0)
	z.writestr(folder + "vBIU.bfd", flow())
	z.writestr(folder + "vBIU.xml", bp.vbiu(p))
	z.writestr(folder + "vVar.xsl", vvar)
	z.writestr("com.sap.b1i.vplatform.scenarios.design/vPac.%s/vPac.xml" % PKG, bp.vpac(p).replace('BizArea="ERPNext"', 'BizArea="Intercompany"'))
	z.close()
	print("built", PKG + ".zip", "step", STEP, "- Hi-Tech", HT, "Manna Treads", MT, "- TIMER every minute")


if __name__ == "__main__":
	main()
