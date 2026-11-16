<?xml version="1.0" encoding="UTF-8"?>
<!--
  Step 6 (delivery dates), atom "sql-mt" (atom3): Manna Treads' side, compared
  IN SQL with what Hi-Tech promises. Run by atom4, Call SQL on Manna Treads'
  SysId.

  Hi-Tech's rows (atom2) go into the statement as a VALUES list - a B1if query
  runs on one company's connection and can name no other database, so the only
  way to compare the two companies in SQL is to carry one side over as text.
  Purchase order numbers go in only as numbers, dates only as ten characters of
  digits and dashes, item codes quoted with ' doubled; a row that is not all
  three is left out.

  For each purchase order named, and the sales order it was made for
  (U_MannaMtSo), both open and not cancelled:
    Want     on an OPEN line, Hi-Tech's date for that item ('' when Hi-Tech has
             no open line for it); '' on a closed line.
    HdrWant  the latest of Hi-Tech's dates for the order - the day it is complete.
  A pair "differs" when an open line's date is not its Want, or a document's
  own date (DocDueDate) is not HdrWant.

  ONE pair per run, in turn by the minute of the clock among the pairs that
  differ (as step 3 takes its pick lists), so a pair SAP refuses every time
  cannot hold up the ones behind it. EVERY line of both documents comes back,
  in the order SAP shows them (VisOrder), because the update hands SAP every
  line - see final.xsl.

  Always at least one row: with nothing that differs, Kind is empty and the
  row carries only the settings, which the decision's B1 Object atoms need for
  the read they do instead of an update.
-->
<xsl:stylesheet version="1.0"
	xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
	xmlns:vpf="urn:com.sap.b1i.vplatform:entity"
	xmlns:bfa="urn:com.sap.b1i.bizprocessor:bizatoms"
	bfa:force=""
	exclude-result-prefixes="vpf bfa">
	<xsl:output method="xml"/>
	<xsl:param name="atom"/>
	<!-- The Call SQL atom that read Hi-Tech. Change it if the atoms were placed in another order. -->
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

	<xsl:template name="settings">
	SELECT
		MAX(CASE WHEN Code = 'ENABLED'   THEN U_Value END) AS Enabled,
		MAX(CASE WHEN Code = 'DATE_SYNC' THEN U_Value END) AS DateSync,
		MAX(CASE WHEN Code = 'VENDOR'    THEN U_Value END) AS Vendor
	FROM [@MANNA_IC]
</xsl:template>

	<xsl:template name="transform">
		<xsl:variable name="rows" select="/vpf:Msg/vpf:Body/vpf:Payload[@id=$htAtom]//*[local-name()='Row'][
			string(number(normalize-space(*[local-name()='MtPo']))) != 'NaN'
			and number(normalize-space(*[local-name()='MtPo'])) = floor(number(normalize-space(*[local-name()='MtPo'])))
			and number(normalize-space(*[local-name()='MtPo'])) &gt;= 1
			and normalize-space(*[local-name()='ItemCode']) != ''
			and string-length(normalize-space(*[local-name()='ShipDate'])) = 10
			and translate(normalize-space(*[local-name()='ShipDate']), '0123456789-', '') = '']"/>
		<Sql xmlns="">
			<Count><xsl:value-of select="count($rows)"/></Count>
			<Statement>
				<xsl:choose>
					<xsl:when test="not($rows)">
SELECT '' AS Kind, S.Enabled, S.DateSync, S.Vendor
FROM (<xsl:call-template name="settings"/>) S
</xsl:when>
					<xsl:otherwise>
SELECT
	ISNULL(D.Kind, '') AS Kind, D.MtPo, D.DocEntry, D.DocNum, D.LineNum, D.VisOrder, D.ItemCode, D.LineStatus,
	D.ShipDate, D.Want, D.DueDate, D.HdrWant, ISNULL(D.Waiting, 0) AS Waiting,
	S.Enabled, S.DateSync, S.Vendor
