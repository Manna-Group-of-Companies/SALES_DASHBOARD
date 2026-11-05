<?xml version="1.0" encoding="UTF-8"?>
<!--
  Step 1, the xform B1if puts in front of the B1 Object atom ("Predecessor
  Transformation for b1object Atom", atom6 on the server): hands the B1 Object
  atom the purchase order and nothing else.

  The B1 Object atom sends whatever this payload holds to the DI API, so it is
  only the BOM final.xsl built. It runs inside the branch's path, which only
  runs when final.xsl said Make = Y; with no BOM there it writes nothing, so a
  path condition that ever let a refusal through still makes no order.
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
				<vpf:Payload Role="X" id="{$atom}">
					<xsl:copy-of select="/vpf:Msg/vpf:Body/vpf:Payload[@id=$decisionAtom]/Decision[Make='Y']/BOM"/>
				</vpf:Payload>
			</vpf:Body>
		</vpf:Msg>
	</xsl:template>
</xsl:stylesheet>
