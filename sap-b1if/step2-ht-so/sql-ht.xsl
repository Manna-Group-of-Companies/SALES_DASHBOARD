<?xml version="1.0" encoding="UTF-8"?>
<!--
  Step 2, atom "sql-ht": what Hi-Tech's side of the decision needs, run by
  the next atom, Call SQL on Hi-Tech's SysId - its settings in its own
  @MANNA_IC, the customer Manna Treads is there, each item on the purchase
  order, the sales person by name, and whether an order already carries this
  purchase order's DocEntry (U_MannaMtPo), which makes a second event for it
  harmless.

  The item codes and the rep's name come out of Manna Treads' SAP, so they
  are quoted here (doubling ') rather than trusted to be clean. One row per
  item; nothing when the purchase order was not found.
-->
<xsl:stylesheet version="1.0"
	xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
	xmlns:vpf="urn:com.sap.b1i.vplatform:entity"
	xmlns:bfa="urn:com.sap.b1i.bizprocessor:bizatoms"
	bfa:force=""
	exclude-result-prefixes="vpf bfa">
	<xsl:output method="xml"/>
	<xsl:param name="atom"/>
	<!-- The Call SQL atom that read Manna Treads. Change it if the atoms were placed in another order. -->
	<xsl:param name="mtAtom" select="'atom1'"/>

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
		<xsl:variable name="rows" select="/vpf:Msg/vpf:Body/vpf:Payload[@id=$mtAtom]//*[local-name()='Row']"/>
		<xsl:variable name="h" select="$rows[1]"/>
		<Sql xmlns="">
			<Statement>
				<xsl:choose>
					<xsl:when test="not($h) or normalize-space($h/*[local-name()='DocEntry']) = ''">SELECT TOP 0 1 AS ItemCode</xsl:when>
					<xsl:otherwise>
SELECT
	X.ItemCode,
	ISNULL(I.SellItem, '') AS SellItem, ISNULL(I.InvntItem, '') AS InvntItem, ISNULL(I.frozenFor, '') AS ItemFrozen,
	S.Enabled, S.Customer, S.SoSeries, S.SoWhs, S.HomeState, S.TaxInState, S.TaxOutState,
	ISNULL(C.CardType, '') AS CustomerType, ISNULL(C.frozenFor, '') AS CustomerFrozen, ISNULL(C.State1, '') AS CustomerState,
	(SELECT COUNT(*) FROM ORDR O WHERE O.U_MannaMtPo = N'<xsl:value-of select="normalize-space($h/*[local-name()='DocEntry'])"/>' AND O.CANCELED = 'N') AS SoCount,
	(SELECT MIN(O.DocNum) FROM ORDR O WHERE O.U_MannaMtPo = N'<xsl:value-of select="normalize-space($h/*[local-name()='DocEntry'])"/>' AND O.CANCELED = 'N') AS SoDocNum,
	(SELECT MIN(SlpCode) FROM OSLP WHERE SlpName = N'<xsl:call-template name="quote"><xsl:with-param name="s" select="normalize-space($h/*[local-name()='SlpName'])"/></xsl:call-template>' AND SlpName &lt;&gt; '') AS SlpCode
FROM (VALUES <xsl:for-each select="$rows"><xsl:if test="position() &gt; 1">, </xsl:if>(N'<xsl:call-template name="quote"><xsl:with-param name="s" select="normalize-space(*[local-name()='ItemCode'])"/></xsl:call-template>')</xsl:for-each>) X(ItemCode)
CROSS JOIN (
	SELECT
		MAX(CASE WHEN Code = 'ENABLED'       THEN U_Value END) AS Enabled,
		MAX(CASE WHEN Code = 'CUSTOMER'      THEN U_Value END) AS Customer,
		MAX(CASE WHEN Code = 'SO_SERIES'     THEN U_Value END) AS SoSeries,
		MAX(CASE WHEN Code = 'SO_WHS'        THEN U_Value END) AS SoWhs,
		MAX(CASE WHEN Code = 'HOME_STATE'    THEN U_Value END) AS HomeState,
		MAX(CASE WHEN Code = 'TAX_IN_STATE'  THEN U_Value END) AS TaxInState,
		MAX(CASE WHEN Code = 'TAX_OUT_STATE' THEN U_Value END) AS TaxOutState
	FROM [@MANNA_IC]
) S
LEFT JOIN OCRD C ON C.CardCode = S.Customer
LEFT JOIN OITM I ON I.ItemCode = X.ItemCode
</xsl:otherwise>
				</xsl:choose>
			</Statement>
		</Sql>
	</xsl:template>
</xsl:stylesheet>
