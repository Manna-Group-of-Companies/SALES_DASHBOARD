<?xml version="1.0" encoding="UTF-8"?>
<!--
  Step 6 (delivery dates), atom "sql-ht" (atom1): what Hi-Tech now promises,
  per item, on every open sales order of the flow that was touched lately.
  Run by atom2, Call SQL on Hi-Tech's SysId.

  13 Nov 2026, the user's decision: the rep picks a delivery date with the
  order; production moves it in HI-TECH's sales order when the plan changes -
  for the whole order (SAP then offers to update the rows: answer Yes) or on
  single rows. Manna Treads' purchase order and sales order must follow, and
  ERPNext too (that half rides on the status package, Z.erpstatht).

  The row's own Delivery Date (RDR1.ShipDate) is the truth, not the header's:
  it is what SAP plans by, and it is the only place a single item's date can
  be. One row per order and item, the LATEST date among that item's open
  lines - a line split to send part later is complete on the later day.

  Only orders B1if made (U_MannaMtPo names Manna Treads' purchase order), open,
  not cancelled, and changed in the last 7 days (ORDR.UpdateDate - any change
  to the order moves it, and a new order counts as changed). Seven days so a
  weekend with B1if stopped loses nothing; not every open order, because the
  whole list goes into the next statement as text, every minute.

  TIMER-triggered, like step 3: the step compares instead of waiting for an
  event, so a change made while B1if was busy or stopped is still found, and a
  date that already agrees costs two reads and writes nothing.

  Always at least one row: with nothing to compare, MtPo is empty and the row
  carries only Hi-Tech's ENABLED.
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
		<Sql xmlns="">
			<Statement>
SELECT
	ISNULL(X.MtPo, '') AS MtPo, ISNULL(X.SoNum, 0) AS SoNum, ISNULL(X.ItemCode, '') AS ItemCode, ISNULL(X.ShipDate, '') AS ShipDate,
	ISNULL(S.Enabled, '') AS Enabled
FROM (
	SELECT MAX(CASE WHEN Code = 'ENABLED' THEN U_Value END) AS Enabled
	FROM [@MANNA_IC]
) S
LEFT JOIN (
	SELECT H.U_MannaMtPo AS MtPo, H.DocNum AS SoNum, UPPER(L.ItemCode) AS ItemCode, CONVERT(char(10), MAX(L.ShipDate), 23) AS ShipDate
	FROM ORDR H
	JOIN RDR1 L ON L.DocEntry = H.DocEntry
	WHERE H.CANCELED = 'N' AND H.DocStatus = 'O' AND L.LineStatus = 'O'
		AND ISNULL(L.ItemCode, '') &lt;&gt; '' AND L.ShipDate IS NOT NULL
		AND ISNULL(H.U_MannaMtPo, '') &lt;&gt; '' AND H.U_MannaMtPo NOT LIKE '%[^0-9]%'
		AND H.UpdateDate &gt;= DATEADD(day, -7, CAST(GETDATE() AS date))
	GROUP BY H.DocEntry, H.DocNum, H.U_MannaMtPo, UPPER(L.ItemCode)
) X ON S.Enabled = 'Y'
ORDER BY X.MtPo, X.ItemCode
</Statement>
		</Sql>
	</xsl:template>
</xsl:stylesheet>
