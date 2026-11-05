<?xml version="1.0" encoding="UTF-8"?>
<!--
  Step 2, the xform in front of the B1 Object atom (atom6; the B1 Object atom
  is atom7, on Hi-Tech's SysId): hands it Hi-Tech's sales order and nothing
  else. Step 1's bom.xsl with the decision read from atom5.

  The B1 Object atom sends whatever this payload holds to the DI API, so it is
  only the Documents and Document_Lines step 2's final.xsl built, and only when
  it said Make = Y. There is no branch around it (this B1if never runs a step
  with one): on N this payload is empty and the atom's Method, read from the
  decision, is a retrieval of Hi-Tech's customer record, which ignores the
  payload. Empty on N also means a Method that somehow said Insert would have
  nothing to insert.
-->
<xsl:stylesheet version="1.0"
	xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
	xmlns:vpf="urn:com.sap.b1i.vplatform:entity"
	xmlns:bfa="urn:com.sap.b1i.bizprocessor:bizatoms"
	bfa:force=""
	exclude-result-prefixes="vpf bfa">
	<xsl:output method="xml"/>
	<xsl:param name="atom"/>
	<!-- The decision atom (final.xsl). Change it if the atoms were placed in another order. -->
	<xsl:param name="decisionAtom" select="'atom5'"/>

	<xsl:template match="/">
		<vpf:Msg>
			<xsl:copy-of select="/vpf:Msg/@*"/>
			<xsl:copy-of select="/vpf:Msg/vpf:Header"/>
			<vpf:Body>
				<xsl:copy-of select="/vpf:Msg/vpf:Body/*"/>
				<!-- The BO's contents only (Documents, Document_Lines): the B1 Object
				     atom wraps the payload in its own BOM/BO/AdmInfo, from its Object
				     field, and a second BOM inside that one is not DI's format (seen in
				     the first real call, 5 Nov 2026). -->
				<vpf:Payload Role="X" id="{$atom}">
					<xsl:copy-of select="/vpf:Msg/vpf:Body/vpf:Payload[@id=$decisionAtom]/Decision[Make='Y']/BOM/BO/*[local-name() != 'AdmInfo']"/>
				</vpf:Payload>
			</vpf:Body>
		</vpf:Msg>
	</xsl:template>
</xsl:stylesheet>
