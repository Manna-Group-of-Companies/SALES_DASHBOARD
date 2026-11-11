# Builds the B1iF packages that send SAP data to ERPNext (9 Nov 2026), as zips
# B1iF imports: Control Center -> Development Environment -> Import.
#
#     python build_packages.py            writes out/*.zip and out/<package>/*.xsl
#
# Each package has one step: an xform that writes the SQL (atom1), Call SQL on
# the sender (atom2), an xform that turns the rows into the JSON body the
# ERPNext endpoint takes (atom3), and B1if's own final atom (atom0). The HTTP
# call that posts atom3's body is NOT in the zip - it is added by hand in the
# Process Flow designer (see SETUP.md), because none of our exports holds one
# to copy its XML from, and a guessed atom is worse than a missing one.
#
# The SQL is the same text as ../<sync>/*.sql, without DECLARE: Call SQL's
# "automatic detection by key word" wants the statement to start with SELECT,
# and B1if puts no value into the SQL atom's own text (the event key goes in
# through atom1, quoted, as step 1 of Z.mannaic does it).
#
# The zip layout copies exports/Z.mannaic-step1-2026-11-05.zip; entry names use
# forward slashes like that export. Every step is built INACTIVE in effect: a
# package does nothing until it is activated in Scenarios -> Control.
import os, re, zipfile, datetime
from xml.sax.saxutils import escape

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
MANNA_TEST, HITECH_TEST = "0010000119", "0010000120"   # SLD ids of the TEST companies (4 Nov 2026)
ERPNEXT_SYS = "0010000121"   # SLD system ERPNEXT_LOCAL (H.AnySystem): host, port, path /api/method/manna_sap_in, basic login
DRY_RUN = 1   # the first posts only report; set 0 (or edit atom3.xsl) once a dry run reads right

NS = ("xmlns:bfa='urn:com.sap.b1i.bizprocessor:bizatoms' xmlns:xci='urn:com.sap.b1i.xcellerator:intdoc' "
	"xmlns:b1e='urn:com.sap.b1i.sim:b1event' xmlns:b1ie='urn:com.sap.b1i.sim:b1ievent' xmlns:vpf='urn:com.sap.b1i.vplatform:entity' "
	"xmlns:jdbc='urn:com.sap.b1i.adapter:jdbcadapter' xmlns:rfc='urn:sap-com:document:sap:rfc:functions' xmlns:sim='urn:com.sap.b1i.sim:entity' "
	"xmlns:utils2='com.sap.b1i.bpc_tools.Utilities' xmlns:b1im='urn:com.sap.b1i.sim:b1imessage' xmlns:uplt='urn:com.sap.b1i.xcellerator:upltdoc' "
	"xmlns:js='com.sap.b1i.bpc_tools.Javascript' ")

