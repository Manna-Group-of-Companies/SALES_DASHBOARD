"""Builds Z.erpinv.zip, the B1if package for step 5, for Scenarios -> Import.

    python sap-b1if/step5-invoice/build_package.py

Same shape as the team's own Z.erpcust / Z.erpstock packages (exported
10 Nov 2026), whose step files are kept in package-template/: atom1 builds the
statement, atom2 (Call SQL, SysId 0010000119 = Manna Treads) runs it, atom3
turns the rows into the JSON body, atom0 is the final xform. As in Z.erpcust
the HTTP call is added by hand after atom3 in B1if, posting
Payload[@id='atom3']/Http/Body to Http/Endpoint on the ERPNext HTTP system.

Two steps, one per event:
    Z.erpinvar   B1 event, object 13 (A/R invoice)
    Z.erpinvpay  B1 event, object 24 (incoming payment)

No credentials are in any file here: the ERPNext key lives in B1if's SLD.
"""

import datetime
import io
import os
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
TPL = os.path.join(HERE, "package-template")
OUT = os.path.join(HERE, "..", "exports", "Z.erpinv.zip")

PAC = "Z.erpinv"
STEPS = [("Z.erpinvar", "13"), ("Z.erpinvpay", "24")]
DESIGN = "com.sap.b1i.vplatform.scenarios.design"


def read(name):
    with open(os.path.join(TPL, name), encoding="utf-8") as f:
        return f.read()


def step_files(step, obj):
    bfd = read("vBIU.bfd").replace("Z.erpcustbp", step)
    xml = read("vBIU.xml").replace('Id="Z.erpcustbp"', f'Id="{step}"')
    xml = xml.replace('SId="Z.erpcust"', f'SId="{PAC}"')
    xml = xml.replace("<obj>2</obj>", f"<obj>{obj}</obj>")
    # The team's vVar.xsl still names the step and package it was first copied
    # from (Z.mannaicmtpo in Z.mannaic); here it names this one.
    var = read("vVar.xsl").replace("Z.mannaicmtpo", step).replace(">Z.mannaic<", f">{PAC}<")
    with open(os.path.join(HERE, "atom1.xsl"), encoding="utf-8") as f:
        a1 = f.read().replace("@OBJTYPE@", obj)
    with open(os.path.join(HERE, "atom3.xsl"), encoding="utf-8") as f:
        a3 = f.read()
    assert f"<obj>{obj}</obj>" in xml and step in bfd, "template did not take the step"
    return {
        "vBIU.bfd": bfd,
        "vBIU.xml": xml,
        "vVar.xsl": var,
        "atom0.xsl": read("atom0.xsl"),
        "atom1.xsl": a1,
        "atom3.xsl": a3,
    }


def main():
    ts = datetime.datetime.now().strftime("%Y/%m/%d %H:%M:%S")
    ident = ('<?xml version="1.0" encoding="UTF-8"?><b1ifident xmlns:bfa="urn:com.sap.b1i.bizprocessor:bizatoms">'
             f"<id>{PAC}</id><type>vPac</type><ver>1.0.0</ver></b1ifident>")
    biu_list = "".join(f'<vBIU Id="{s}"></vBIU>' for s, _ in STEPS)
    vpac = ('<?xml version="1.0" encoding="UTF-8"?><vPac xmlns:bfa="urn:com.sap.b1i.bizprocessor:bizatoms" '
            'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns="urn:com.sap.b1i.vplatform:entity" '
            'xsi:schemaLocation="urn:com.sap.b1i.vplatform:entity ../../com.sap.b1i.vplatform.repository/xsd/vPlatform.xsd" '
            f'Id="{PAC}" Vendor="" Version="1.0.0" Timestamp="{ts}" Authentication="" BizArea="ERPNext" xmlproc="">'
            "<desc>Manna Treads A/R invoices and incoming payments -&gt; ERPNext SAP Invoice (manna_sap_invoice_sync)</desc>"
            f"<vBIUList>{biu_list}</vBIUList></vPac>")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("b1ifident/b1ifident/b1ifident.xml", ident)
        z.writestr(f"{DESIGN}/vPac.{PAC}/vPac.xml", vpac)
        for step, obj in STEPS:
            for name, text in step_files(step, obj).items():
                z.writestr(f"{DESIGN}/vBIU.{step}/{name}", text)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(buf.getvalue())
    print(f"wrote {os.path.normpath(OUT)}")


if __name__ == "__main__":
    main()
