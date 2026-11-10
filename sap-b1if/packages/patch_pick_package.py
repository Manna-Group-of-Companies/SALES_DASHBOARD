# Puts the confirmed-pick-list rule (9 Nov 2026) into an exported Z.mannaicpk.
#
#     python patch_pick_package.py "<the exported Z.mannaicpk zip>"
#     -> writes "<same name> - confirmed.zip" beside it, to import back
#
# Replaces the step's pick-list query atom - found by its content (it is the
# .xsl that reads FROM OPKL K and does not yet ask for U_Confirmed) - with
# ../step3-pick/sql-ht.xsl. Everything else is copied byte for byte, entry
# names included: B1if exports some with backslashes and rejects a zip whose
# names were "fixed" (5 Nov 2026).
#
# Import it only after the field exists on that company's pick list
# (OPKL.U_Confirmed): the query names it and fails every minute without it.
import os, sys, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
# Beside it in the Downloads copy, one folder up in the repo.
NEW = open(next(p for p in (os.path.join(HERE, "step3-pick", "sql-ht.xsl"), os.path.join(HERE, "..", "step3-pick", "sql-ht.xsl")) if os.path.exists(p)), "rb").read()


def main(src):
	z = zipfile.ZipFile(src)
	hits = [i for i in z.infolist() if i.filename.lower().endswith(".xsl") and b"FROM OPKL K" in z.read(i)]
	if not hits:
		sys.exit("No pick-list query in %s - is it the Z.mannaicpk export?" % src)
	if len(hits) > 1:
		sys.exit("More than one .xsl reads OPKL: %s - send me the zip" % ", ".join(i.filename for i in hits))
	if b"U_Confirmed" in z.read(hits[0]):
		sys.exit("%s already asks for U_Confirmed - nothing to do" % hits[0].filename)
	dest = os.path.splitext(src)[0] + " - confirmed.zip"
	out = zipfile.ZipFile(dest, "w")
	for i in z.infolist():
		out.writestr(i, NEW if i.filename == hits[0].filename else z.read(i))
	out.close()
	print("replaced", hits[0].filename, "->", dest)


if __name__ == "__main__":
	if len(sys.argv) != 2:
		sys.exit(__doc__ if False else "usage: python patch_pick_package.py <Z.mannaicpk export zip>")
	main(sys.argv[1])
