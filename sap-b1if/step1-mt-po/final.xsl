<?xml version="1.0" encoding="UTF-8"?>
<!--
  Step 1, atom "final": Manna Treads' purchase order to Hi-Tech for one
  Manna Treads sales order, or the reason there is none.

  Output: <Decision><Make>Y|N</Make><Reason/><BOM/></Decision>. The condition
  atom after this calls the B1 Object atom only on Make = Y; on N the reason
  stays in the message log and nothing is written to SAP.

  The rules are the sync's PASS P (Sync-SapOrders.ps1, Get-MfPurchasePlan),
  so a purchase order looks the same whichever of the two made it:
    - same items and kilos as the sales order - Manna Treads holds no stock,
      so it buys exactly what it sold;
    - price = the sales order's rate incl. GST, less MARGIN rupees per kilo,
      then GST taken back off; rounded 2 places gross and 6 net, as the sync;
    - tax by the supplier's state against HOME_STATE, never copied from the
      sales order: a Karnataka customer is IGST, but the supplier is in Kerala;
    - nothing names the end customer. Hi-Tech's sales order is made from this
      purchase order, and the factory has no business knowing who bought.
  Refusing is the safe direction here: a purchase order at the wrong price is
  an invoice between the two companies somebody has to unpick, while a missing
  one is a line on the alert query (alert.sql) and a few minutes' typing.
