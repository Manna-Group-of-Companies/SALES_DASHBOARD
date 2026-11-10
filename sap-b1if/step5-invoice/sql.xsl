<?xml version="1.0" encoding="UTF-8"?>
<!--
  Step 5, atom "sql": the invoices to send to ERPNext for one B1 event.

    - A/R Invoice event (object 13, Add / Update / Cancel): that invoice;
    - Incoming Payment event (object 24, Add / Cancel): every A/R invoice the
      payment was applied to (RCT2, InvType 13), with SAP's PaidToDate as it
      stands after the payment.

  Built here and run by the next atom (Call SQL) for the same reason as
  step 1: B1if does not substitute values into the SQL atom's text. The key
  goes in only as a number. Settings come from @MANNA_IC:
  ERP_INVOICE_SYNC (Y to send), ERP_COMPANY (the company name ERPNext keys
  SAP Invoice rows by, "Manna Treads"), ERP_URL (the ERPNext site).
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
		<xsl:variable name="type" select="normalize-space(($trigger//*[local-name()='ObjectType'])[1])"/>
		<xsl:variable name="raw" select="string(($trigger//*[local-name()='key'][*[local-name()='name']='DocEntry']/*[local-name()='value'] | $trigger//*[local-name()='keys']//*[local-name()='value'])[1])"/>
		<xsl:variable name="entry" select="number(normalize-space($raw))"/>
		<xsl:variable name="n" select="format-number($entry, '0')"/>
		<Sql xmlns="">
			<ObjectType><xsl:value-of select="$type"/></ObjectType>
			<DocEntry><xsl:value-of select="$raw"/></DocEntry>
			<Statement>
				<xsl:choose>
					<xsl:when test="string($entry) = 'NaN' or $entry != floor($entry) or $entry &lt; 1 or ($type != '13' and $type != '24')">SELECT TOP 0 1 AS DocEntry</xsl:when>
					<xsl:otherwise>
SELECT
	I.DocEntry, I.DocNum, I.CardCode,
	CONVERT(char(10), I.DocDate, 23) AS PostingDate,
	CONVERT(char(10), I.DocDueDate, 23) AS DueDate,
	I.DocTotal, I.PaidToDate, I.DocStatus, I.CANCELED AS Cancelled,
	S.Enabled, S.Company, S.ErpUrl
FROM OINV I
CROSS JOIN (
	SELECT
		MAX(CASE WHEN Code = 'ERP_INVOICE_SYNC' THEN U_Value END) AS Enabled,
		MAX(CASE WHEN Code = 'ERP_COMPANY'      THEN U_Value END) AS Company,
		MAX(CASE WHEN Code = 'ERP_URL'          THEN U_Value END) AS ErpUrl
	FROM [@MANNA_IC]
) S
WHERE <xsl:choose>
	<xsl:when test="$type = '13'">I.DocEntry = <xsl:value-of select="$n"/></xsl:when>
	<xsl:otherwise>I.DocEntry IN (SELECT R.DocEntry FROM RCT2 R WHERE R.DocNum = <xsl:value-of select="$n"/> AND R.InvType = 13)</xsl:otherwise>
</xsl:choose>
ORDER BY I.DocEntry
</xsl:otherwise>
				</xsl:choose>
			</Statement>
		</Sql>
	</xsl:template>
</xsl:stylesheet>
