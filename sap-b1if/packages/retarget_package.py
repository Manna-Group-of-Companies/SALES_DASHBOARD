# Points a B1if package at other SLD systems: the TEST companies' ids swapped for the live ones (13 Nov 2026).
#
#     python retarget_package.py --manna <id> --hitech <id> --erpnext <id> <package.zip> [<package.zip> ...]
#     -> writes each as "<same name> - live.zip" in out-live/ beside this file, to import on the SAP server
#
# Every package here was built or exported against the TEST systems, and names them by SLD id inside its
# atoms (Call SQL, the B1 Object calls, the HTTP call):
#
#     0010000119  TEST_MANNA_TREADS        --manna    the live Manna Treads system's id
#     0010000120  TEST_HITECH_PRETREADS    --hitech   the live Hi-Tech system's id
#     0010000121  ERPNEXT_LOCAL            --erpnext  the HTTP system for the live ERPNext
#
# Read the three live ids off the SLD (B1if console -> SLD -> the system -> SysId); they are not known here.
# Nothing else in a package names a company - no database name, no login - so the ids are the whole change.
# Works on the zips in out/ and on a package exported from B1if (Z.mannaic, Z.mannaicpk) alike.
#
# All three swaps happen in one pass, so a live id that happens to equal another system's TEST id is not
# swapped twice. Every entry is otherwise copied byte for byte, names included: B1if exports some with
# backslashes and rejects a zip whose names were "fixed" (5 Nov 2026).
#
# It refuses rather than guess: an id that is not ten digits, a package that names a TEST system no live id
# was given for, a source that is already a "- live" zip. What it cannot check is that an id is the RIGHT
# system - a package pointed at the wrong company writes purchase orders there. Read the summary it prints.
#
# The same package name cannot be on a B1if server twice: importing a live zip under the TEST name REPLACES
# the TEST one, and the TEST companies stop being followed. To keep both, give the live copy its own names:
#
#     --rename Z.mannaic=Z.LIVEmannaic      (and --rename Z.erp=Z.LIVEerp for the six data packages)
#
# The text before "=" is swapped for the text after it wherever it stands - in every entry's name and
# content - so one prefix renames a package and all its steps together (Z.mannaic, Z.mannaicpk,
# Z.mannaicmtpo, Z.mannaicpick -> Z.LIVEmannaic...). A package holds its names as plain text (its ident file,
# vPac.xml, each step's vBIU.xml and flow), which is how build_packages.py made Z.erpcust out of Z.mannaic's
# layout in the first place. Give the prefix every name in the zip shares, or a step is left with its TEST
# name and the import collides with the TEST package after all: the summary lists the names it ends with.
import argparse, os, re, sys, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
TEST = {"manna": "0010000119", "hitech": "0010000120", "erpnext": "0010000121"}
LABEL = {"manna": "Manna Treads", "hitech": "Hi-Tech Pretreads", "erpnext": "ERPNext (HTTP)"}
ID = re.compile(rb"00100001(?:19|20|21)")


def plan(given):
	"""{TEST id (bytes): live id (bytes)} for the ids given; exits on one that is not a SysId."""
	swap = {}
	for key, new in given.items():
		if new is None:
			continue
		if not re.fullmatch(r"\d{10}", new):
			sys.exit("--%s %s is not an SLD SysId (ten digits, like %s)" % (key, new, TEST[key]))
		swap[TEST[key].encode()] = new.encode()
	if not swap:
		sys.exit("give at least one of --manna, --hitech, --erpnext")
	live = [v for v in swap.values()]
	if len(set(live)) != len(live):
		sys.exit("two systems were given the same id - each of Manna Treads, Hi-Tech and ERPNext is its own SLD system")
	return swap


def names_in(z):
	"""The package and step names a zip holds, from its entry paths."""
	return sorted({part[5:] for i in z.infolist() for part in re.split(r"[/\\]", i.filename) if part[:5] in ("vPac.", "vBIU.") and part[5:] not in ("xml", "bfd")})


