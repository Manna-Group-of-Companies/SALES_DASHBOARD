<?xml version="1.0" encoding="UTF-8"?>
<!--
  atom5: the request the Call HTTP atom (atom4) sends to ERPNext - the same
  file in all five steps. B1if's own template (9 Nov 2026) defines the shape:
  <call> with an optional <connect>, <pltype>, <payload> and <htta> headers.

  - No <connect>: host, port, path and the basic login (ERPNext's API key and
    secret) come from the step's SLD system, one per ERPNext endpoint, so no
    password is in any XSL and live is only a matter of re-pointing the SLD.
  - The body is atom3's JSON, sent as text (<bfa:io pltype="txt">) with
    Content-Type application/json.
  - The answer is taken back as text: ERPNext answers JSON, which B1if would
    otherwise try to read as XML and fail on. The Message Log shows it.
-->
<xsl:stylesheet version="1.0"
	xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
	xmlns:vpf="urn:com.sap.b1i.vplatform:entity"
	xmlns:bfa="urn:com.sap.b1i.bizprocessor:bizatoms"
	bfa:force=""
	exclude-result-prefixes="vpf">
	<xsl:output method="xml" encoding="UTF-8" indent="yes"/>
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
		<call xmlns="">
			<pltype>txt</pltype>
			<!-- The text must sit in B1if's own wrapper for non-XML content. Bare text
			     in <payload> is sent as an EMPTY body (Content-Length: 0, read off the
			     wire on 10 Nov 2026); of four shapes tried in one run, only this one
			     arrived. -->
			<payload><bfa:io pltype="txt"><xsl:value-of select="/vpf:Msg/vpf:Body/vpf:Payload[@id='atom3']/Http/Body"/></bfa:io></payload>
			<htta>
				<par id="httpheader.Content-Type" value="application/json"/>
				<par id="httpheader.Accept" value="application/json"/>
				<par id="htta.returnpltypeforce" value="txt"/>
			</htta>
		</call>
	</xsl:template>
</xsl:stylesheet>