CUSTOMERS_SQL = """SELECT
	C.CardCode AS code,
	C.CardName AS name,
	CASE WHEN C.validFor = 'N' OR C.frozenFor = 'Y' THEN 'N' ELSE 'Y' END AS active,
	ISNULL(S.SlpName, '') AS sales_employee,
	COALESCE(NULLIF(LTRIM(RTRIM(C.Cellular)), ''), LTRIM(RTRIM(ISNULL(C.Phone1, '')))) AS phone,
	ISNULL(STUFF(
		ISNULL(', ' + NULLIF(LTRIM(RTRIM(B.Street)), ''), '') + ISNULL(', ' + NULLIF(LTRIM(RTRIM(B.Block)), ''), '') +
		ISNULL(', ' + NULLIF(LTRIM(RTRIM(B.City)), ''), '') + ISNULL(', ' + NULLIF(LTRIM(RTRIM(B.State)), ''), '') +
		ISNULL(', ' + NULLIF(LTRIM(RTRIM(B.ZipCode)), ''), '') + ISNULL(', ' + NULLIF(LTRIM(RTRIM(B.Country)), ''), ''), 1, 2, ''), '') AS address,
	COALESCE(ST.Name, B.State, '') AS state,
	ISNULL(G.GSTRegnNo, '') AS gstin
FROM OCRD C
LEFT JOIN OSLP S ON S.SlpCode = C.SlpCode AND C.SlpCode &lt;&gt; -1
OUTER APPLY (SELECT TOP 1 A.Street, A.Block, A.City, A.State, A.ZipCode, A.Country FROM CRD1 A WHERE A.CardCode = C.CardCode
	ORDER BY CASE WHEN A.AdresType = 'B' AND A.Address = C.BillToDef THEN 0 WHEN A.AdresType = 'B' THEN 1 ELSE 2 END, A.LineNum) B
LEFT JOIN OCST ST ON ST.Code = B.State AND ST.Country = B.Country
OUTER APPLY (SELECT TOP 1 A.GSTRegnNo FROM CRD1 A WHERE A.CardCode = C.CardCode AND ISNULL(A.GSTRegnNo, '') &lt;&gt; ''
	ORDER BY CASE WHEN A.AdresType = 'B' THEN 0 ELSE 1 END, A.LineNum) G
WHERE C.CardType = 'C'"""

ITEMS_SQL = """SELECT
	I.ItemCode AS code,
	I.ItemName AS name,
	CASE WHEN I.validFor = 'N' OR I.frozenFor = 'Y' THEN 'N' ELSE 'Y' END AS active,
	LTRIM(RTRIM(ISNULL(I.InvntryUom, ''))) AS uom,
	ISNULL(C.ChapterID, '') AS hsn
FROM OITM I
LEFT JOIN OCHP C ON C.AbsEntry = I.ChapterID
WHERE I.SellItem = 'Y'"""

# Warehouse 01 STORE: the one the order flow picks from (see ../stock/stock.sql). The same text as that file.
STOCK_SQL = """SELECT W.ItemCode AS code, CAST(W.OnHand - W.IsCommited AS decimal(19, 3)) AS qty
FROM OITW W
JOIN OITM I ON I.ItemCode = W.ItemCode
WHERE W.WhsCode = N'01' AND I.SellItem = 'Y' AND I.InvntItem = 'Y'
ORDER BY W.ItemCode"""

STATUS_HT_SQL = """SELECT
	H.NumAtCard AS [order],
	L.ItemCode AS item,
	CASE
		WHEN H.CANCELED &lt;&gt; 'N' THEN 'Cancelled'
		WHEN L.DelivrdQty &gt; 0 OR P.Picked = 1 OR V.Invoiced = 1 THEN 'Picked'
		WHEN L.LineStatus = 'C' THEN 'Cancelled'
		ELSE 'In SAP'
	END AS stage
FROM ORDR H
JOIN RDR1 L ON L.DocEntry = H.DocEntry
OUTER APPLY (SELECT TOP 1 1 AS Picked FROM PKL1 K JOIN OPKL Q ON Q.AbsEntry = K.AbsEntry
	WHERE K.BaseObject = 17 AND K.OrderEntry = H.DocEntry AND K.OrderLine = L.LineNum AND ISNULL(Q.U_Confirmed, 'N') = 'Y'
		AND (K.PickQtty &gt; 0 OR (K.RelQtty &gt; 0 AND NOT EXISTS (SELECT 1 FROM PKL1 Z WHERE Z.AbsEntry = K.AbsEntry AND Z.PickQtty &gt; 0)))) P
OUTER APPLY (SELECT TOP 1 1 AS Invoiced FROM INV1 I JOIN OINV J ON J.DocEntry = I.DocEntry AND J.CANCELED = 'N'
	WHERE I.BaseType = 17 AND I.BaseEntry = H.DocEntry AND I.BaseLine = L.LineNum) V
WHERE H.NumAtCard LIKE N'SAL-ORD-%'
	AND (H.DocStatus = 'O' OR H.UpdateDate &gt;= DATEADD(day, -120, CAST(GETDATE() AS date)))
	AND ISNULL(L.ItemCode, '') &lt;&gt; ''
ORDER BY H.NumAtCard, L.LineNum"""

