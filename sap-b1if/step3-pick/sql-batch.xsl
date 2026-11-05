<?xml version="1.0" encoding="UTF-8"?>
<!--
  Step 3, atom "sql-batch" (atom3): the batches Hi-Tech's invoice can sell
  from, oldest first, for each batch-managed item on the pick list in the
  warehouse its sales order line ships from. Run by atom4, Call SQL on
  Hi-Tech's SysId. 85 of Hi-Tech's 145 finished goods are batch-managed
  (Manna Treads' are not), and the user chose oldest-first on 5 Nov 2026.

  Available is on hand less committed to batch allocations. Nothing when no
  item on the list is batch-managed. Item and warehouse codes come out of
  Hi-Tech's own SAP, and are quoted (doubling ') rather than trusted.
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
		<xsl:variable name="rows" select="/vpf:Msg/vpf:Body/vpf:Payload[@id=$htAtom]//*[local-name()='Row'][normalize-space(*[local-name()='Batch']) = 'Y' and normalize-space(*[local-name()='ItemCode']) != '']"/>
		<Sql xmlns="">
			<Statement>
				<xsl:choose>
					<xsl:when test="not($rows)">SELECT TOP 0 '' AS ItemCode</xsl:when>
					<xsl:otherwise>
SELECT Q.ItemCode, Q.WhsCode, N.DistNumber AS BatchNum, Q.Quantity - ISNULL(Q.CommitQty, 0) AS Avail
FROM OBTQ Q
JOIN OBTN N ON N.AbsEntry = Q.MdAbsEntry AND N.ItemCode = Q.ItemCode
WHERE Q.Quantity - ISNULL(Q.CommitQty, 0) &gt; 0 AND (<xsl:for-each select="$rows"><xsl:if test="position() &gt; 1"> OR </xsl:if>(Q.ItemCode = N'<xsl:call-template name="quote"><xsl:with-param name="s" select="normalize-space(*[local-name()='ItemCode'])"/></xsl:call-template>' AND Q.WhsCode = N'<xsl:call-template name="quote"><xsl:with-param name="s" select="normalize-space(*[local-name()='WhsCode'])"/></xsl:call-template>')</xsl:for-each>)
ORDER BY Q.ItemCode, Q.WhsCode, N.InDate, N.AbsEntry
</xsl:otherwise>
				</xsl:choose>
			</Statement>
		</Sql>
	</xsl:template>
</xsl:stylesheet>
