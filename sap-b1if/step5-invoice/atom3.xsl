<?xml version="1.0" encoding="UTF-8"?>
<!-- Z.erpinv: atom3, the invoices Call SQL (atom2) read, as the JSON body
     ERPNext's manna_sap_invoice_sync takes. Same shape as Z.erpcust's atom3:
     the HTTP call added after this atom posts
     /vpf:Msg/vpf:Body/vpf:Payload[@id='atom3']/Http/Body to Http/Endpoint
     with Content-Type application/json.
     Off unless @MANNA_IC ERP_INVOICE_SYNC = Y: then the list is sent empty,
     which ERPNext answers with nothing changed. -->
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

	<xsl:template name="transform">
		<xsl:variable name="all" select="/vpf:Msg/vpf:Body/vpf:Payload[@id='atom2']//*[local-name()='Row']"/>
		<xsl:variable name="on" select="normalize-space($all[1]/*[local-name()='enabled']) = 'Y'"/>
		<xsl:variable name="company">
			<xsl:choose>
				<xsl:when test="normalize-space($all[1]/*[local-name()='company']) != ''"><xsl:value-of select="normalize-space($all[1]/*[local-name()='company'])"/></xsl:when>
				<xsl:otherwise>Manna Treads</xsl:otherwise>
			</xsl:choose>
		</xsl:variable>
		<xsl:variable name="rows" select="$all[$on]"/>
		<Http xmlns="">
			<Endpoint>/api/method/manna_sap_invoice_sync</Endpoint>
			<ContentType>application/json</ContentType>
			<Enabled><xsl:value-of select="normalize-space($all[1]/*[local-name()='enabled'])"/></Enabled>
			<Count><xsl:value-of select="count($rows)"/></Count>
			<Body>
				<xsl:text>{"company":"</xsl:text><xsl:call-template name="esc"><xsl:with-param name="s" select="string($company)"/></xsl:call-template><xsl:text>","invoices":[</xsl:text>
				<xsl:for-each select="$rows">
					<xsl:if test="position() &gt; 1"><xsl:text>,</xsl:text></xsl:if>
					<xsl:text>{"doc_entry":</xsl:text><xsl:call-template name="num"><xsl:with-param name="v" select="*[local-name()='doc_entry']"/></xsl:call-template>
					<xsl:text>,"doc_num":</xsl:text><xsl:call-template name="num"><xsl:with-param name="v" select="*[local-name()='doc_num']"/></xsl:call-template>
					<xsl:text>,"card_code":"</xsl:text><xsl:call-template name="esc"><xsl:with-param name="s" select="normalize-space(*[local-name()='card_code'])"/></xsl:call-template><xsl:text>"</xsl:text>
					<xsl:text>,"posting_date":"</xsl:text><xsl:value-of select="normalize-space(*[local-name()='posting_date'])"/><xsl:text>"</xsl:text>
					<xsl:text>,"due_date":"</xsl:text><xsl:value-of select="normalize-space(*[local-name()='due_date'])"/><xsl:text>"</xsl:text>
					<xsl:text>,"total":</xsl:text><xsl:call-template name="num"><xsl:with-param name="v" select="*[local-name()='total']"/></xsl:call-template>
					<xsl:text>,"paid":</xsl:text><xsl:call-template name="num"><xsl:with-param name="v" select="*[local-name()='paid']"/></xsl:call-template>
					<xsl:text>,"status":"</xsl:text><xsl:value-of select="normalize-space(*[local-name()='status'])"/><xsl:text>"</xsl:text>
					<xsl:text>,"cancelled":"</xsl:text><xsl:value-of select="normalize-space(*[local-name()='cancelled'])"/><xsl:text>"}</xsl:text>
				</xsl:for-each>
				<xsl:text>]}</xsl:text>
			</Body>
		</Http>
	</xsl:template>

	<!-- A number for JSON: SQL's decimals as they are, 0 when empty or not a number. -->
	<xsl:template name="num">
		<xsl:param name="v"/>
		<xsl:variable name="t" select="normalize-space($v)"/>
		<xsl:choose>
			<xsl:when test="$t = '' or string(number($t)) = 'NaN'">0</xsl:when>
			<xsl:otherwise><xsl:value-of select="number($t)"/></xsl:otherwise>
		</xsl:choose>
	</xsl:template>

	<!-- A JSON string: backslash and quote escaped. Codes and company names only. -->
	<xsl:template name="esc">
		<xsl:param name="s"/>
		<xsl:call-template name="rep"><xsl:with-param name="s">
		<xsl:call-template name="rep"><xsl:with-param name="s" select="$s"/><xsl:with-param name="from" select="'\'"/><xsl:with-param name="to" select="'\\'"/></xsl:call-template>
		</xsl:with-param><xsl:with-param name="from" select="'&quot;'"/><xsl:with-param name="to" select="'\&quot;'"/></xsl:call-template>
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
