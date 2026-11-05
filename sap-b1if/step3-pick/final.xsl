<?xml version="1.0" encoding="UTF-8"?>
<!--
  Step 3, atom "final" (atom7): from one of PASS K's pick lists in Hi-Tech,
  the three documents stage 4 makes, or the reason there are none.

    Inv   Hi-Tech's A/R invoice to Manna Treads, each line based on the
          sales order line the pick list line is on (SAP closes the pick list
          line when it is invoiced - seen on TEST, 5 Nov 2026), for the
          pick list's kilos, batches oldest first.
    Grpo  Manna Treads' goods receipt from Hi-Tech, each line based on the
          purchase order line for the same item, the same kilos.
    Dn    Manna Treads' delivery to its customer, each line based on the
          sales order line for the same item, the same kilos.

  Only what is on the pick list: a product the rep left off the ERPNext list
  - how an item is cancelled - is on none of them, and its lines stay open.
  All three carry the ERPNext list's name in NumAtCard, which is how the sync
  finds them, and how the next run knows this list is done: the timer's query
  (sql-ht.xsl) only offers a list no live invoice carries the name of.

  Output: <Decision><PickList/><PickName/><Make/><Reason/><Inv/><Grpo/><Dn/>
  </Decision>, each of Inv, Grpo and Dn holding CallMethod, CallObject,
  CallKeyName, CallKey and, on Y, the BOM. A B1 Object atom per document
  always runs (this B1if never runs a step with a branch) and takes its call
  from these: on Y an insert, on N a read of a business partner that is there
  whenever the settings are, so nothing is written. All or nothing: one
  problem anywhere refuses all three, so Manna Treads is never billed for
  goods it never received.

  Dates: today by the SQL server's clock, due today too - left to SAP, the due
  date came from 10118's payment terms and fell outside the open periods
  ("Date deviates from permissible range", TEST, 5 Nov 2026).
