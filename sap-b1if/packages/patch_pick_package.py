# Puts step 3's current pick-list query and decision into an exported
# Z.mannaicpk (or Z.LIVEmannaicpk).
#
#     python patch_pick_package.py "<the exported pick package zip>"
#     -> writes "<same name> - patched.zip" beside it, to import back
#
# Replaces two atoms, each found by its content, with the repo's files:
#   the query    the .xsl that reads FROM OPKL K       <- ../step3-pick/sql-ht.xsl
#   the decision the .xsl with the "fifo" batch template <- ../step3-pick/final.xsl
# Everything else is copied byte for byte, entry names included: B1if exports
# some with backslashes and rejects a zip whose names were "fixed" (5 Nov
# 2026). B1if adds its own variables to an atom it exports; the repo's file
# without them imports and runs (Z.mannaicpk, 10 Nov 2026).
#
# History: 9 Nov 2026 the confirmed-pick-list rule (OPKL.U_Confirmed); 16 Nov
# 2026 the store's Actual kg (PKL1.U_ActualKg) and the over-weight limit.
# Import it only after the company has both fields: the query names them and
# fails every minute without them.
import os, sys, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))


def step_file(name):
	# Beside it in the Downloads copy, one folder up in the repo.
	return open(next(p for p in (os.path.join(HERE, "step3-pick", name), os.path.join(HERE, "..", "step3-pick", name)) if os.path.exists(p)), "rb").read()


ATOMS = [("the pick-list query", b"FROM OPKL K", step_file("sql-ht.xsl")), ("the decision", b"name=\"fifo\"", step_file("final.xsl"))]


def main(src):
	z = zipfile.ZipFile(src)
	xsl = [i for i in z.infolist() if i.filename.lower().endswith(".xsl")]
	swap = {}
	for what, mark, new in ATOMS:
		hits = [i for i in xsl if mark in z.read(i)]
		if len(hits) != 1:
			sys.exit("%s: %d .xsl files hold %s, expected 1 - is it the pick package export? Send me the zip" % (src, len(hits), what))
		swap[hits[0].filename] = new
		print("%s = %s" % (what, hits[0].filename))
	dest = os.path.splitext(src)[0] + " - patched.zip"
	out = zipfile.ZipFile(dest, "w")
	for i in z.infolist():
		out.writestr(i, swap.get(i.filename, z.read(i)))
	out.close()
	print("->", dest)


if __name__ == "__main__":
	if len(sys.argv) != 2:
		sys.exit("usage: python patch_pick_package.py <exported pick package zip>")
	main(sys.argv[1])
