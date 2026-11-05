<?xml version="1.0" encoding="UTF-8"?>
<!--
  Step 1, atom "sql": the one query the purchase order is decided from, run
  against Manna Treads by the next atom (Call SQL, statement
  /vpf:Msg/vpf:Body/vpf:Payload[@id='<this atom>']/Sql/Statement).

  The statement is built here rather than written in the SQL atom with a
  placeholder, because B1if does not substitute a value into the SQL atom's
  own text - its documented workaround is an xform that writes the statement.
  The DocEntry is from the event and is put in only as a number, so nothing
  in the event can become SQL.

  One row per sales order line. Everything else the decision needs is a
  column repeated on every row: the order's header, the settings in
  @MANNA_IC, the supplier, and whether a purchase order already carries this
  sales order's DocEntry - which is what makes a second event for the same
  order harmless.
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
		<!-- The B1 event's key, matched by local name so the event's namespace
		     prefix cannot break it. -->
		<xsl:variable name="trigger" select="/vpf:Msg/vpf:Body/vpf:Payload[@Role='T']"/>
		<xsl:variable name="raw" select="string(($trigger//*[local-name()='key'][*[local-name()='name']='DocEntry']/*[local-name()='value'] | $trigger//*[local-name()='keys']//*[local-name()='value'])[1])"/>
		<xsl:variable name="entry" select="number(normalize-space($raw))"/>
		<Sql xmlns="">
			<DocEntry><xsl:value-of select="$raw"/></DocEntry>
			<Statement>
				<xsl:choose>
					<!-- Not a whole number: a query that returns nothing, so the
					     final atom says so and makes nothing. -->
					<xsl:when test="string($entry) = 'NaN' or $entry != floor($entry) or $entry &lt; 1">SELECT TOP 0 1 AS DocEntry</xsl:when>
					<xsl:otherwise>
SELECT
	T0.DocEntry, T0.DocNum, T0.CANCELED AS Cancelled, T0.DocStatus, T0.DiscPrcnt AS HeaderDisc,
	CONVERT(char(10), T0.DocDate, 23) AS DocDate,
	CONVERT(char(10), CASE WHEN T0.DocDueDate &lt; CAST(GETDATE() AS date) THEN CAST(GETDATE() AS date) ELSE T0.DocDueDate END, 23) AS DueDate,
	ISNULL(T0.NumAtCard, '') AS NumAtCard, LEFT(ISNULL(CAST(T0.Comments AS nvarchar(254)), ''), 254) AS Remarks,
	T1.LineNum, ISNULL(T1.ItemCode, '') AS ItemCode, T1.Quantity, T1.PriceAfVAT, T1.VatPrcnt, T1.DiscPrcnt AS LineDisc,
	ISNULL(I.InvntItem, '') AS InvntItem, ISNULL(I.PrchseItem, '') AS PrchseItem, ISNULL(I.frozenFor, '') AS ItemFrozen,
	S.Enabled, S.StartDate, S.Margin, S.Vendor, S.PoSeries, S.PoBranch, S.PoWhs, S.PoLocation,
	S.HomeState, S.TaxInState, S.TaxOutState, S.ErpPrefix,
	ISNULL(V.CardType, '') AS VendorType, ISNULL(V.frozenFor, '') AS VendorFrozen, ISNULL(V.State1, '') AS VendorState,
	(SELECT COUNT(*) FROM OPOR P WHERE P.U_MannaMtSo = CAST(T0.DocEntry AS nvarchar(11)) AND P.CANCELED = 'N') AS PoCount,
	(SELECT MIN(P.DocNum) FROM OPOR P WHERE P.U_MannaMtSo = CAST(T0.DocEntry AS nvarchar(11)) AND P.CANCELED = 'N') AS PoDocNum
FROM ORDR T0
JOIN RDR1 T1 ON T1.DocEntry = T0.DocEntry
LEFT JOIN OITM I ON I.ItemCode = T1.ItemCode
CROSS JOIN (
	SELECT
		MAX(CASE WHEN Code = 'ENABLED'       THEN U_Value END) AS Enabled,
		MAX(CASE WHEN Code = 'START_DATE'    THEN U_Value END) AS StartDate,
		MAX(CASE WHEN Code = 'MARGIN'        THEN U_Value END) AS Margin,
		MAX(CASE WHEN Code = 'VENDOR'        THEN U_Value END) AS Vendor,
		MAX(CASE WHEN Code = 'PO_SERIES'     THEN U_Value END) AS PoSeries,
		MAX(CASE WHEN Code = 'PO_BRANCH'     THEN U_Value END) AS PoBranch,
		MAX(CASE WHEN Code = 'PO_WHS'        THEN U_Value END) AS PoWhs,
		MAX(CASE WHEN Code = 'PO_LOCATION'   THEN U_Value END) AS PoLocation,
		MAX(CASE WHEN Code = 'HOME_STATE'    THEN U_Value END) AS HomeState,
		MAX(CASE WHEN Code = 'TAX_IN_STATE'  THEN U_Value END) AS TaxInState,
		MAX(CASE WHEN Code = 'TAX_OUT_STATE' THEN U_Value END) AS TaxOutState,
		MAX(CASE WHEN Code = 'ERP_PREFIX'    THEN U_Value END) AS ErpPrefix
	FROM [@MANNA_IC]
) S
LEFT JOIN OCRD V ON V.CardCode = S.Vendor
WHERE T0.DocEntry = <xsl:value-of select="format-number($entry, '0')"/>
ORDER BY T1.LineNum
</xsl:otherwise>
				</xsl:choose>
			</Statement>
		</Sql>
	</xsl:template>
</xsl:stylesheet>