STATUS_MT_SQL = """SELECT
	H.NumAtCard AS [order],
	L.ItemCode AS item,
	CASE WHEN H.CANCELED = 'N' AND (D1.Hit = 1 OR D2.Hit = 1) THEN 'Dispatched' ELSE '' END AS stage
FROM ORDR H
JOIN RDR1 L ON L.DocEntry = H.DocEntry
OUTER APPLY (SELECT TOP 1 1 AS Hit FROM INV1 I JOIN OINV J ON J.DocEntry = I.DocEntry AND J.CANCELED = 'N'
	WHERE I.BaseType = 17 AND I.BaseEntry = H.DocEntry AND I.BaseLine = L.LineNum) D1
OUTER APPLY (SELECT TOP 1 1 AS Hit FROM INV1 I JOIN OINV J ON J.DocEntry = I.DocEntry AND J.CANCELED = 'N'
	JOIN DLN1 N ON I.BaseType = 15 AND N.DocEntry = I.BaseEntry AND N.LineNum = I.BaseLine
	JOIN ODLN M ON M.DocEntry = N.DocEntry AND M.CANCELED = 'N'
	WHERE N.BaseType = 17 AND N.BaseEntry = H.DocEntry AND N.BaseLine = L.LineNum) D2
WHERE H.NumAtCard LIKE N'SAL-ORD-%'
	AND (H.DocStatus = 'O' OR H.UpdateDate &gt;= DATEADD(day, -120, CAST(GETDATE() AS date)))
	AND ISNULL(L.ItemCode, '') &lt;&gt; ''
ORDER BY H.NumAtCard, L.LineNum"""

def every(n, first):
	"""Minutes of the hour: every n, starting at `first` - "1,6,11,...,56"."""
	return ",".join(str(m) for m in range(first, 60, n))


# id, step, sender, trigger (B1 object for an event; None = timer, with cron = (minute, hour)), endpoint, JSON list key,
# columns, SQL, the event key's column (event packages), extra JSON members, description
PACKAGES = [
	dict(pkg="Z.erpcust", step="Z.erpcustbp", sys=MANNA_TEST, obj="2", endpoint="manna_sap_customers", key="customers",
		cols=["code", "name", "active", "sales_employee", "phone", "address", "state", "gstin"], sql=CUSTOMERS_SQL,
		keycol="C.CardCode", extra='"kind":"customers",', desc="Manna Treads customer add/update -> ERPNext Customer (manna_sap_customers)"),
	dict(pkg="Z.erpitem", step="Z.erpitemit", sys=MANNA_TEST, obj="4", endpoint="manna_sap_items", key="items",
		cols=["code", "name", "active", "uom", "hsn"], sql=ITEMS_SQL,
		keycol="I.ItemCode", extra='"kind":"items",', desc="Manna Treads item add/update -> ERPNext Item, shared codes only (manna_sap_items)"),
	dict(pkg="Z.erpstock", step="Z.erpstockht", cron=(every(5, 0), "*"), sys=HITECH_TEST, obj=None, endpoint="manna_sap_stock", key="stock",
		cols=["code", "qty"], sql=STOCK_SQL, keycol=None, extra='"kind":"stock",', desc="Hi-Tech 01 STORE available to promise -> ERPNext Finished Goods - MT (manna_sap_stock), timer"),
	dict(pkg="Z.erpstatht", step="Z.erpstathtso", cron=(every(5, 1), "*"), sys=HITECH_TEST, obj=None, endpoint="manna_sap_status", key="lines",
		cols=["order", "item", "stage"], sql=STATUS_HT_SQL, keycol=None, extra='"kind":"status","source":"hitech",',
		desc="Hi-Tech SO lines (In SAP / Picked / Cancelled) -> ERPNext order status (manna_sap_status), timer"),
	dict(pkg="Z.erpstatmt", step="Z.erpstatmtso", cron=(every(5, 2), "*"), sys=MANNA_TEST, obj=None, endpoint="manna_sap_status", key="lines",
		cols=["order", "item", "stage"], sql=STATUS_MT_SQL, keycol=None, extra='"kind":"status","source":"manna",',
		desc="Manna Treads invoiced SO lines (Dispatched) -> ERPNext order status (manna_sap_status), timer"),
]

