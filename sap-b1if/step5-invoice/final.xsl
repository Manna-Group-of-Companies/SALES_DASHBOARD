<?xml version="1.0" encoding="UTF-8"?>
<!--
  Step 5, atom "final": the request to ERPNext, or the reason there is none.

  Output: <Decision><Send>Y|N</Send><Reason/><Url/><Body/></Decision>.
  On Send = Y the HTTP atom POSTs Body (JSON) to Url, which is
  ERP_URL + /api/method/manna_sap_invoice_sync, with the SAP Sync Bot's
  "Authorization: token <key>:<secret>" header set in the HTTP atom or the
  SLD - never here, so no secret is in a file.

  Body: {"company": ERP_COMPANY, "invoices": [{doc_entry, doc_num, card_code,
  posting_date, due_date, total, paid, status, cancelled}, ...]}. ERPNext
  works out the customer, the balance and what to do with a cancelled
  invoice (app/server/sap_invoice_sync.py). Nothing is sent when the setting
  is off, when there are no invoices (a payment on account), or when the
  company or URL is not set.
-->
<xsl:stylesheet version="1.0"
	xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
	xmlns:vpf="urn:com.sap.b1i.vplatform:entity"
	xmlns:bfa="urn:com.sap.b1i.bizprocessor:bizatoms"
	bfa:force=""
	exclude-result-prefixes="vpf bfa">
	<xsl:output method="xml"/>
	<xsl:param name="atom"/>
	<!-- The Call SQL atom's id. Change it if the atoms were placed in another order. -->
	<xsl:param name="sqlAtom" select="'atom1'"/>

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

	<!-- A JSON string: backslash and double quote escaped. -->
	<xsl:template name="esc">
		<xsl:param name="s"/>
		<xsl:choose>
			<xsl:when test="contains($s, '\')">
				<xsl:call-template name="esc2"><xsl:with-param name="s" select="substring-before($s, '\')"/></xsl:call-template>
				<xsl:text>\\</xsl:text>
				<xsl:call-template name="esc"><xsl:with-param name="s" select="substring-after($s, '\')"/></xsl:call-template>
			</xsl:when>
			<xsl:otherwise><xsl:call-template name="esc2"><xsl:with-param name="s" select="$s"/></xsl:call-template></xsl:otherwise>
		</xsl:choose>
	</xsl:template>
	<xsl:template name="esc2">
		<xsl:param name="s"/>
		<xsl:choose>
			<xsl:when test="contains($s, '&quot;')">
				<xsl:value-of select="substring-before($s, '&quot;')"/>
				<xsl:text>\"</xsl:text>
				<xsl:call-template name="esc2"><xsl:with-param name="s" select="substring-after($s, '&quot;')"/></xsl:call-template>
			</xsl:when>
			<xsl:otherwise><xsl:value-of select="$s"/></xsl:otherwise>
		</xsl:choose>
	</xsl:template>

	<xsl:template name="str">
		<xsl:param name="v"/>
		<xsl:text>"</xsl:text><xsl:call-template name="esc"><xsl:with-param name="s" select="normalize-space($v)"/></xsl:call-template><xsl:text>"</xsl:text>
	</xsl:template>

	<!-- A JSON number; anything not a number becomes 0. -->
	<xsl:template name="num">
		<xsl:param name="v"/>
		<xsl:variable name="x" select="number(normalize-space($v))"/>
		<xsl:choose>
			<xsl:when test="string($x) = 'NaN'">0</xsl:when>
			<xsl:otherwise><xsl:value-of select="$x"/></xsl:otherwise>
		</xsl:choose>
	</xsl:template>

	<xsl:template name="transform">
		<xsl:variable name="rows" select="/vpf:Msg/vpf:Body/vpf:Payload[@id=$sqlAtom]//*[local-name()='Row']"/>
		<xsl:variable name="h" select="$rows[1]"/>
		<xsl:variable name="company" select="normalize-space($h/*[local-name()='Company'])"/>
		<xsl:variable name="base" select="normalize-space($h/*[local-name()='ErpUrl'])"/>
		<xsl:variable name="why">
			<xsl:choose>
				<xsl:when test="not($h)">skip: no A/R invoice for this event</xsl:when>
				<xsl:when test="normalize-space($h/*[local-name()='Enabled']) != 'Y'">skip: @MANNA_IC ERP_INVOICE_SYNC is not Y</xsl:when>
				<xsl:when test="$company = ''">ERP_COMPANY is not set in @MANNA_IC</xsl:when>
				<xsl:when test="$base = ''">ERP_URL is not set in @MANNA_IC</xsl:when>
			</xsl:choose>
		</xsl:variable>
		<Decision xmlns="">
			<Send><xsl:choose><xsl:when test="$why = ''">Y</xsl:when><xsl:otherwise>N</xsl:otherwise></xsl:choose></Send>
			<Reason>
				<xsl:choose>
					<xsl:when test="$why = ''">send <xsl:value-of select="count($rows)"/> invoice(s)</xsl:when>
					<xsl:otherwise><xsl:value-of select="$why"/></xsl:otherwise>
				</xsl:choose>
			</Reason>
			<Url>
				<xsl:if test="$why = ''">
					<xsl:choose>
						<xsl:when test="substring($base, string-length($base)) = '/'"><xsl:value-of select="substring($base, 1, string-length($base) - 1)"/></xsl:when>
						<xsl:otherwise><xsl:value-of select="$base"/></xsl:otherwise>
					</xsl:choose>
					<xsl:text>/api/method/manna_sap_invoice_sync</xsl:text>
				</xsl:if>
			</Url>
			<Body>
				<xsl:if test="$why = ''">
					<xsl:text>{"company":</xsl:text>
					<xsl:call-template name="str"><xsl:with-param name="v" select="$company"/></xsl:call-template>
					<xsl:text>,"invoices":[</xsl:text>
					<xsl:for-each select="$rows">
						<xsl:if test="position() &gt; 1">,</xsl:if>
						<xsl:text>{"doc_entry":</xsl:text><xsl:call-template name="num"><xsl:with-param name="v" select="*[local-name()='DocEntry']"/></xsl:call-template>
						<xsl:text>,"doc_num":</xsl:text><xsl:call-template name="num"><xsl:with-param name="v" select="*[local-name()='DocNum']"/></xsl:call-template>
						<xsl:text>,"card_code":</xsl:text><xsl:call-template name="str"><xsl:with-param name="v" select="*[local-name()='CardCode']"/></xsl:call-template>
						<xsl:text>,"posting_date":</xsl:text><xsl:call-template name="str"><xsl:with-param name="v" select="*[local-name()='PostingDate']"/></xsl:call-template>
						<xsl:text>,"due_date":</xsl:text><xsl:call-template name="str"><xsl:with-param name="v" select="*[local-name()='DueDate']"/></xsl:call-template>
						<xsl:text>,"total":</xsl:text><xsl:call-template name="num"><xsl:with-param name="v" select="*[local-name()='DocTotal']"/></xsl:call-template>
						<xsl:text>,"paid":</xsl:text><xsl:call-template name="num"><xsl:with-param name="v" select="*[local-name()='PaidToDate']"/></xsl:call-template>
						<xsl:text>,"status":</xsl:text><xsl:call-template name="str"><xsl:with-param name="v" select="*[local-name()='DocStatus']"/></xsl:call-template>
						<xsl:text>,"cancelled":</xsl:text><xsl:call-template name="str"><xsl:with-param name="v" select="*[local-name()='Cancelled']"/></xsl:call-template>
						<xsl:text>}</xsl:text>
					</xsl:for-each>
					<xsl:text>]}</xsl:text>
				</xsl:if>
			</Body>
		</Decision>
	</xsl:template>
</xsl:stylesheet>
