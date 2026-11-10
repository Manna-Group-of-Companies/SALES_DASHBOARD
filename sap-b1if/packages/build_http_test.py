# One-off experiment (10 Nov 2026): which shape of <payload> makes B1if's Call
# HTTP atom actually send a JSON body. The first try - JSON as plain text in
# <payload> with <pltype>txt</pltype> - arrived at ERPNext with the right
# headers and Content-Length: 0 (read off the wire).
#
# Builds out-httptest/Z.erpcust.zip: the customer step with FOUR Call HTTP atoms,
# one per candidate, all in one run (throwexception false, so each is tried).
# Every body is a dry run and carries "variant" so the arrival can be told apart:
#   V1  pltype txt,  <bfa:io pltype="txt">json text</bfa:io>
#   V2  pltype json, <bfa:io pltype="json"><object>..</object></bfa:io>   (B1if's JSON-as-XML model)
#   V3  pltype json, <object>..</object> directly
#   V4  pltype json, json text in <payload>
import os, zipfile
import build_packages as bp

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out-httptest")
HEAD = bp.HEAD.replace('exclude-result-prefixes="vpf bfa"', 'exclude-result-prefixes="vpf"')
HTTA = ('<htta><par id="httpheader.Content-Type" value="application/json"/><par id="httpheader.Accept" value="application/json"/>'
	'<par id="htta.returnpltypeforce" value="txt"/></htta>')
TEXT = ('<xsl:text>{"kind":"customers","dry_run":1,"variant":"%s","customers":[{"code":"</xsl:text>'
	'<xsl:value-of select="$row/*[local-name()=\'code\']"/><xsl:text>","active":"Y"}]}</xsl:text>')
MODEL = ('<object><string name="kind">customers</string><number name="dry_run">1</number><string name="variant">%s</string>'
	'<array name="customers"><object><string name="code"><xsl:value-of select="$row/*[local-name()=\'code\']"/></string>'
	'<string name="active">Y</string></object></array></object>')
VARIANTS = [
	("V1", "txt", '<bfa:io pltype="txt">' + TEXT % "V1" + '</bfa:io>'),
	("V2", "json", '<bfa:io pltype="json">' + MODEL % "V2" + '</bfa:io>'),
	("V3", "json", MODEL % "V3"),
	("V4", "json", TEXT % "V4"),
]


def variant_xsl(pltype, payload):
	return HEAD + """
	<xsl:template name="transform">
		<xsl:variable name="row" select="(/vpf:Msg/vpf:Body/vpf:Payload[@id='atom2']//*[local-name()='Row'])[1]"/>
		<call xmlns="">
			<pltype>%s</pltype>
			<payload>%s</payload>
			%s
		</call>
	</xsl:template>
</xsl:stylesheet>
""" % (pltype, payload, HTTA)


def main():
	p = next(x for x in bp.PACKAGES if x["pkg"] == "Z.erpcust")
	src = zipfile.ZipFile(os.path.join(HERE, "..", "exports", "Z.mannaic-step1-2026-11-05.zip"))
	base = "com.sap.b1i.vplatform.scenarios.design/vBIU.Z.mannaicmtpo/"
	flow = bp.bfd(p)
	one = bp.xform("atom5", "Predecessor Transformation for httpcall Atom")
	a, b = flow.index(one), flow.index('<xform name="atom0"')
	pair = flow[a:b]
	pairs = ""
	for i, (name, _, _) in enumerate(VARIANTS):
		pre, call = "atom%d" % (5 + 2 * i), "atom%d" % (4 + 2 * i)
		pairs += (pair.replace("atom5", pre).replace("atom4", call)
			.replace('name="throwexception" bfxp_value="#true"', 'name="throwexception" bfxp_value="#false"')
			.replace("Call Function Using HTTP", "Call HTTP, payload variant " + name))
	flow = flow[:a] + pairs + flow[b:]
	os.makedirs(OUT, exist_ok=True)
	step = "com.sap.b1i.vplatform.scenarios.design/vBIU.%s/" % p["step"]
	z = zipfile.ZipFile(os.path.join(OUT, "Z.erpcust.zip"), "w", zipfile.ZIP_DEFLATED)
	z.writestr("b1ifident/b1ifident/b1ifident.xml", '<?xml version="1.0" encoding="UTF-8"?><b1ifident xmlns:bfa="urn:com.sap.b1i.bizprocessor:bizatoms"><id>%s</id><type>vPac</type><ver>1.0.0</ver></b1ifident>' % p["pkg"])
	z.writestr(step + "atom0.xsl", src.read(base + "atom0.xsl"))
	z.writestr(step + "atom1.xsl", bp.sql_xsl(p).encode("utf-8"))
	z.writestr(step + "atom3.xsl", bp.json_xsl(p).encode("utf-8"))
	for i, (name, pltype, payload) in enumerate(VARIANTS):
		x = variant_xsl(pltype, payload)
		open(os.path.join(OUT, "variant_%s.xsl" % name), "w", encoding="utf-8").write(x)
		z.writestr(step + "atom%d.xsl" % (5 + 2 * i), x.encode("utf-8"))
	z.writestr(step + "vBIU.bfd", flow)
	z.writestr(step + "vBIU.xml", bp.vbiu(p))
	z.writestr(step + "vVar.xsl", src.read(base + "vVar.xsl"))
	z.writestr("com.sap.b1i.vplatform.scenarios.design/vPac.%s/vPac.xml" % p["pkg"], bp.vpac(p))
	z.close()
	print("built", os.path.join(OUT, "Z.erpcust.zip"))


if __name__ == "__main__":
	main()
