# Runs every test_*.py beside this file without pytest (it is not installed here).
#   python run_tests.py
import glob, importlib, os, sys, traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
total = bad = 0
for path in sorted(glob.glob(os.path.join(HERE, "test_*.py"))):
	mod = importlib.import_module(os.path.basename(path)[:-3])
	names = [n for n in dir(mod) if n.startswith("test_")]
	failed = 0
	for n in names:
		try:
			getattr(mod, n)()
		except Exception:
			failed += 1
			print("FAIL", mod.__name__, n)
			traceback.print_exc()
	print("%-28s %2d passed%s" % (mod.__name__, len(names) - failed, ", %d FAILED" % failed if failed else ""))
	total += len(names)
	bad += failed
print("%d tests, %d failed" % (total, bad))
sys.exit(1 if bad else 0)