HEAD = """<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0"
	xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
	xmlns:vpf="urn:com.sap.b1i.vplatform:entity"
	xmlns:bfa="urn:com.sap.b1i.bizprocessor:bizatoms"
	bfa:force=""
	exclude-result-prefixes="vpf bfa">
	<xsl:output method="xml"/>
	<xsl:param name="atom"/>

	<xsl:template match="/">
		<vpf:Msg>
			<xsl:copy-of select="/vpf:Msg/@*"/>
			<xsl:copy-of select="/vpf:Msg/vpf:Header"/>
			<vpf:Body>
				<xsl:copy-of select="/vpf:Msg/vpf:Body/*"/>
				<vpf:Payload Role="X" id="{$atom}">
					<xsl:call-template name="transform"/>
				</vpf:Payload>
			</vpf:Body>
		</vpf:Msg>
	</xsl:template>
"""


# When SAP read the batch, in UTC, on every row (11 Nov 2026). atom3 puts the
# first row's into the body as "sent_at" and ERPNext ignores a whole-state batch
# older than ten minutes (manna_sap_in, MAX_AGE): B1if keeps every message it
# could not deliver and sends them all once ERPNext answers again, and an old
# shelf or an old set of order stages must not be written over a newer one. On
# the rows because Call SQL returns nothing but rows; UTC so that neither
# server's time zone matters. A result with no rows carries no time, and
# ERPNext lets that through.
SENT_AT = ", CONVERT(varchar(19), GETUTCDATE(), 120) AS [sent_at]"


def clean_select(cols):
	"""The outer SELECT put round every statement: each column as text with tab,
	CR and LF turned into a space - in SQL, where no stylesheet can spoil it."""
	return "SELECT " + ", ".join(
		"REPLACE(REPLACE(REPLACE(CAST(Q.[%s] AS nvarchar(4000)), CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' ') AS [%s]" % (c, c) for c in cols) + SENT_AT + " FROM ("


def inner_sql(sql):
	# A derived table may not end in ORDER BY; no endpoint depends on the order.
	return re.sub(r"\s+ORDER BY [^()]*$", "", sql.strip())


def sql_xsl(p):
	p = dict(p, sql=inner_sql(p["sql"]), head=clean_select(p["cols"]))
	if p["obj"]:
		body = """
	<xsl:template name="transform">
		<!-- The event's key (CardCode / ItemCode), matched by local name. It goes
		     into the statement quoted, quotes doubled, so nothing in it can become
		     SQL; a key longer than SAP allows sends nothing. -->
		<xsl:variable name="trigger" select="/vpf:Msg/vpf:Body/vpf:Payload[@Role='T']"/>
		<xsl:variable name="raw" select="normalize-space(string(($trigger//*[local-name()='keys']//*[local-name()='value'] | $trigger//*[local-name()='key']/*[local-name()='value'])[1]))"/>
		<Sql xmlns="">
			<Key><xsl:value-of select="$raw"/></Key>
			<Statement>
				<xsl:choose>
					<xsl:when test="$raw = '' or string-length($raw) &gt; 50">SELECT TOP 0 '' AS code</xsl:when>
					<xsl:otherwise>%s%s AND %s = N'<xsl:call-template name="quote"><xsl:with-param name="s" select="$raw"/></xsl:call-template>') Q</xsl:otherwise>
				</xsl:choose>
			</Statement>
		</Sql>
	</xsl:template>

	<xsl:template name="quote">
		<xsl:param name="s"/>
		<xsl:choose>
			<xsl:when test="contains($s, &quot;'&quot;)"><xsl:value-of select="substring-before($s, &quot;'&quot;)"/>''<xsl:call-template name="quote"><xsl:with-param name="s" select="substring-after($s, &quot;'&quot;)"/></xsl:call-template></xsl:when>
			<xsl:otherwise><xsl:value-of select="$s"/></xsl:otherwise>
		</xsl:choose>
	</xsl:template>
</xsl:stylesheet>
""" % (p["head"], p["sql"], p["keycol"])
	else:
		body = """
	<xsl:template name="transform">
		<!-- A timer step: the whole set every run, no key. -->
		<Sql xmlns="">
			<Statement>%s%s) Q</Statement>
		</Sql>
	</xsl:template>
</xsl:stylesheet>
""" % (p["head"], p["sql"])
	return "<!-- %s: atom1, the statement Call SQL (atom2) runs on the sender. Generated by build_packages.py. -->\n" % p["pkg"] + HEAD.replace('<?xml version="1.0" encoding="UTF-8"?>\n', '', 1) + body


