<?xml version="1.0" encoding="UTF-8"?>
<!--
  Step 2, atom "sql-mt": the purchase order the event is about, read from
  Manna Treads with its lines, and the sales person of the Manna Treads sales
  order it was made for (Hi-Tech's order carries the rep, as the sync's
  PASS H does). Run by the next atom, Call SQL on Manna Treads' SysId.

  As step 1's sql.xsl: built here because B1if does not substitute into the
  SQL atom, and the DocEntry goes in only as a number.
-->
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
		<xsl:variable name="trigger" select="/vpf:Msg/vpf:Body/vpf:Payload[@Role='T']"/>
		<xsl:variable name="raw" select="string(($trigger//*[local-name()='key'][*[local-name()='name']='DocEntry']/*[local-name()='value'] | $trigger//*[local-name()='keys']//*[local-name()='value'])[1])"/>
		<xsl:variable name="entry" select="number(normalize-space($raw))"/>
		<Sql xmlns="">
			<DocEntry><xsl:value-of select="$raw"/></DocEntry>
			<Statement>
				<xsl:choose>
					<xsl:when test="string($entry) = 'NaN' or $entry != floor($entry) or $entry &lt; 1">SELECT TOP 0 1 AS DocEntry</xsl:when>
					<xsl:otherwise>
SELECT
	P.DocEntry, P.DocNum, P.CANCELED AS Cancelled, P.CardCode, P.DiscPrcnt AS HeaderDisc,
	ISNULL(P.NumAtCard, '') AS NumAtCard, ISNULL(P.U_MannaMtSo, '') AS MtSo,
	CONVERT(char(10), CASE WHEN P.DocDueDate &lt; CAST(GETDATE() AS date) THEN CAST(GETDATE() AS date) ELSE P.DocDueDate END, 23) AS DueDate,
	L.LineNum, ISNULL(L.ItemCode, '') AS ItemCode, L.Quantity, L.Price,
	ISNULL(SP.SlpName, '') AS SlpName, ISNULL(CAST(SO.DocNum AS nvarchar(20)), '') AS MtSoNum,
	(SELECT MAX(U_Value) FROM [@MANNA_IC] WHERE Code = 'VENDOR') AS Vendor
FROM OPOR P
JOIN POR1 L ON L.DocEntry = P.DocEntry
LEFT JOIN ORDR SO ON CAST(SO.DocEntry AS nvarchar(11)) = P.U_MannaMtSo
LEFT JOIN OSLP SP ON SP.SlpCode = SO.SlpCode AND SO.SlpCode &gt; 0
WHERE P.DocEntry = <xsl:value-of select="format-number($entry, '0')"/>
ORDER BY L.LineNum
</xsl:otherwise>
				</xsl:choose>
			</Statement>
		</Sql>
	</xsl:template>
</xsl:stylesheet>