FROM (<xsl:call-template name="settings"/>) S
LEFT JOIN (
	SELECT C.*, MAX(C.Rn) OVER () AS Waiting
	FROM (
		SELECT B.*, DENSE_RANK() OVER (ORDER BY B.MtPo) AS Rn
		FROM (
			SELECT A.*,
				MAX(CASE WHEN (A.Want &lt;&gt; '' AND A.Want &lt;&gt; A.ShipDate) OR (A.HdrWant IS NOT NULL AND A.HdrWant &lt;&gt; A.DueDate) THEN 1 ELSE 0 END) OVER (PARTITION BY A.MtPo) AS Differs
			FROM (
				SELECT T.Kind, T.MtPo, T.DocEntry, T.DocNum, T.LineNum, T.VisOrder, T.ItemCode, T.LineStatus,
					ISNULL(CONVERT(char(10), T.ShipDate, 23), '') AS ShipDate,
					CASE WHEN T.LineStatus = 'O' THEN ISNULL(W.ShipDate, '') ELSE '' END AS Want,
					ISNULL(CONVERT(char(10), T.DocDueDate, 23), '') AS DueDate,
					MAX(W.HdrWant) OVER (PARTITION BY T.MtPo) AS HdrWant
				FROM (
					SELECT 'PO' AS Kind, P.DocEntry AS MtPo, P.DocEntry, P.DocNum, P.DocDueDate,
						L.LineNum, L.VisOrder, UPPER(ISNULL(L.ItemCode, '')) AS ItemCode, L.LineStatus, L.ShipDate
					FROM OPOR P
					JOIN POR1 L ON L.DocEntry = P.DocEntry
					WHERE P.CANCELED = 'N' AND P.DocStatus = 'O' AND ISNULL(P.U_MannaMtSo, '') &lt;&gt; ''
						AND P.DocEntry IN (<xsl:for-each select="$rows"><xsl:if test="position() &gt; 1">, </xsl:if><xsl:value-of select="format-number(number(normalize-space(*[local-name()='MtPo'])), '0')"/></xsl:for-each>)
					UNION ALL
					SELECT 'SO', P.DocEntry, O.DocEntry, O.DocNum, O.DocDueDate,
						L.LineNum, L.VisOrder, UPPER(ISNULL(L.ItemCode, '')), L.LineStatus, L.ShipDate
					FROM OPOR P
					JOIN ORDR O ON CAST(O.DocEntry AS nvarchar(11)) = P.U_MannaMtSo
					JOIN RDR1 L ON L.DocEntry = O.DocEntry
					WHERE P.CANCELED = 'N' AND P.DocStatus = 'O' AND O.CANCELED = 'N' AND O.DocStatus = 'O'
						AND P.DocEntry IN (<xsl:for-each select="$rows"><xsl:if test="position() &gt; 1">, </xsl:if><xsl:value-of select="format-number(number(normalize-space(*[local-name()='MtPo'])), '0')"/></xsl:for-each>)
				) T
				LEFT JOIN (
					SELECT V.MtPo, V.ItemCode, MAX(V.ShipDate) AS ShipDate, MAX(MAX(V.ShipDate)) OVER (PARTITION BY V.MtPo) AS HdrWant
					FROM (VALUES <xsl:for-each select="$rows"><xsl:if test="position() &gt; 1">, </xsl:if>(<xsl:value-of select="format-number(number(normalize-space(*[local-name()='MtPo'])), '0')"/>, N'<xsl:call-template name="quote"><xsl:with-param name="s" select="normalize-space(*[local-name()='ItemCode'])"/></xsl:call-template>', '<xsl:value-of select="normalize-space(*[local-name()='ShipDate'])"/>')</xsl:for-each>
					) V(MtPo, ItemCode, ShipDate)
					GROUP BY V.MtPo, V.ItemCode
				) W ON W.MtPo = T.MtPo AND W.ItemCode = T.ItemCode
			) A
		) B
		WHERE B.Differs = 1
	) C
) D ON D.Rn = DATEDIFF(MINUTE, '20260101', GETDATE()) % D.Waiting + 1
ORDER BY D.Kind, D.VisOrder, D.LineNum
</xsl:otherwise>
				</xsl:choose>
			</Statement>
		</Sql>
	</xsl:template>
</xsl:stylesheet>
