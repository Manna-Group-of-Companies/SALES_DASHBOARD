<?xml version="1.0" encoding="UTF-8"?>
<!--
  Step 3, the xform in front of each of its three B1 Object atoms (atom8 for
  Hi-Tech's invoice, atom10 for Manna Treads' goods receipt, atom12 for its
  delivery): hands the atom one document and nothing else. One file, three
  copies in the package, differing only in $part (Inv, Grpo, Dn) - the build
  sets it in each copy.

  As steps 1 and 2: the BO's contents only, without AdmInfo, because the B1
  Object atom wraps the payload in its own BOM/BO/AdmInfo; and empty when the
  decision said N, when the atom's Method is a read that ignores the payload.
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
	<xsl:param name="decisionAtom" select="'atom7'"/>
	<xsl:param name="part" select="'Inv'"/>

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
