<?xml version="1.0" encoding="UTF-8"?>
<!--
  Step 2, atom "final": Hi-Tech's sales order to Manna Treads for one of
  Manna Treads' purchase orders, or the reason there is none.

  Output as step 1: <Decision><Make>Y|N</Make><Reason/><BOM/></Decision>;
  the condition atom calls the B1 Object atom (Hi-Tech's SysId) only on Y.

  Made from the purchase order as SAP holds it - items, kilos, net price -
  so the two companies cannot disagree about what was bought; the sync's
  PASS H does the same (New-HtSalesOrderBody). Only purchase orders step 1
  made are followed (U_MannaMtSo set): a purchase order somebody keyed by
  hand already has its hand-keyed Hi-Tech order, and following it would make
  a second one.
-->
<xsl:stylesheet version="1.0"
	xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
	xmlns:vpf="urn:com.sap.b1i.vplatform:entity"
	xmlns:bfa="urn:com.sap.b1i.bizprocessor:bizatoms"
	bfa:force=""
	exclude-result-prefixes="vpf bfa">
	<xsl:output method="xml"/>
	<xsl:param name="atom"/>
	<!-- The two Call SQL atoms. Change them if the atoms were placed in another order. -->
	<xsl:param name="mtAtom" select="'atom1'"/>
	<xsl:param name="htAtom" select="'atom3'"/>

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
		<xsl:variable name="po" select="/vpf:Msg/vpf:Body/vpf:Payload[@id=$mtAtom]//*[local-name()='Row']"/>
		<xsl:variable name="ht" select="/vpf:Msg/vpf:Body/vpf:Payload[@id=$htAtom]//*[local-name()='Row']"/>
		<xsl:variable name="h" select="$po[1]"/>
		<xsl:variable name="s" select="$ht[1]"/>
		<xsl:variable name="custState" select="normalize-space($s/*[local-name()='CustomerState'])"/>
		<xsl:variable name="tax">
			<xsl:choose>
				<xsl:when test="$custState = ''"/>
				<xsl:when test="translate($custState, 'abcdefghijklmnopqrstuvwxyz', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ') = translate(normalize-space($s/*[local-name()='HomeState']), 'abcdefghijklmnopqrstuvwxyz', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ')">
					<xsl:value-of select="normalize-space($s/*[local-name()='TaxInState'])"/>
				</xsl:when>
				<xsl:otherwise><xsl:value-of select="normalize-space($s/*[local-name()='TaxOutState'])"/></xsl:otherwise>
			</xsl:choose>
		</xsl:variable>
		<xsl:variable name="badItem" select="$ht[normalize-space(*[local-name()='SellItem']) != 'Y' or normalize-space(*[local-name()='InvntItem']) != 'Y' or normalize-space(*[local-name()='ItemFrozen']) = 'Y'][1]"/>

		<xsl:variable name="why">
			<xsl:choose>
				<xsl:when test="not($h)">skip: the purchase order was not found</xsl:when>
				<xsl:when test="normalize-space($h/*[local-name()='MtSo']) = ''">skip: not made by B1if from a sales order (U_MannaMtSo is empty)</xsl:when>
				<xsl:when test="normalize-space($h/*[local-name()='Cancelled']) != 'N'">skip: the purchase order is cancelled</xsl:when>
				<xsl:when test="normalize-space($h/*[local-name()='CardCode']) != normalize-space($h/*[local-name()='Vendor'])">skip: the purchase order is not to Hi-Tech (VENDOR)</xsl:when>
				<xsl:when test="not($s)">Hi-Tech's query returned nothing</xsl:when>
				<xsl:when test="normalize-space($s/*[local-name()='Enabled']) != 'Y'">skip: Hi-Tech's @MANNA_IC ENABLED is not Y</xsl:when>
				<xsl:when test="number($s/*[local-name()='SoCount']) &gt; 0">
					<xsl:value-of select="concat('skip: Hi-Tech order ', normalize-space($s/*[local-name()='SoDocNum']), ' already carries this purchase order')"/>
				</xsl:when>
				<xsl:when test="number(concat('0', normalize-space($h/*[local-name()='HeaderDisc']))) != 0">the purchase order has a header discount - its line prices are not what Manna Treads pays</xsl:when>
				<xsl:when test="normalize-space($s/*[local-name()='CustomerType']) != 'C'">
					<xsl:value-of select="concat('customer ', normalize-space($s/*[local-name()='Customer']), ' (CUSTOMER) is missing or not a customer in Hi-Tech')"/>
				</xsl:when>
				<xsl:when test="normalize-space($s/*[local-name()='CustomerFrozen']) = 'Y'">
					<xsl:value-of select="concat('customer ', normalize-space($s/*[local-name()='Customer']), ' is inactive in Hi-Tech')"/>
				</xsl:when>
				<xsl:when test="string($tax) = ''">
					<xsl:value-of select="concat('no tax code for the customer state &quot;', $custState, '&quot; (HOME_STATE / TAX_IN_STATE / TAX_OUT_STATE)')"/>
				</xsl:when>
				<xsl:when test="$badItem">
					<xsl:value-of select="concat(normalize-space($badItem/*[local-name()='ItemCode']), ' is not an active stock item Hi-Tech can sell')"/>
				</xsl:when>
				<xsl:when test="$po[not(number(*[local-name()='Quantity']) &gt; 0) or not(number(*[local-name()='Price']) &gt; 0)]">a purchase order line has no quantity or price</xsl:when>
			</xsl:choose>
		</xsl:variable>

		<Decision xmlns="">
			<PurchaseOrder><xsl:value-of select="normalize-space($h/*[local-name()='DocNum'])"/></PurchaseOrder>
			<xsl:choose>
				<xsl:when test="string($why) != ''">
					<Make>N</Make>
					<Reason><xsl:value-of select="$why"/></Reason>
				</xsl:when>
				<xsl:otherwise>
					<Make>Y</Make>
					<Reason/>
					<xsl:variable name="numAtCard" select="normalize-space($h/*[local-name()='NumAtCard'])"/>
					<BOM>
						<BO>
							<AdmInfo><Object>oOrders</Object></AdmInfo>
							<Documents>
								<row>
									<CardCode><xsl:value-of select="normalize-space($s/*[local-name()='Customer'])"/></CardCode>
									<DocDueDate><xsl:value-of select="translate(normalize-space($h/*[local-name()='DueDate']), '-', '')"/></DocDueDate>
									<!-- The ERPNext name when the purchase order has one: the sync's
									     PASS H finds Hi-Tech's order by it, and PASS B follows it. -->
									<NumAtCard>
										<xsl:choose>
											<xsl:when test="$numAtCard != ''"><xsl:value-of select="$numAtCard"/></xsl:when>
											<xsl:otherwise><xsl:value-of select="concat('MT PO ', normalize-space($h/*[local-name()='DocNum']))"/></xsl:otherwise>
										</xsl:choose>
									</NumAtCard>
									<Comments><xsl:value-of select="concat('Manna Treads PO ', normalize-space($h/*[local-name()='DocNum']), ' - made by B1if')"/></Comments>
									<DiscPrcnt>0</DiscPrcnt>
									<xsl:if test="normalize-space($s/*[local-name()='SoSeries']) != ''"><Series><xsl:value-of select="normalize-space($s/*[local-name()='SoSeries'])"/></Series></xsl:if>
									<xsl:if test="number($s/*[local-name()='SlpCode']) &gt; 0"><SlpCode><xsl:value-of select="normalize-space($s/*[local-name()='SlpCode'])"/></SlpCode></xsl:if>
									<U_MannaMtPo><xsl:value-of select="normalize-space($h/*[local-name()='DocEntry'])"/></U_MannaMtPo>
									<!-- The number people see on Manna Treads' sales order, so Hi-Tech's
									     orders can be searched by it. U_MannaMtPo is the machine's link. -->
									<U_MannaMtSoNo><xsl:value-of select="normalize-space($h/*[local-name()='MtSoNum'])"/></U_MannaMtSoNo>
								</row>
							</Documents>
							<Document_Lines>
								<xsl:for-each select="$po">
									<row>
										<ItemCode><xsl:value-of select="normalize-space(*[local-name()='ItemCode'])"/></ItemCode>
										<Quantity><xsl:value-of select="format-number(number(*[local-name()='Quantity']), '0.######')"/></Quantity>
										<Price><xsl:value-of select="format-number(number(*[local-name()='Price']), '0.######')"/></Price>
										<DiscPrcnt>0</DiscPrcnt>
										<TaxCode><xsl:value-of select="$tax"/></TaxCode>
										<xsl:if test="normalize-space($s/*[local-name()='SoWhs']) != ''"><WhsCode><xsl:value-of select="normalize-space($s/*[local-name()='SoWhs'])"/></WhsCode></xsl:if>
									</row>
								</xsl:for-each>
							</Document_Lines>
						</BO>
					</BOM>
				</xsl:otherwise>
			</xsl:choose>
		</Decision>
	</xsl:template>
</xsl:stylesheet>
