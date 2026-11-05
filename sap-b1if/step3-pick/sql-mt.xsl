<?xml version="1.0" encoding="UTF-8"?>
<!--
  Step 3, atom "sql-mt" (atom5): Manna Treads' side - the purchase order
  Hi-Tech's sales order was made for (U_MannaMtPo) with its lines, the sales
  order that purchase order was made for (U_MannaMtSo) with its lines, the
  settings in Manna Treads' @MANNA_IC, and whether a goods receipt or delivery
  already carries this list's name. Run by atom6, Call SQL on Manna Treads'
  SysId. Every read in this step comes before its first insert, so nothing
  here waits on the step's own uncommitted writes (see step 2's sql-mt.xsl).

  One row per line, Kind 'PO' or 'SO'; the settings and counts repeat on
  every row. One row of settings only (Kind '') when there is no purchase
  order to read.
-->
<xsl:stylesheet version="1.0"
	xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
	xmlns:vpf="urn:com.sap.b1i.vplatform:entity"
	xmlns:bfa="urn:com.sap.b1i.bizprocessor:bizatoms"
	bfa:force=""
	exclude-result-prefixes="vpf bfa">
	<xsl:output method="xml"/>
	<xsl:param name="atom"/>
	<!-- The Call SQL atom that read the pick list. Change it if the atoms were placed in another order. -->
	<xsl:param name="htAtom" select="'atom2'"/>

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

	<xsl:template name="quote">
		<xsl:param name="s"/>
		<xsl:choose>
			<xsl:when test="contains($s, &quot;'&quot;)">
				<xsl:value-of select="concat(substring-before($s, &quot;'&quot;), &quot;''&quot;)"/>
				<xsl:call-template name="quote"><xsl:with-param name="s" select="substring-after($s, &quot;'&quot;)"/></xsl:call-template>
			</xsl:when>
			<xsl:otherwise><xsl:value-of select="$s"/></xsl:otherwise>
		</xsl:choose>
	</xsl:template>

	<xsl:template name="transform">
		<xsl:variable name="h" select="(/vpf:Msg/vpf:Body/vpf:Payload[@id=$htAtom]//*[local-name()='Row'])[1]"/>
		<xsl:variable name="po" select="number(normalize-space($h/*[local-name()='MtPo']))"/>
		<xsl:variable name="name">
			<xsl:call-template name="quote"><xsl:with-param name="s" select="normalize-space($h/*[local-name()='PickName'])"/></xsl:call-template>
		</xsl:variable>
		<Sql xmlns="">
			<Statement>
				<xsl:choose>
					<!-- No pick list this run (step 3 is timer-triggered), or Hi-Tech's
					     order names no purchase order: the settings alone, because the
					     decision's B1 Object atoms read Manna Treads' vendor by them. -->
					<xsl:when test="string($po) = 'NaN' or $po != floor($po) or $po &lt; 1">
SELECT '' AS Kind, S.*, 0 AS GrpoCount, 0 AS DnCount
FROM (
	SELECT
		MAX(CASE WHEN Code = 'ENABLED'     THEN U_Value END) AS Enabled,
		MAX(CASE WHEN Code = 'VENDOR'      THEN U_Value END) AS Vendor,
		MAX(CASE WHEN Code = 'PO_BRANCH'   THEN U_Value END) AS Branch,
		MAX(CASE WHEN Code = 'GRPO_SERIES' THEN U_Value END) AS GrpoSeries,
		MAX(CASE WHEN Code = 'DN_SERIES'   THEN U_Value END) AS DnSeries
	FROM [@MANNA_IC]
) S
</xsl:when>
					<xsl:otherwise>
SELECT D.*, S.*,
	(SELECT COUNT(*) FROM OPDN G WHERE G.NumAtCard = N'<xsl:value-of select="$name"/>' AND G.CANCELED = 'N' AND N'<xsl:value-of select="$name"/>' &lt;&gt; '') AS GrpoCount,
	(SELECT COUNT(*) FROM ODLN G WHERE G.NumAtCard = N'<xsl:value-of select="$name"/>' AND G.CANCELED = 'N' AND N'<xsl:value-of select="$name"/>' &lt;&gt; '') AS DnCount
FROM (
	SELECT 'PO' AS Kind, P.DocEntry, P.DocNum, P.CardCode, P.CANCELED AS Cancelled, ISNULL(P.U_MannaMtSo, '') AS MtSo,
		L.LineNum, ISNULL(L.ItemCode, '') AS ItemCode, L.LineStatus
	FROM OPOR P JOIN POR1 L ON L.DocEntry = P.DocEntry
	WHERE P.DocEntry = <xsl:value-of select="format-number($po, '0')"/>
	UNION ALL
	SELECT 'SO', O.DocEntry, O.DocNum, O.CardCode, O.CANCELED, '', L.LineNum, ISNULL(L.ItemCode, ''), L.LineStatus
	FROM ORDR O JOIN RDR1 L ON L.DocEntry = O.DocEntry
	WHERE CAST(O.DocEntry AS nvarchar(11)) = (SELECT ISNULL(U_MannaMtSo, '') FROM OPOR WHERE DocEntry = <xsl:value-of select="format-number($po, '0')"/>)
) D
CROSS JOIN (
	SELECT
		MAX(CASE WHEN Code = 'ENABLED'     THEN U_Value END) AS Enabled,
		MAX(CASE WHEN Code = 'VENDOR'      THEN U_Value END) AS Vendor,
		MAX(CASE WHEN Code = 'PO_BRANCH'   THEN U_Value END) AS Branch,
		MAX(CASE WHEN Code = 'GRPO_SERIES' THEN U_Value END) AS GrpoSeries,
		MAX(CASE WHEN Code = 'DN_SERIES'   THEN U_Value END) AS DnSeries
	FROM [@MANNA_IC]
) S
ORDER BY D.Kind, D.LineNum
</xsl:otherwise>
				</xsl:choose>
			</Statement>
		</Sql>
	</xsl:template>
</xsl:stylesheet>
