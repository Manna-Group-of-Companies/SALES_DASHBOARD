/** Whether a tab is running an older build than the site now serves. */
import { describe, expect, it } from 'vitest';
import { isNewBuild, runningBuild, servedBuild } from '../newBuild';

const INDEX = '<script type="module" crossorigin src="/assets/index-CnorDnBn.js"></script>';

describe('which build', () => {
  it("reads the entry script from the site's index.html", () => {
    expect(servedBuild(INDEX)).toBe('/assets/index-CnorDnBn.js');
  });

  it('reads the entry script this tab was started from', () => {
    const doc = {
      querySelectorAll: () => [
        { src: 'https://sales.mannarubber.com/assets/xlsx-CkFp8p6R.js' },
        { src: 'https://sales.mannarubber.com/assets/index-V8aGKeor.js' },
      ],
    } as unknown as Document;
    expect(runningBuild(doc)).toBe('/assets/index-V8aGKeor.js');
  });

  it('a different entry script is a new build', () => {
    expect(isNewBuild('/assets/index-V8aGKeor.js', '/assets/index-CnorDnBn.js')).toBe(true);
  });

  it('the same one is not', () => {
    expect(isNewBuild('/assets/index-CnorDnBn.js', '/assets/index-CnorDnBn.js')).toBe(false);
  });

  it('an unreadable answer (offline, an error page) is never a new build', () => {
    expect(isNewBuild('/assets/index-CnorDnBn.js', servedBuild('<html>502</html>'))).toBe(false);
    expect(isNewBuild(null, '/assets/index-CnorDnBn.js')).toBe(false);
  });
});