def json_xsl(p):
	members = "\n".join(
		"""				<xsl:text>%s"%s":"</xsl:text><xsl:call-template name="esc"><xsl:with-param name="s" select="string(*[local-name()='%s'])"/></xsl:call-template><xsl:text>"</xsl:text>""" % ("," if i else "", c, c)
		for i, c in enumerate(p["cols"]))
	return """<?xml version="1.0" encoding="UTF-8"?>
<!-- %(pkg)s: atom3, the rows Call SQL (atom2) read, as the JSON body ERPNext's
     %(endpoint)s takes. The HTTP call added after this atom posts
     /vpf:Msg/vpf:Body/vpf:Payload[@id='atom3']/Http/Body with Content-Type
     application/json. Generated by build_packages.py. -->
""" % p + HEAD.replace('<?xml version="1.0" encoding="UTF-8"?>\n', '', 1).replace('<xsl:param name="atom"/>', '<xsl:param name="atom"/>\n\t<!-- 1: ERPNext only reports what it would do. 0: it writes. -->\n\t<xsl:variable name="dryRun" select="\'%d\'"/>' % DRY_RUN) + """
	<xsl:template name="transform">
		<xsl:variable name="rows" select="/vpf:Msg/vpf:Body/vpf:Payload[@id='atom2']//*[local-name()='Row']"/>
		<Http xmlns="">
			<Endpoint>/api/method/manna_sap_in</Endpoint>
			<ContentType>application/json</ContentType>
			<Count><xsl:value-of select="count($rows)"/></Count>
			<Body>
				<xsl:text>{%(extra)s"sent_at":"</xsl:text><xsl:value-of select="normalize-space($rows[1]/*[local-name()='sent_at'])"/><xsl:text>","dry_run":</xsl:text><xsl:value-of select="$dryRun"/><xsl:text>,"%(key)s":[</xsl:text>
				<xsl:for-each select="$rows">
				<xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
				<xsl:text>{</xsl:text>
%(members)s
				<xsl:text>}</xsl:text>
				</xsl:for-each>
				<xsl:text>]}</xsl:text>
			</Body>
		</Http>
	</xsl:template>

	<!-- A JSON string: backslash and quote escaped. Tab, CR and LF never get here:
	     the query replaces them with a space in every column (clean_select), in SQL,
	     because B1if re-writes an imported stylesheet and turns a character
	     reference such as "&amp;#9;" in an attribute into a plain space - so the old
	     "replace a tab" became "replace every SPACE" and a real line break went
	     through raw (10 Nov 2026: remarks arrived with a tab escape between all
	     their words, and one with a line break was refused as invalid JSON). -->
	<xsl:template name="esc">
		<xsl:param name="s"/>
		<xsl:call-template name="rep"><xsl:with-param name="s">
		<xsl:call-template name="rep"><xsl:with-param name="s" select="$s"/><xsl:with-param name="from" select="'\\'"/><xsl:with-param name="to" select="'\\\\'"/></xsl:call-template>
		</xsl:with-param><xsl:with-param name="from" select="'&quot;'"/><xsl:with-param name="to" select="'\\&quot;'"/></xsl:call-template>
	</xsl:template>

	<xsl:template name="rep">
		<xsl:param name="s"/>
		<xsl:param name="from"/>
		<xsl:param name="to"/>
		<xsl:choose>
			<xsl:when test="contains($s, $from)"><xsl:value-of select="substring-before($s, $from)"/><xsl:value-of select="$to"/><xsl:call-template name="rep"><xsl:with-param name="s" select="substring-after($s, $from)"/><xsl:with-param name="from" select="$from"/><xsl:with-param name="to" select="$to"/></xsl:call-template></xsl:when>
			<xsl:otherwise><xsl:value-of select="$s"/></xsl:otherwise>
		</xsl:choose>
	</xsl:template>
</xsl:stylesheet>
""" % dict(p, members=members)


