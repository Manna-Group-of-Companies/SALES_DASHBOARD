<?xml version="1.0" encoding="UTF-8"?>
<!--
  Step 1, the xform B1if puts in front of the B1 Object atom ("Predecessor
  Transformation for b1object Atom", atom6 on the server): hands the B1 Object
  atom the purchase order and nothing else.

  The B1 Object atom sends whatever this payload holds to the DI API, so it is
  only the BOM final.xsl built, and only when it said Make = Y. There is no
  branch around it (this B1if never runs a step with one): on N this payload is
  empty and the atom's Method, read from the decision, is a retrieval of the
  sales order, which ignores the payload. Empty on N also means a Method that
  somehow said Insert would have nothing to insert.
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
	<xsl:param name="decisionAtom" select="'atom3'"/>

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