-->
<xsl:stylesheet version="1.0"
	xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
	xmlns:vpf="urn:com.sap.b1i.vplatform:entity"
	xmlns:bfa="urn:com.sap.b1i.bizprocessor:bizatoms"
	bfa:force=""
	exclude-result-prefixes="vpf bfa">
	<xsl:output method="xml"/>
	<xsl:param name="atom"/>
	<!-- The Call SQL atom's id. Change it if the atoms were placed in another order. -->
	<xsl:param name="sqlAtom" select="'atom2'"/>

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

	<xsl:template name="col">
		<xsl:param name="row"/>
		<xsl:param name="name"/>
		<xsl:value-of select="normalize-space($row/*[local-name()=$name])"/>
	</xsl:template>

	<xsl:template name="transform">
		<xsl:variable name="rows" select="/vpf:Msg/vpf:Body/vpf:Payload[@id=$sqlAtom]//*[local-name()='Row']"/>
		<xsl:variable name="h" select="$rows[1]"/>
		<xsl:variable name="margin" select="number(normalize-space($h/*[local-name()='Margin']))"/>
		<xsl:variable name="hdrDisc" select="number(concat('0', normalize-space($h/*[local-name()='HeaderDisc'])))"/>
		<xsl:variable name="vendorState" select="normalize-space($h/*[local-name()='VendorState'])"/>
		<xsl:variable name="tax">
			<xsl:choose>
				<xsl:when test="$vendorState = ''"/>
				<xsl:when test="translate($vendorState, 'abcdefghijklmnopqrstuvwxyz', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ') = translate(normalize-space($h/*[local-name()='HomeState']), 'abcdefghijklmnopqrstuvwxyz', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ')">
					<xsl:value-of select="normalize-space($h/*[local-name()='TaxInState'])"/>
				</xsl:when>
				<xsl:otherwise><xsl:value-of select="normalize-space($h/*[local-name()='TaxOutState'])"/></xsl:otherwise>
			</xsl:choose>
		</xsl:variable>

		<!-- Why not, checked in order; the first one wins. Skips (nothing is
		     wrong, there is just nothing to do) start "skip:". -->
		<xsl:variable name="why">
			<xsl:choose>
				<xsl:when test="not($h)">skip: the sales order was not found</xsl:when>
				<xsl:when test="normalize-space($h/*[local-name()='Enabled']) != 'Y'">skip: @MANNA_IC ENABLED is not Y</xsl:when>
				<xsl:when test="normalize-space($h/*[local-name()='StartDate']) = ''">START_DATE is not set in @MANNA_IC</xsl:when>
				<xsl:when test="number(translate($h/*[local-name()='DocDate'], '-', '')) &lt; number(translate(normalize-space($h/*[local-name()='StartDate']), '-', ''))">skip: the sales order is dated before START_DATE</xsl:when>
				<!-- Only orders the sync's PASS M made from ERPNext (user, 4 Nov 2026):
				     NumAtCard is the ERPNext name and the remarks start "From ERPNext"
				     and that name, as New-MfSalesOrderBody writes them. An order keyed in
				     SAP is left to whoever keyed it, even if its reference looks like one. -->
				<xsl:when test="normalize-space($h/*[local-name()='ErpPrefix']) = ''">ERP_PREFIX is not set in @MANNA_IC</xsl:when>
				<xsl:when test="not(starts-with(normalize-space($h/*[local-name()='NumAtCard']), normalize-space($h/*[local-name()='ErpPrefix'])))
					or not(starts-with(normalize-space($h/*[local-name()='Remarks']), concat('From ERPNext ', normalize-space($h/*[local-name()='NumAtCard']))))">skip: not an order from ERPNext - keyed in SAP</xsl:when>
				<xsl:when test="normalize-space($h/*[local-name()='Cancelled']) != 'N'">skip: the sales order is cancelled</xsl:when>
				<xsl:when test="number($h/*[local-name()='PoCount']) &gt; 0">
					<xsl:value-of select="concat('skip: purchase order ', normalize-space($h/*[local-name()='PoDocNum']), ' already carries this sales order')"/>
				</xsl:when>
				<xsl:when test="string($margin) = 'NaN' or $margin &lt;= 0">no MARGIN in @MANNA_IC - refusing to buy from Hi-Tech at the customer's price</xsl:when>
				<xsl:when test="normalize-space($h/*[local-name()='VendorType']) != 'S'">
					<xsl:value-of select="concat('supplier ', normalize-space($h/*[local-name()='Vendor']), ' (VENDOR) is missing or not a supplier')"/>
				</xsl:when>
				<xsl:when test="normalize-space($h/*[local-name()='VendorFrozen']) = 'Y'">
					<xsl:value-of select="concat('supplier ', normalize-space($h/*[local-name()='Vendor']), ' is inactive')"/>
				</xsl:when>
				<xsl:when test="string($tax) = ''">
					<xsl:value-of select="concat('no tax code for the supplier state &quot;', $vendorState, '&quot; (HOME_STATE / TAX_IN_STATE / TAX_OUT_STATE)')"/>
				</xsl:when>
				<xsl:when test="$rows[normalize-space(*[local-name()='ItemCode']) = '']">a line has no item</xsl:when>
				<xsl:when test="$rows[normalize-space(*[local-name()='InvntItem']) != 'Y' or normalize-space(*[local-name()='PrchseItem']) != 'Y' or normalize-space(*[local-name()='ItemFrozen']) = 'Y']">
					<xsl:value-of select="concat(normalize-space($rows[normalize-space(*[local-name()='InvntItem']) != 'Y' or normalize-space(*[local-name()='PrchseItem']) != 'Y' or normalize-space(*[local-name()='ItemFrozen']) = 'Y'][1]/*[local-name()='ItemCode']), ' is not an active stock item Manna Treads can buy')"/>
				</xsl:when>
				<xsl:when test="$rows[not(number(*[local-name()='Quantity']) &gt; 0)]">a line has no quantity</xsl:when>
				<xsl:when test="$rows[not(round(number(*[local-name()='PriceAfVAT']) * (1 - $hdrDisc div 100) * 100) div 100 - $margin &gt; 0)]">
					<xsl:value-of select="concat(normalize-space($rows[not(round(number(*[local-name()='PriceAfVAT']) * (1 - $hdrDisc div 100) * 100) div 100 - $margin &gt; 0)][1]/*[local-name()='ItemCode']), ' sells at no more than the margin of ', $margin, '/kg')"/>
				</xsl:when>
			</xsl:choose>
		</xsl:variable>

		<Decision xmlns="">
			<SalesOrder><xsl:value-of select="normalize-space($h/*[local-name()='DocNum'])"/></SalesOrder>
			<xsl:choose>
				<xsl:when test="string($why) != ''">
					<Make>N</Make>
					<Reason><xsl:value-of select="$why"/></Reason>
				</xsl:when>
				<xsl:otherwise>
					<Make>Y</Make>
					<Reason/>
					<xsl:call-template name="bom">
						<xsl:with-param name="rows" select="$rows"/>
						<xsl:with-param name="h" select="$h"/>
						<xsl:with-param name="margin" select="$margin"/>
						<xsl:with-param name="hdrDisc" select="$hdrDisc"/>
						<xsl:with-param name="tax" select="string($tax)"/>
					</xsl:call-template>
				</xsl:otherwise>
			</xsl:choose>
		</Decision>
	</xsl:template>

	<xsl:template name="bom">
		<xsl:param name="rows"/>
		<xsl:param name="h"/>
		<xsl:param name="margin"/>
		<xsl:param name="hdrDisc"/>
		<xsl:param name="tax"/>
		<!-- The ERPNext order's name - only those orders get this far. Copied,
		     because the sync finds the purchase order by it (PASS P adopts by
		     NumAtCard). -->
		<xsl:variable name="erpName" select="normalize-space($h/*[local-name()='NumAtCard'])"/>
		<BOM>
			<BO>
				<AdmInfo><Object>oPurchaseOrders</Object></AdmInfo>
				<Documents>
					<row>
						<CardCode><xsl:value-of select="normalize-space($h/*[local-name()='Vendor'])"/></CardCode>
						<DocDueDate><xsl:value-of select="translate(normalize-space($h/*[local-name()='DueDate']), '-', '')"/></DocDueDate>
						<xsl:if test="string($erpName) != ''"><NumAtCard><xsl:value-of select="$erpName"/></NumAtCard></xsl:if>
						<Comments>
							<xsl:value-of select="concat('For Manna Treads SO ', normalize-space($h/*[local-name()='DocNum']))"/>
							<xsl:if test="string($erpName) != ''"><xsl:value-of select="concat(' - ERPNext ', $erpName)"/></xsl:if>
							<xsl:text> - made by B1if</xsl:text>
						</Comments>
						<DiscPrcnt>0</DiscPrcnt>
						<xsl:if test="normalize-space($h/*[local-name()='PoSeries']) != ''"><Series><xsl:value-of select="normalize-space($h/*[local-name()='PoSeries'])"/></Series></xsl:if>
						<xsl:if test="normalize-space($h/*[local-name()='PoBranch']) != ''"><BPLId><xsl:value-of select="normalize-space($h/*[local-name()='PoBranch'])"/></BPLId></xsl:if>
						<U_MannaMtSo><xsl:value-of select="normalize-space($h/*[local-name()='DocEntry'])"/></U_MannaMtSo>
					</row>
				</Documents>
				<Document_Lines>
					<xsl:for-each select="$rows">
						<xsl:variable name="gross" select="round(number(*[local-name()='PriceAfVAT']) * (1 - $hdrDisc div 100) * 100) div 100 - $margin"/>
						<xsl:variable name="vat" select="number(concat('0', normalize-space(*[local-name()='VatPrcnt'])))"/>
						<row>
							<ItemCode><xsl:value-of select="normalize-space(*[local-name()='ItemCode'])"/></ItemCode>
							<Quantity><xsl:value-of select="format-number(number(*[local-name()='Quantity']), '0.######')"/></Quantity>
							<Price><xsl:value-of select="format-number(round(round($gross * 100) div 100 div (1 + $vat div 100) * 1000000) div 1000000, '0.######')"/></Price>
							<DiscPrcnt>0</DiscPrcnt>
							<TaxCode><xsl:value-of select="$tax"/></TaxCode>
							<xsl:if test="normalize-space($h/*[local-name()='PoWhs']) != ''"><WhsCode><xsl:value-of select="normalize-space($h/*[local-name()='PoWhs'])"/></WhsCode></xsl:if>
							<xsl:if test="normalize-space($h/*[local-name()='PoLocation']) != ''"><LocCode><xsl:value-of select="normalize-space($h/*[local-name()='PoLocation'])"/></LocCode></xsl:if>
						</row>
					</xsl:for-each>
				</Document_Lines>
			</BO>
		</BOM>
	</xsl:template>
</xsl:stylesheet>