ATOM0 = None   # B1if's own final atom, copied byte for byte from the export


def xform(name, desc, final=False):
	return ('<xform name="%s" nslist="%s"><description>%s</description><rule optional="false" XSLprofile="jrexml"><intended bfxp_href="#%s.xsl"></intended>'
		'<propertylist><property name="atom" bfxp_value="#%s"></property><property name="sessionid" bfxp_value="#!sessionid_"></property>'
		'<property name="userid" bfxp_value="#!userid_"></property><property name="vbiu" bfxp_value="#!vBIU_"></property>%s</propertylist></rule></xform>'
		% (name, escape(NS, {"'": "&apos;"}), escape(desc), name, name, '<property name="final" bfxp_value="true"></property>' if final else ""))


def bfd(p):
	callsql = ('<include name="atom2" nslist="%s"><description>SQL Call to Database</description><subflow optional="false">'
		'<intended bfxp_href="#/com.sap.b1i.vplatform.runtime/vCall/callsql.bfd"></intended><propertylist>'
		'<property name="bpc.maxDumpSize" bfxp_value="#!bpc.b1ifDumpSize_"></property><property name="atom" bfxp_value="#atom2"></property>'
		'<property name="sessionid" bfxp_value="#!sessionid_"></property><property name="userid" bfxp_value="#!userid_"></property>'
		'<property name="vbiu" bfxp_value="#!vBIU_"></property><property name="SysId" bfxp_value="#%s"></property>'
		'<property name="SQL" bfxp_value="/vpf:Msg/vpf:Body/vpf:Payload[@id=&apos;atom1&apos;]/Sql/Statement"></property>'
		'<property name="SQLH" bfxp_value="#"></property><property name="method" bfxp_value="#Automatic detection by key word"></property>'
		'<property name="mode" bfxp_value="#Single Processing"></property><property name="blockdeli" bfxp_value="#;"></property>'
		'<property name="throwexception" bfxp_value="#true"></property><property name="committype" bfxp_value="#2PC"></property>'
		'</propertylist></subflow></include>') % (escape(NS, {"'": "&apos;"}), p["sys"])
	# Copied from the export of Z.erpcust after the atom was added in the designer
	# (10 Nov 2026). throwexception true: a failed post must show as a failed message.
	callhttp = ('<include name="atom4" nslist="%s"><description>Call Function Using HTTP</description><subflow optional="false">'
		'<intended bfxp_href="#/com.sap.b1i.vplatform.runtime/vCall/callhttp.bfd"></intended><propertylist>'
		'<property name="atom" bfxp_value="#atom4"></property><property name="sessionid" bfxp_value="#!sessionid_"></property>'
		'<property name="userid" bfxp_value="#!userid_"></property><property name="vbiu" bfxp_value="#!vBIU_"></property>'
		'<property name="Reference" bfxp_value="#%s"></property><property name="Payload" bfxp_value="#atom5"></property>'
		'<property name="throwexception" bfxp_value="#true"></property></propertylist></subflow></include>') % (escape(NS, {"'": "&apos;"}), ERPNEXT_SYS)
	return ('<?xml version="1.0" encoding="UTF-8"?><bizflow2 xmlns:bfa="urn:com.sap.b1i.bizprocessor:bizatoms" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
		'xmlns="urn:com.sap.b1i.bizprocessor:bfdefinition" xsi:schemaLocation="urn:com.sap.b1i.bizprocessor:bfdefinition ../../com.sap.b1i.system/xsd/bizflow.xsd" '
		'active="true" name="vBIU.bfd" schemaversion="1.0"><interface><description>processing flow to convert message from Sender object to Receiver object</description>'
		'<inbound><propertylist><property name="bpc.maxDumpSize" importable="true" bfxp_value="#"></property><property name="bpc.b1ifDumpSize" importable="true" bfxp_value="#"></property>'
		'<property name="sessionid" importable="true" bfxp_value="#"></property><property name="userid" importable="true" bfxp_value="#"></property>'
		'<property name="username" importable="true" bfxp_value="#"></property><property name="vBIU" importable="false" bfxp_value="#%s"></property></propertylist></inbound>'
		'<outbound><propertylist></propertylist></outbound></interface><bizatoms>%s%s%s%s%s</bizatoms></bizflow2>') % (
		p["step"], xform("atom1", "Build the query"), callsql, xform("atom3", "Rows to the ERPNext JSON body"),
		xform("atom5", "Predecessor Transformation for httpcall Atom") + callhttp,
		xform("atom0", "Invoke XSLT file to convert import object to result object", final=True))