def retarget(src, swap, out_dir, renames=()):
	"""Writes the retargeted zip; returns (dest, {TEST id: times swapped}, names it ends with)."""
	if os.path.splitext(os.path.basename(src))[0].endswith(" - live"):
		sys.exit("%s is already a live zip - give the TEST one" % src)
	z = zipfile.ZipFile(src)
	found = {}
	for i in z.infolist():
		for m in ID.findall(z.read(i)):
			found[m] = found.get(m, 0) + 1
	missing = sorted(k.decode() for k in found if k not in swap)
	if missing:
		names = ", ".join("--%s (%s)" % (key, tid) for key, tid in TEST.items() if tid in missing)
		sys.exit("%s names a TEST system with no live id given: %s - it would go live half pointed at TEST" % (os.path.basename(src), names))
	if not found:
		sys.exit("%s names no system at all - is it a B1if package?" % os.path.basename(src))
	os.makedirs(out_dir, exist_ok=True)
	dest = os.path.join(out_dir, os.path.splitext(os.path.basename(src))[0] + " - live.zip")
	out = zipfile.ZipFile(dest, "w")
	for i in z.infolist():
		data = ID.sub(lambda m: swap[m.group(0)], z.read(i))
		name = i.filename
		for old, new in renames:
			data = data.replace(old.encode(), new.encode())
			name = name.replace(old, new)
		if name != i.filename:
			# A copy of the entry's own record with only the name changed, so dates, flags and method stay B1if's.
			j = zipfile.ZipInfo(name, i.date_time)
			j.compress_type, j.external_attr, j.create_system, j.comment, j.extra = i.compress_type, i.external_attr, i.create_system, i.comment, i.extra
			i = j
		out.writestr(i, data)
	out.close()
	# Read it back: no TEST id left that was meant to go, and the same entries in the same order.
	back = zipfile.ZipFile(dest)
	want = [i.filename for i in z.infolist()]
	for old, new in renames:
		want = [n.replace(old, new) for n in want]
	if [i.filename for i in back.infolist()] != want:
		sys.exit("%s: the entries changed - not usable" % dest)
	before = set(names_in(z))
	after = names_in(back)
	if renames:
		kept = sorted(set(after) & before)
		if kept:
			sys.exit("%s: still named as on TEST: %s - give --rename the prefix all its names share" % (os.path.basename(src), ", ".join(kept)))
		for old, new in renames:
			if any(old.encode() in back.read(i) for i in back.infolist()):
				sys.exit("%s: '%s' is still inside after renaming - not usable" % (dest, old))
	left = sum(len(ID.findall(back.read(i))) for i in back.infolist())
	expected = sum(n for k, n in found.items() if swap[k] in TEST_BYTES)
	if left != expected:
		sys.exit("%s: %d TEST id(s) still inside - not usable" % (dest, left - expected))
	return dest, found, after


TEST_BYTES = {v.encode() for v in TEST.values()}


def main():
	p = argparse.ArgumentParser(description="Point B1if packages at the live SLD systems.")
	for key in TEST:
		p.add_argument("--" + key, help="SysId of the live %s system (TEST: %s)" % (LABEL[key], TEST[key]))
	p.add_argument("--out", default=os.path.join(HERE, "out-live"), help="folder for the live zips (default: out-live beside this file)")
	p.add_argument("--rename", action="append", default=[], metavar="OLD=NEW", help="swap OLD for NEW in every name, to keep the TEST package beside the live one (Z.mannaic=Z.LIVEmannaic)")
	p.add_argument("zips", nargs="+", help="package zips built or exported against the TEST systems")
	a = p.parse_args()
	renames = []
	for r in a.rename:
		old, _, new = r.partition("=")
		if not re.fullmatch(r"Z\.[A-Za-z0-9]+", old) or not re.fullmatch(r"Z\.[A-Za-z0-9]+", new):
			sys.exit("--rename %s: both sides must be a name in B1if's Z namespace, like Z.mannaic=Z.LIVEmannaic" % r)
		if old in new:
			sys.exit("--rename %s: the new name holds the old one, so a second run would rename it again" % r)
		renames.append((old, new))
	swap = plan({key: getattr(a, key) for key in TEST})
	by_test = {v: k for k, v in TEST.items()}
	print("TEST -> live:")
	for old, new in swap.items():
		print("  %s  %-18s -> %s" % (old.decode(), LABEL[by_test[old.decode()]], new.decode()))
	for src in a.zips:
		dest, found, names = retarget(src, swap, a.out, renames)
		print("%-34s %s  ->  %s" % (os.path.basename(src), ", ".join("%s x%d" % (LABEL[by_test[k.decode()]], n) for k, n in sorted(found.items())), dest))
		print("%-34s names: %s" % ("", ", ".join(names)))
	print("Import each on the SAP server." + (" The new names sit beside the TEST packages; nothing is replaced." if renames else " It replaces the TEST package of the same name."))


if __name__ == "__main__":
	main()
