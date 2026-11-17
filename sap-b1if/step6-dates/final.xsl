<?xml version="1.0" encoding="UTF-8"?>
<!--
  Step 6 (delivery dates), atom "final" (atom5): the update of Manna Treads'
  sales order and purchase order to the dates Hi-Tech now promises, or the
  reason there is none.

  Output: <Decision><MtPo/><Waiting/><Make/><Reason/><Changes/><So/><Po/>
  </Decision>, each of So and Po holding CallMethod, CallObject, CallKeyName,
  CallKey and, when that document changes, the BOM. A B1 Object atom per
  document always runs (this B1if never runs a step with a branch) and takes
  its call from these: an update of the document by its DocEntry, or - when it
  already agrees, or nothing is to be done - a read of Manna Treads' vendor
  record for Hi-Tech, which is there whenever the settings are, so nothing is
  written.

  THE UPDATE HANDS SAP EVERY LINE, in the order SAP shows them, each with its
  own LineNum:
    an open line    LineNum and ShipDate - Hi-Tech's date for the item, or the
                    date the line already has when Hi-Tech has no open line for it
    a closed line   LineNum only
  This is the first step here that changes a document instead of adding one
  (13 Nov 2026), and how B1if's update finds a line - by its LineNum, or by its
  place in the list - is not written down anywhere we could check. A payload
  that is every line, in order, numbered, is right under both: by number it is
  plainly right, by place row n is line n and the number is its own. Giving
  every open line its date, changed or not, also means that if SAP copies a
  changed document date down to the rows, as its own screen offers to, each
  row still ends on the date meant for it.

  The document's own date (DocDueDate) becomes the latest of Hi-Tech's dates:
  the day the order is complete, the same rule ERPNext's order follows.

  Dates leave SQL as yyyy-mm-dd and go to the DI API as yyyymmdd.
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
	<xsl:param name="htAtom" select="'atom2'"/>
	<xsl:param name="mtAtom" select="'atom4'"/>

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
		<xsl:variable name="ht" select="/vpf:Msg/vpf:Body/vpf:Payload[@id=$htAtom]//*[local-name()='Row']"/>
		<xsl:variable name="mt" select="/vpf:Msg/vpf:Body/vpf:Payload[@id=$mtAtom]//*[local-name()='Row']"/>
		<xsl:variable name="m" select="$mt[1]"/>
		<xsl:variable name="so" select="$mt[normalize-space(*[local-name()='Kind']) = 'SO']"/>
		<xsl:variable name="po" select="$mt[normalize-space(*[local-name()='Kind']) = 'PO']"/>
		<xsl:variable name="vendor" select="normalize-space($m/*[local-name()='Vendor'])"/>

		<xsl:variable name="why">
			<xsl:choose>
				<xsl:when test="not($ht)">Hi-Tech's query returned nothing</xsl:when>
				<xsl:when test="normalize-space($ht[1]/*[local-name()='Enabled']) != 'Y'">skip: Hi-Tech's @MANNA_IC ENABLED is not Y</xsl:when>
				<xsl:when test="not($m)">Manna Treads' query returned nothing</xsl:when>
				<xsl:when test="normalize-space($m/*[local-name()='Enabled']) != 'Y'">skip: Manna Treads' @MANNA_IC ENABLED is not Y</xsl:when>
				<xsl:when test="normalize-space($m/*[local-name()='DateSync']) != 'Y'">skip: Manna Treads' @MANNA_IC DATE_SYNC is not Y</xsl:when>
				<!-- Most runs: step 6 is on a timer and the dates nearly always agree. -->
				<xsl:when test="not($ht[normalize-space(*[local-name()='MtPo']) != ''])">skip: no open Hi-Tech order of the flow was changed in the last 7 days</xsl:when>
				<xsl:when test="not($so) and not($po)">skip: every delivery date in Manna Treads already agrees with Hi-Tech</xsl:when>
			</xsl:choose>
		</xsl:variable>

		<Decision xmlns="">
			<MtPo><xsl:value-of select="normalize-space(($po | $so)[1]/*[local-name()='MtPo'])"/></MtPo>
			<Waiting><xsl:value-of select="normalize-space($m/*[local-name()='Waiting'])"/></Waiting>
			<xsl:choose>
				<xsl:when test="string($why) != ''">
					<Make>N</Make>
					<Reason><xsl:value-of select="$why"/></Reason>
					<Changes/>
					<So><xsl:call-template name="read"><xsl:with-param name="vendor" select="$vendor"/></xsl:call-template></So>
					<Po><xsl:call-template name="read"><xsl:with-param name="vendor" select="$vendor"/></xsl:call-template></Po>
				</xsl:when>
				<xsl:otherwise>
					<Make>Y</Make>
					<Reason/>
					<Changes>
						<xsl:call-template name="said"><xsl:with-param name="rows" select="$so"/><xsl:with-param name="what" select="'sales order'"/></xsl:call-template>
						<xsl:call-template name="said"><xsl:with-param name="rows" select="$po"/><xsl:with-param name="what" select="'purchase order'"/></xsl:call-template>
					</Changes>
					<So><xsl:call-template name="doc"><xsl:with-param name="rows" select="$so"/><xsl:with-param name="object" select="'17'"/><xsl:with-param name="vendor" select="$vendor"/></xsl:call-template></So>
					<Po><xsl:call-template name="doc"><xsl:with-param name="rows" select="$po"/><xsl:with-param name="object" select="'22'"/><xsl:with-param name="vendor" select="$vendor"/></xsl:call-template></Po>
				</xsl:otherwise>
			</xsl:choose>
		</Decision>
	</xsl:template>

	<!-- Nothing to write for this document: read Hi-Tech's vendor record instead. -->
	<xsl:template name="read">
		<xsl:param name="vendor"/>
		<CallMethod xmlns="">Synchronous Retrieval</CallMethod>
		<CallObject xmlns="">2</CallObject>
		<CallKeyName xmlns="">CardCode</CallKeyName>
		<CallKey xmlns=""><xsl:value-of select="$vendor"/></CallKey>
	</xsl:template>

	<!-- One document: the update when a line's date or the document's own date
	     is not the one wanted, else the read. The pair was picked because one of
	     the two differs; the other may well agree already. -->
	<xsl:template name="doc">
		<xsl:param name="rows"/>
		<xsl:param name="object"/>
		<xsl:param name="vendor"/>
		<xsl:variable name="h" select="$rows[1]"/>
		<xsl:variable name="hdrWant" select="normalize-space($h/*[local-name()='HdrWant'])"/>
		<xsl:variable name="differs" select="$rows[normalize-space(*[local-name()='Want']) != '' and normalize-space(*[local-name()='Want']) != normalize-space(*[local-name()='ShipDate'])]
			or ($hdrWant != '' and $hdrWant != normalize-space($h/*[local-name()='DueDate']))"/>
		<xsl:choose>
			<xsl:when test="not($rows) or not($differs)">
				<xsl:call-template name="read"><xsl:with-param name="vendor" select="$vendor"/></xsl:call-template>
			</xsl:when>
			<xsl:otherwise>
				<CallMethod xmlns="">Synchronous Update</CallMethod>
				<CallObject xmlns=""><xsl:value-of select="$object"/></CallObject>
				<CallKeyName xmlns="">DocEntry</CallKeyName>
				<CallKey xmlns=""><xsl:value-of select="normalize-space($h/*[local-name()='DocEntry'])"/></CallKey>
				<BOM xmlns="">
					<BO>
						<AdmInfo><Object><xsl:value-of select="$object"/></Object><Version>2</Version></AdmInfo>
						<Documents>
							<row>
								<DocDueDate>
									<xsl:choose>
										<xsl:when test="$hdrWant != ''"><xsl:value-of select="translate($hdrWant, '-', '')"/></xsl:when>
										<xsl:otherwise><xsl:value-of select="translate(normalize-space($h/*[local-name()='DueDate']), '-', '')"/></xsl:otherwise>
									</xsl:choose>
								</DocDueDate>
							</row>
						</Documents>
						<Document_Lines>
							<xsl:for-each select="$rows">
								<xsl:variable name="want" select="normalize-space(*[local-name()='Want'])"/>
								<row>
									<LineNum><xsl:value-of select="normalize-space(*[local-name()='LineNum'])"/></LineNum>
									<xsl:if test="normalize-space(*[local-name()='LineStatus']) = 'O'">
										<xsl:choose>
											<xsl:when test="$want != ''"><ShipDate><xsl:value-of select="translate($want, '-', '')"/></ShipDate></xsl:when>
											<xsl:when test="normalize-space(*[local-name()='ShipDate']) != ''"><ShipDate><xsl:value-of select="translate(normalize-space(*[local-name()='ShipDate']), '-', '')"/></ShipDate></xsl:when>
										</xsl:choose>
									</xsl:if>
								</row>
							</xsl:for-each>
						</Document_Lines>
					</BO>
				</BOM>
			</xsl:otherwise>
		</xsl:choose>
	</xsl:template>

	<!-- What changes, in words, for the message log: "sales order 586: PMB001 2026-11-20 to 2026-11-25; ..." -->
	<xsl:template name="said">
		<xsl:param name="rows"/>
		<xsl:param name="what"/>
		<xsl:variable name="h" select="$rows[1]"/>
		<xsl:variable name="hdrWant" select="normalize-space($h/*[local-name()='HdrWant'])"/>
		<xsl:variable name="moved" select="$rows[normalize-space(*[local-name()='Want']) != '' and normalize-space(*[local-name()='Want']) != normalize-space(*[local-name()='ShipDate'])]"/>
		<xsl:if test="$moved or ($hdrWant != '' and $hdrWant != normalize-space($h/*[local-name()='DueDate']))">
			<xsl:value-of select="concat($what, ' ', normalize-space($h/*[local-name()='DocNum']), ':')"/>
			<xsl:if test="$hdrWant != '' and $hdrWant != normalize-space($h/*[local-name()='DueDate'])">
				<xsl:value-of select="concat(' document ', normalize-space($h/*[local-name()='DueDate']), ' to ', $hdrWant, ';')"/>
			</xsl:if>
			<xsl:for-each select="$moved">
				<xsl:value-of select="concat(' ', normalize-space(*[local-name()='ItemCode']), ' ', normalize-space(*[local-name()='ShipDate']), ' to ', normalize-space(*[local-name()='Want']), ';')"/>
			</xsl:for-each>
			<xsl:text> </xsl:text>
		</xsl:if>
	</xsl:template>
</xsl:stylesheet>