def vbiu(p):
	# Two inbound channels, each copied from a step B1if itself exported: the B1
	# event (Z.erpcust, 10 Nov 2026) and the timer (Z.erpstock after its Inbound
	# was switched in Step Design, 10 Nov 2026 - INB_AY_TIMR_ASYN_BIU, whose
	# <obj> is the step's own id).
	head = ('<?xml version="1.0" encoding="UTF-8"?><vBIU xmlns:bfa="urn:com.sap.b1i.bizprocessor:bizatoms" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
		'xmlns="urn:com.sap.b1i.vplatform:entity" xsi:schemaLocation="urn:com.sap.b1i.vplatform:entity ../../com.sap.b1i.vplatform.repository/xsd/vPlatform.xsd" '
		'Id="%s" version="1.0.0" proc="" SId="%s" internal="false" parallel="false" mlogexcl="false" b1isncompmode="false" b1autocommit="false" bi1fver="">') % (p["step"], p["pkg"])
	rest = ('<Formatting><ruledoc></ruledoc><skipempty>false</skipempty></Formatting><DataRetrieval delret="false" noret="true"><method>Retrieval</method>'
		'<adapter>DI API</adapter><type>Object</type><mode></mode><ruledoc></ruledoc></DataRetrieval>')
	tail = ('<Outbound><Channel Id="VOID"><type>Void</type><format>void</format></Channel><Successor Id="" Mode="" SkipIfFiltered="false"></Successor>'
		'<ErrResend>Resend from outbound phase</ErrResend></Outbound></vBIU>')
	if p["obj"]:
		channel = ('<Channel Id="INB_B1_EVNT_ASYN_EVT"><type>SAP Business One</type><mode>Asynchronous</mode><trigger>B1Event</trigger>'
			'<obj>%s</obj><ident>B1 Event</ident><idpar>n.a.</idpar><idns></idns></Channel>') % p["obj"]
		return head + "<Inbound>" + rest + channel + "</Inbound>" + tail
	# The schedule rides in the channel, where B1if's export of Z.mannaicpk (10 Nov
	# 2026) holds its own - <Scheduler min="*" hour="*" .../> after <idns> - so an
	# import does not leave a step waiting for somebody to set ten clocks again.
	# Setup's clock still shows it and can change it.
	minute, hour = p["cron"]
	channel = ('<Channel Id="INB_AY_TIMR_ASYN_BIU"><type>Void</type><mode>Asynchronous</mode><trigger>Timer</trigger>'
		'<obj>%s</obj><ident>Void</ident><idpar>n.a.</idpar><idns></idns>'
		'<Scheduler min="%s" hour="%s" day="*" month="*" dow="*" year="*"></Scheduler></Channel>') % (p["step"], minute, hour)
	return head + "<Inbound>" + channel + rest + "</Inbound>" + tail


