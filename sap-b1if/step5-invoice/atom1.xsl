<!-- Z.erpinv: atom1, the statement Call SQL (atom2) runs on Manna Treads.
     Same shape as Z.erpcust's atom1. The step's object (13 A/R invoice, 24
     incoming payment) is fixed by build_package.py into $objType, so the
     statement does not depend on what the event says it is.
     13: that invoice. 24: every invoice the payment touches (RCT2, InvType 13),
     read after the payment, so PaidToDate already includes it. The key is
     numeric and checked as such, so nothing in it can become SQL. -->
<xsl:stylesheet version="1.0"
	xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
	xmlns:vpf="urn:com.sap.b1i.vplatform:entity"
	xmlns:bfa="urn:com.sap.b1i.bizprocessor:bizatoms"
	bfa:force=""
	exclude-result-prefixes="vpf bfa">
	<xsl:output method="xml"/>
	<xsl:param name="atom"/>
	<xsl:variable name="objType" select="'@OBJTYPE@'"/>

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
		<xsl:variable name="trigger" select="/vpf:Msg/vpf:Body/vpf:Payload[@Role='T']"/>
		<xsl:variable name="raw" select="normalize-space(string(($trigger//*[local-name()='keys']//*[local-name()='value'] | $trigger//*[local-name()='key']/*[local-name()='value'])[1]))"/>
		<xsl:variable name="entry" select="number($raw)"/>
		<xsl:variable name="n" select="format-number($entry, '0')"/>
		<Sql xmlns="">
			<Key><xsl:value-of select="$raw"/></Key>
			<Statement>
				<xsl:choose>
					<xsl:when test="string($entry) = 'NaN' or $entry != floor($entry) or $entry &lt; 1">SELECT TOP 0 1 AS doc_entry</xsl:when>
					<xsl:otherwise>SELECT
	I.DocEntry AS doc_entry, I.DocNum AS doc_num, I.CardCode AS card_code,
	CONVERT(char(10), I.DocDate, 23) AS posting_date,
	CONVERT(char(10), I.DocDueDate, 23) AS due_date,
	I.DocTotal AS total, I.PaidToDate AS paid, I.DocStatus AS status, I.CANCELED AS cancelled,
	ISNULL(S.Enabled, 'N') AS enabled, ISNULL(S.Company, '') AS company
FROM OINV I
CROSS JOIN (
	SELECT
		MAX(CASE WHEN Code = 'ERP_INVOICE_SYNC' THEN U_Value END) AS Enabled,
		MAX(CASE WHEN Code = 'ERP_COMPANY'      THEN U_Value END) AS Company
	FROM [@MANNA_IC]
) S
WHERE <xsl:choose>
	<xsl:when test="$objType = '24'">I.DocEntry IN (SELECT R.DocEntry FROM RCT2 R WHERE R.DocNum = <xsl:value-of select="$n"/> AND R.InvType = 13)</xsl:when>
	<xsl:otherwise>I.DocEntry = <xsl:value-of select="$n"/></xsl:otherwise>
</xsl:choose>
ORDER BY I.DocEntry</xsl:otherwise>
				</xsl:choose>
			</Statement>
		</Sql>
	</xsl:template>
</xsl:stylesheet>
