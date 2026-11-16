<?xml version="1.0" encoding="UTF-8"?>
<!--
  Step 6 (delivery dates), the xform in front of each of its two B1 Object
  atoms (atom6 for Manna Treads' sales order, atom8 for its purchase order):
  hands the atom one document's update and nothing else. One file, two copies
  in the package, differing only in $part (So, Po) - the build sets it.

  As steps 1 to 3: the BO's contents only, without AdmInfo, because the B1
  Object atom wraps the payload in its own BOM/BO/AdmInfo; and empty when that
  document has nothing to change, when the atom's Method is a read that
  ignores the payload.
-->
<xsl:stylesheet version="1.0"
	xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
	xmlns:vpf="urn:com.sap.b1i.vplatform:entity"
	xmlns:bfa="urn:com.sap.b1i.bizprocessor:bizatoms"
	bfa:force=""
	exclude-result-prefixes="vpf bfa">
	<xsl:output method="xml"/>
	<xsl:param name="atom"/>
	<!-- The decision atom (final.xsl), and which of its documents this copy hands on. -->
	<xsl:param name="decisionAtom" select="'atom5'"/>
	<xsl:param name="part" select="'So'"/>

	<xsl:template match="/">
		<vpf:Msg>
			<xsl:copy-of select="/vpf:Msg/@*"/>
			<xsl:copy-of select="/vpf:Msg/vpf:Header"/>
			<vpf:Body>
				<xsl:copy-of select="/vpf:Msg/vpf:Body/*"/>
				<vpf:Payload Role="X" id="{$atom}">
					<xsl:copy-of select="/vpf:Msg/vpf:Body/vpf:Payload[@id=$decisionAtom]/Decision[Make='Y']/*[local-name()=$part]/BOM/BO/*[local-name() != 'AdmInfo']"/>
				</vpf:Payload>
			</vpf:Body>
		</vpf:Msg>
	</xsl:template>
</xsl:stylesheet>