def vpac(p):
	ts = datetime.datetime.now().strftime("%Y/%m/%d %H:%M:%S")
	return ('<?xml version="1.0" encoding="UTF-8"?><vPac xmlns:bfa="urn:com.sap.b1i.bizprocessor:bizatoms" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
		'xmlns="urn:com.sap.b1i.vplatform:entity" xsi:schemaLocation="urn:com.sap.b1i.vplatform:entity ../../com.sap.b1i.vplatform.repository/xsd/vPlatform.xsd" '
		'Id="%s" Vendor="" Version="1.0.0" Timestamp="%s" Authentication="" BizArea="ERPNext" xmlproc=""><desc>%s</desc>'
		'<vBIUList><vBIU Id="%s"></vBIU></vBIUList></vPac>') % (p["pkg"], ts, escape(p["desc"]), p["step"])


def main():
	src = zipfile.ZipFile(os.path.join(HERE, "..", "exports", "Z.mannaic-step1-2026-11-05.zip"))
	base = "com.sap.b1i.vplatform.scenarios.design/vBIU.Z.mannaicmtpo/"
	atom0, vvar = src.read(base + "atom0.xsl"), src.read(base + "vVar.xsl")
	atom5 = open(os.path.join(HERE, "atom5_http.xsl"), "rb").read()
	os.makedirs(OUT, exist_ok=True)
	for p in PACKAGES:
		d = os.path.join(OUT, p["pkg"])
		os.makedirs(d, exist_ok=True)
		files = {"atom1.xsl": sql_xsl(p).encode("utf-8"), "atom3.xsl": json_xsl(p).encode("utf-8")}
		for n, b in files.items():
			# B1if spoils a character reference in an imported stylesheet (see the esc template).
			assert b"&#" not in b, n
			open(os.path.join(d, n), "wb").write(b)
		step = "com.sap.b1i.vplatform.scenarios.design/vBIU.%s/" % p["step"]
		z = zipfile.ZipFile(os.path.join(OUT, p["pkg"] + ".zip"), "w", zipfile.ZIP_DEFLATED)
		z.writestr("b1ifident/b1ifident/b1ifident.xml", '<?xml version="1.0" encoding="UTF-8"?><b1ifident xmlns:bfa="urn:com.sap.b1i.bizprocessor:bizatoms"><id>%s</id><type>vPac</type><ver>1.0.0</ver></b1ifident>' % p["pkg"])
		z.writestr(step + "atom0.xsl", atom0)
		z.writestr(step + "atom1.xsl", files["atom1.xsl"])
		z.writestr(step + "atom3.xsl", files["atom3.xsl"])
		z.writestr(step + "atom5.xsl", atom5)
		z.writestr(step + "vBIU.bfd", bfd(p))
		z.writestr(step + "vBIU.xml", vbiu(p))
		z.writestr(step + "vVar.xsl", vvar)
		z.writestr("com.sap.b1i.vplatform.scenarios.design/vPac.%s/vPac.xml" % p["pkg"], vpac(p))
		z.close()
		print("built", p["pkg"] + ".zip", "step", p["step"], "sender", p["sys"], "event obj " + p["obj"] if p["obj"] else "TIMER")


if __name__ == "__main__":
	main()