-->
<xsl:stylesheet version="1.0"
	xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
	xmlns:vpf="urn:com.sap.b1i.vplatform:entity"
	xmlns:bfa="urn:com.sap.b1i.bizprocessor:bizatoms"
	bfa:force=""
	exclude-result-prefixes="vpf bfa">
	<xsl:output method="xml"/>
	<xsl:param name="atom"/>
	<!-- The three Call SQL atoms. Change them if the atoms were placed in another order. -->
	<xsl:param name="htAtom" select="'atom2'"/>
	<xsl:param name="batchAtom" select="'atom4'"/>
	<xsl:param name="mtAtom" select="'atom6'"/>

	<xsl:variable name="lc" select="'abcdefghijklmnopqrstuvwxyz'"/>
	<xsl:variable name="uc" select="'ABCDEFGHIJKLMNOPQRSTUVWXYZ'"/>

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
		<xsl:variable name="pk" select="/vpf:Msg/vpf:Body/vpf:Payload[@id=$htAtom]//*[local-name()='Row']"/>
		<xsl:variable name="bt" select="/vpf:Msg/vpf:Body/vpf:Payload[@id=$batchAtom]//*[local-name()='Row']"/>
		<xsl:variable name="mt" select="/vpf:Msg/vpf:Body/vpf:Payload[@id=$mtAtom]//*[local-name()='Row']"/>
		<xsl:variable name="h" select="$pk[1]"/>
		<xsl:variable name="m" select="$mt[1]"/>
		<xsl:variable name="poRows" select="$mt[normalize-space(*[local-name()='Kind']) = 'PO']"/>
		<xsl:variable name="soRows" select="$mt[normalize-space(*[local-name()='Kind']) = 'SO']"/>
		<xsl:variable name="name" select="normalize-space($h/*[local-name()='PickName'])"/>

		<!-- The first line whose item Manna Treads' purchase order or sales order
		     has no open line for, and the first batch item Hi-Tech holds too
		     little of. -->
		<xsl:variable name="noPo">
			<xsl:for-each select="$pk">
				<xsl:variable name="it" select="translate(normalize-space(*[local-name()='ItemCode']), $lc, $uc)"/>
				<xsl:if test="not($poRows[translate(normalize-space(*[local-name()='ItemCode']), $lc, $uc) = $it and normalize-space(*[local-name()='LineStatus']) = 'O'])"><xsl:value-of select="concat(normalize-space(*[local-name()='ItemCode']), ' ')"/></xsl:if>
			</xsl:for-each>
		</xsl:variable>
		<xsl:variable name="noSo">
			<xsl:for-each select="$pk">
				<xsl:variable name="it" select="translate(normalize-space(*[local-name()='ItemCode']), $lc, $uc)"/>
				<xsl:if test="not($soRows[translate(normalize-space(*[local-name()='ItemCode']), $lc, $uc) = $it and normalize-space(*[local-name()='LineStatus']) = 'O'])"><xsl:value-of select="concat(normalize-space(*[local-name()='ItemCode']), ' ')"/></xsl:if>
			</xsl:for-each>
		</xsl:variable>
		<xsl:variable name="shortBatch">
			<xsl:for-each select="$pk[normalize-space(*[local-name()='Batch']) = 'Y']">
				<xsl:variable name="it" select="normalize-space(*[local-name()='ItemCode'])"/>
				<xsl:variable name="wh" select="normalize-space(*[local-name()='WhsCode'])"/>
				<xsl:variable name="have" select="sum($bt[normalize-space(*[local-name()='ItemCode']) = $it and normalize-space(*[local-name()='WhsCode']) = $wh]/*[local-name()='Avail'])"/>
				<xsl:if test="$have + 0.0005 &lt; number(*[local-name()='Kg'])"><xsl:value-of select="concat($it, ' (', format-number($have, '0.###'), ' kg in batches in ', $wh, ') ')"/></xsl:if>
			</xsl:for-each>
		</xsl:variable>

		<xsl:variable name="why">
			<xsl:choose>
				<xsl:when test="not($h)">Hi-Tech's query returned nothing</xsl:when>
				<!-- Step 3 runs on a timer; most runs find nothing to do. -->
				<xsl:when test="normalize-space($h/*[local-name()='PickEntry']) = ''">skip: no ERPNext pick list waiting in Hi-Tech</xsl:when>
				<xsl:when test="$name = ''">skip: not from ERPNext (its Remarks do not start "ERPNext PICK-...")</xsl:when>
				<xsl:when test="normalize-space($h/*[local-name()='Enabled']) != 'Y'">skip: Hi-Tech's @MANNA_IC ENABLED is not Y</xsl:when>
				<xsl:when test="$pk[normalize-space(*[local-name()='BaseObject']) != '17']">a pick list line is not on a sales order</xsl:when>
				<xsl:when test="$pk[normalize-space(*[local-name()='OrderEntry']) != normalize-space($h/*[local-name()='OrderEntry'])]">the pick list spans more than one sales order</xsl:when>
				<xsl:when test="normalize-space($h/*[local-name()='SoCancelled']) != 'N'">Hi-Tech's sales order is cancelled or missing</xsl:when>
				<xsl:when test="normalize-space($h/*[local-name()='MtPo']) = ''">skip: Hi-Tech's sales order was not made by B1if (U_MannaMtPo is empty)</xsl:when>
				<xsl:when test="$pk[normalize-space(*[local-name()='SoLineStatus']) != 'O']">
					<xsl:value-of select="concat(normalize-space($pk[normalize-space(*[local-name()='SoLineStatus']) != 'O'][1]/*[local-name()='ItemCode']), ' is closed on Hi-Tech sales order ', normalize-space($h/*[local-name()='SoNum']))"/>
				</xsl:when>
				<xsl:when test="$pk[not(number(*[local-name()='Kg']) &gt; 0)]">a pick list line has no kilos</xsl:when>
				<xsl:when test="normalize-space($h/*[local-name()='Customer']) = ''">Hi-Tech's @MANNA_IC has no CUSTOMER</xsl:when>
				<xsl:when test="string($shortBatch) != ''">
					<xsl:value-of select="concat('not enough in batches: ', normalize-space($shortBatch))"/>
				</xsl:when>
				<xsl:when test="not($m)">Manna Treads' query returned nothing</xsl:when>
				<xsl:when test="not($poRows)">
					<xsl:value-of select="concat('Manna Treads purchase order (DocEntry ', normalize-space($h/*[local-name()='MtPo']), ') was not found')"/>
				</xsl:when>
				<xsl:when test="normalize-space($m/*[local-name()='Enabled']) != 'Y'">skip: Manna Treads' @MANNA_IC ENABLED is not Y</xsl:when>
				<xsl:when test="number($m/*[local-name()='GrpoCount']) &gt; 0 or number($m/*[local-name()='DnCount']) &gt; 0">
					<xsl:value-of select="concat('skip: Manna Treads already has a goods receipt or delivery carrying ', $name)"/>
				</xsl:when>
				<xsl:when test="normalize-space($poRows[1]/*[local-name()='Cancelled']) != 'N'">Manna Treads' purchase order is cancelled</xsl:when>
				<xsl:when test="not($soRows)">Manna Treads' sales order for the purchase order was not found</xsl:when>
				<xsl:when test="normalize-space($soRows[1]/*[local-name()='Cancelled']) != 'N'">Manna Treads' sales order is cancelled</xsl:when>
				<xsl:when test="string($noPo) != ''">
					<xsl:value-of select="concat('not open on Manna Treads purchase order ', normalize-space($poRows[1]/*[local-name()='DocNum']), ': ', normalize-space($noPo))"/>
				</xsl:when>
				<xsl:when test="string($noSo) != ''">
					<xsl:value-of select="concat('not open on Manna Treads sales order ', normalize-space($soRows[1]/*[local-name()='DocNum']), ': ', normalize-space($noSo))"/>
				</xsl:when>
				<xsl:when test="normalize-space($m/*[local-name()='DnSeries']) = ''">Manna Treads' @MANNA_IC has no DN_SERIES - it has no delivery series of its own (5 Nov 2026)</xsl:when>
				<xsl:when test="normalize-space($m/*[local-name()='Vendor']) = ''">Manna Treads' @MANNA_IC has no VENDOR</xsl:when>
			</xsl:choose>
		</xsl:variable>

		<xsl:variable name="today" select="translate(normalize-space($h/*[local-name()='Today']), '-', '')"/>
		<xsl:variable name="comment" select="concat('Pick list ', $name, ' (Hi-Tech pick list ', normalize-space($h/*[local-name()='PickEntry']), ') - made by B1if')"/>

		<Decision xmlns="">
			<PickList><xsl:value-of select="normalize-space($h/*[local-name()='PickEntry'])"/></PickList>
			<PickName><xsl:value-of select="$name"/></PickName>
			<xsl:choose>
				<xsl:when test="string($why) != ''">
					<Make>N</Make>
					<Reason><xsl:value-of select="$why"/></Reason>
					<!-- Reads only: Hi-Tech's customer record for Manna Treads, and
					     Manna Treads' vendor record for Hi-Tech, by the settings. -->
					<Inv>
						<CallMethod>Synchronous Retrieval</CallMethod>
						<CallObject>2</CallObject>
						<CallKeyName>CardCode</CallKeyName>
						<CallKey><xsl:value-of select="normalize-space($h/*[local-name()='Customer'])"/></CallKey>
					</Inv>
					<Grpo>
						<CallMethod>Synchronous Retrieval</CallMethod>
						<CallObject>2</CallObject>
						<CallKeyName>CardCode</CallKeyName>
						<CallKey><xsl:value-of select="normalize-space($m/*[local-name()='Vendor'])"/></CallKey>
					</Grpo>
					<Dn>
						<CallMethod>Synchronous Retrieval</CallMethod>
						<CallObject>2</CallObject>
						<CallKeyName>CardCode</CallKeyName>
						<CallKey><xsl:value-of select="normalize-space($m/*[local-name()='Vendor'])"/></CallKey>
					</Dn>
				</xsl:when>
				<xsl:otherwise>
					<Make>Y</Make>
					<Reason/>
					<Inv>
						<CallMethod>Synchronous Insert</CallMethod>
						<CallObject>13</CallObject>
						<CallKeyName>DocEntry</CallKeyName>
						<CallKey/>
						<BOM>
							<BO>
								<AdmInfo><Object>13</Object><Version>2</Version></AdmInfo>
								<Documents>
									<row>
										<CardCode><xsl:value-of select="normalize-space($h/*[local-name()='SoCard'])"/></CardCode>
										<DocDate><xsl:value-of select="$today"/></DocDate>
										<DocDueDate><xsl:value-of select="$today"/></DocDueDate>
										<NumAtCard><xsl:value-of select="$name"/></NumAtCard>
										<Comments><xsl:value-of select="$comment"/></Comments>
										<xsl:if test="normalize-space($h/*[local-name()='InvSeries']) != ''"><Series><xsl:value-of select="normalize-space($h/*[local-name()='InvSeries'])"/></Series></xsl:if>
									</row>
								</Documents>
								<Document_Lines>
									<xsl:for-each select="$pk">
										<row>
											<BaseType>17</BaseType>
											<BaseEntry><xsl:value-of select="normalize-space(*[local-name()='OrderEntry'])"/></BaseEntry>
											<BaseLine><xsl:value-of select="normalize-space(*[local-name()='OrderLine'])"/></BaseLine>
											<Quantity><xsl:value-of select="format-number(number(*[local-name()='Kg']), '0.###')"/></Quantity>
										</row>
									</xsl:for-each>
								</Document_Lines>
								<xsl:if test="$pk[normalize-space(*[local-name()='Batch']) = 'Y']">
									<BatchNumbers>
										<xsl:for-each select="$pk">
											<xsl:if test="normalize-space(*[local-name()='Batch']) = 'Y'">
												<xsl:variable name="it" select="normalize-space(*[local-name()='ItemCode'])"/>
												<xsl:variable name="wh" select="normalize-space(*[local-name()='WhsCode'])"/>
												<xsl:call-template name="fifo">
													<xsl:with-param name="batches" select="$bt[normalize-space(*[local-name()='ItemCode']) = $it and normalize-space(*[local-name()='WhsCode']) = $wh]"/>
													<xsl:with-param name="need" select="round(number(*[local-name()='Kg']) * 1000) div 1000"/>
													<xsl:with-param name="line" select="position() - 1"/>
												</xsl:call-template>
											</xsl:if>
										</xsl:for-each>
									</BatchNumbers>
								</xsl:if>
							</BO>
						</BOM>
					</Inv>
					<Grpo>
						<CallMethod>Synchronous Insert</CallMethod>
						<CallObject>20</CallObject>
						<CallKeyName>DocEntry</CallKeyName>
						<CallKey/>
						<BOM>
							<BO>
								<AdmInfo><Object>20</Object><Version>2</Version></AdmInfo>
								<Documents>
									<row>
										<CardCode><xsl:value-of select="normalize-space($poRows[1]/*[local-name()='CardCode'])"/></CardCode>
										<DocDate><xsl:value-of select="$today"/></DocDate>
										<DocDueDate><xsl:value-of select="$today"/></DocDueDate>
										<NumAtCard><xsl:value-of select="$name"/></NumAtCard>
										<Comments><xsl:value-of select="$comment"/></Comments>
										<xsl:if test="normalize-space($m/*[local-name()='GrpoSeries']) != ''"><Series><xsl:value-of select="normalize-space($m/*[local-name()='GrpoSeries'])"/></Series></xsl:if>
										<xsl:if test="normalize-space($m/*[local-name()='Branch']) != ''"><BPL_IDAssignedToInvoice><xsl:value-of select="normalize-space($m/*[local-name()='Branch'])"/></BPL_IDAssignedToInvoice></xsl:if>
									</row>
								</Documents>
								<Document_Lines>
									<xsl:for-each select="$pk">
										<xsl:variable name="it" select="translate(normalize-space(*[local-name()='ItemCode']), $lc, $uc)"/>
										<xsl:variable name="pl" select="$poRows[translate(normalize-space(*[local-name()='ItemCode']), $lc, $uc) = $it and normalize-space(*[local-name()='LineStatus']) = 'O'][1]"/>
										<row>
											<BaseType>22</BaseType>
											<BaseEntry><xsl:value-of select="normalize-space($pl/*[local-name()='DocEntry'])"/></BaseEntry>
											<BaseLine><xsl:value-of select="normalize-space($pl/*[local-name()='LineNum'])"/></BaseLine>
											<Quantity><xsl:value-of select="format-number(number(*[local-name()='Kg']), '0.###')"/></Quantity>
										</row>
									</xsl:for-each>
								</Document_Lines>
							</BO>
						</BOM>
					</Grpo>
					<Dn>
						<CallMethod>Synchronous Insert</CallMethod>
						<CallObject>15</CallObject>
						<CallKeyName>DocEntry</CallKeyName>
						<CallKey/>
						<BOM>
							<BO>
								<AdmInfo><Object>15</Object><Version>2</Version></AdmInfo>
								<Documents>
									<row>
										<CardCode><xsl:value-of select="normalize-space($soRows[1]/*[local-name()='CardCode'])"/></CardCode>
										<DocDate><xsl:value-of select="$today"/></DocDate>
										<DocDueDate><xsl:value-of select="$today"/></DocDueDate>
										<NumAtCard><xsl:value-of select="$name"/></NumAtCard>
										<Comments><xsl:value-of select="$comment"/></Comments>
										<Series><xsl:value-of select="normalize-space($m/*[local-name()='DnSeries'])"/></Series>
										<xsl:if test="normalize-space($m/*[local-name()='Branch']) != ''"><BPL_IDAssignedToInvoice><xsl:value-of select="normalize-space($m/*[local-name()='Branch'])"/></BPL_IDAssignedToInvoice></xsl:if>
									</row>
								</Documents>
								<Document_Lines>
									<xsl:for-each select="$pk">
										<xsl:variable name="it" select="translate(normalize-space(*[local-name()='ItemCode']), $lc, $uc)"/>
										<xsl:variable name="sl" select="$soRows[translate(normalize-space(*[local-name()='ItemCode']), $lc, $uc) = $it and normalize-space(*[local-name()='LineStatus']) = 'O'][1]"/>
										<row>
											<BaseType>17</BaseType>
											<BaseEntry><xsl:value-of select="normalize-space($sl/*[local-name()='DocEntry'])"/></BaseEntry>
											<BaseLine><xsl:value-of select="normalize-space($sl/*[local-name()='LineNum'])"/></BaseLine>
											<Quantity><xsl:value-of select="format-number(number(*[local-name()='Kg']), '0.###')"/></Quantity>
										</row>
									</xsl:for-each>
								</Document_Lines>
							</BO>
						</BOM>
					</Dn>
				</xsl:otherwise>
			</xsl:choose>
		</Decision>
	</xsl:template>

	<!-- Oldest batch first until the line's kilos are covered: one BatchNumbers
	     row per batch used, on invoice line $line. $batches is in the order the
	     SQL gave (oldest first); the decision has already checked they hold
	     enough. Kilos to three places, as SAP keeps them. -->
	<xsl:template name="fifo">
		<xsl:param name="batches"/>
		<xsl:param name="need"/>
		<xsl:param name="line"/>
		<xsl:if test="$need &gt; 0.0005 and $batches">
			<xsl:variable name="avail" select="round(number($batches[1]/*[local-name()='Avail']) * 1000) div 1000"/>
			<xsl:variable name="take">
				<xsl:choose>
					<xsl:when test="$avail &lt; $need"><xsl:value-of select="$avail"/></xsl:when>
					<xsl:otherwise><xsl:value-of select="$need"/></xsl:otherwise>
				</xsl:choose>
			</xsl:variable>
			<xsl:if test="number($take) &gt; 0">
				<row>
					<BatchNumber><xsl:value-of select="normalize-space($batches[1]/*[local-name()='BatchNum'])"/></BatchNumber>
					<Quantity><xsl:value-of select="format-number(number($take), '0.###')"/></Quantity>
					<BaseLineNumber><xsl:value-of select="$line"/></BaseLineNumber>
				</row>
			</xsl:if>
			<xsl:call-template name="fifo">
				<xsl:with-param name="batches" select="$batches[position() &gt; 1]"/>
				<xsl:with-param name="need" select="round(($need - number($take)) * 1000) div 1000"/>
				<xsl:with-param name="line" select="$line"/>
			</xsl:call-template>
		</xsl:if>
	</xsl:template>
</xsl:stylesheet>
