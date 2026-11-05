<?xml version="1.0" encoding="UTF-8"?>
<!--
  Step 3, atom "sql-ht" (atom1): which pick list this run works on, read from
  Hi-Tech with every line, the sales order line each one is on, and what the
  decision needs from Hi-Tech's side - its settings in @MANNA_IC and whether
  the item is batch-managed. Run by atom2, Call SQL on Hi-Tech's SysId.

  Stage 4 (5 Nov 2026): the order sync's PASS K makes these pick lists from
  ERPNext's, with Remarks "ERPNext PICK-00012 - order SAL-ORD-...". The step
  is TIMER-triggered, not by an event: SAP sends no B1 event when a pick list
  is added (TEST, 5 Nov 2026 - pick list 3 made at 14:48:33, no object 156
  event in any status). So each run looks for the work itself:

    waiting  a pick list not closed, whose Remarks carry an ERPNext name, and
             no live Hi-Tech invoice carries that name in NumAtCard yet. The
             invoice is the last thing that can be missing - B1if makes the
             three documents in one run, all or none.
    which    one per run, in turn by the minute of the clock, so a list that
             is refused every time (no batch stock, say) cannot hold up the
             lists behind it.

  One statement starting SELECT, no WITH: the Call SQL atom picks how to run
  a statement by its first keyword.

  Always at least one row: with nothing waiting, PickEntry is empty and the
  row carries only the settings, so the decision says "nothing waiting" and
  its B1 Object atoms read a business partner by key, which needs the key.
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
	ISNULL(CAST(P.AbsEntry AS nvarchar(11)), '') AS PickEntry, ISNULL(P.PickName, '') AS PickName, ISNULL(P.N, 0) AS Waiting,
	L.PickEntry AS PickLine, L.BaseObject, L.OrderEntry, L.OrderLine, L.RelQtty AS Kg,
	ISNULL(O.DocNum, 0) AS SoNum, ISNULL(O.CANCELED, '') AS SoCancelled, ISNULL(O.CardCode, '') AS SoCard,
	ISNULL(O.U_MannaMtPo, '') AS MtPo, ISNULL(O.NumAtCard, '') AS OrderName,
	ISNULL(R.ItemCode, '') AS ItemCode, ISNULL(R.LineStatus, '') AS SoLineStatus, ISNULL(R.WhsCode, '') AS WhsCode,
	ISNULL(I.ManBtchNum, 'N') AS Batch,
	S.Enabled, S.Customer, S.InvSeries,
	CONVERT(char(10), GETDATE(), 23) AS Today
FROM (
	SELECT
		MAX(CASE WHEN Code = 'ENABLED'    THEN U_Value END) AS Enabled,
		MAX(CASE WHEN Code = 'CUSTOMER'   THEN U_Value END) AS Customer,
		MAX(CASE WHEN Code = 'INV_SERIES' THEN U_Value END) AS InvSeries
	FROM [@MANNA_IC]
) S
LEFT JOIN (
	SELECT W.AbsEntry, W.PickName, W.N
	FROM (
		SELECT K.AbsEntry, X.PickName,
			ROW_NUMBER() OVER (ORDER BY K.AbsEntry) AS Rn, COUNT(*) OVER () AS N
		FROM OPKL K
		CROSS APPLY (
			SELECT CASE WHEN CAST(K.Remarks AS nvarchar(254)) LIKE 'ERPNext % - %'
				THEN SUBSTRING(CAST(K.Remarks AS nvarchar(254)), 9, CHARINDEX(' - ', CAST(K.Remarks AS nvarchar(254))) - 9)
				ELSE '' END AS PickName
		) X
		WHERE K.Status &lt;&gt; 'C' AND X.PickName &lt;&gt; ''
			AND NOT EXISTS (SELECT 1 FROM OINV V WHERE V.NumAtCard = X.PickName AND V.CANCELED = 'N')
	) W
	WHERE W.Rn = DATEDIFF(MINUTE, '20260101', GETDATE()) % W.N + 1
) P ON 1 = 1
LEFT JOIN PKL1 L ON L.AbsEntry = P.AbsEntry
LEFT JOIN ORDR O ON O.DocEntry = L.OrderEntry AND L.BaseObject = 17
LEFT JOIN RDR1 R ON R.DocEntry = L.OrderEntry AND R.LineNum = L.OrderLine AND L.BaseObject = 17
LEFT JOIN OITM I ON I.ItemCode = R.ItemCode
ORDER BY L.PickEntry
</Statement>
		</Sql>
	</xsl:template>
</xsl:stylesheet>
