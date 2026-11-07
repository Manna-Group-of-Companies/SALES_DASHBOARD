/** Sales manager: the team's pick lists, read only. Reps make them on the phone. */
import { useEffect, useState } from 'react';
import { listPickLists, type PickList } from '@/api/pickLists';
import { Alert, Card, Empty, Icon, Skeleton, Tabs } from '@/components/ui';
import { RefreshButton } from '@/components/common/RefreshButton';
import { PickListsTable } from './PickListsTable';
import { isPicked, matches } from './format';
import '@/components/layout/layout.css';
import './picklists.css';

type Show = 'all' | 'waiting' | 'picked';

export function SalesPickListsPage() {
  const [lists, setLists] = useState<PickList[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const [show, setShow] = useState<Show>('all');
  const [query, setQuery] = useState('');

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    listPickLists()
      .then((l) => live && setLists(l.filter((x) => x.status === 'Submitted')))
      .catch((e: unknown) => live && setError(e instanceof Error && e.message ? e.message : 'Could not load.'))
      .finally(() => live && setLoading(false));
    return () => {
      live = false;
    };
  }, [tick]);

  const found = lists.filter((l) => matches(l, query));
  const shown = show === 'picked' ? found.filter(isPicked) : show === 'waiting' ? found.filter((l) => !isPicked(l)) : found;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Pick Lists</div>
          <div className="tiny dim">View only</div>
        </div>
        <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
      </div>

      {error && <Alert tone="danger">{error}</Alert>}

      <Card flush>
        <div className="pl-tools">
          <Tabs<Show>
            tabs={[
              { id: 'all', label: 'All', count: found.length },
              { id: 'waiting', label: 'On pick list', count: found.filter((l) => !isPicked(l)).length },
              { id: 'picked', label: 'Picked', count: found.filter(isPicked).length },
            ]}
            active={show}
            onChange={setShow}
          />
          <div className="pl-tools__right">
            <label className="pl-search">
              <Icon name="search" size={15} />
              <input placeholder="Search" value={query} onChange={(e) => setQuery(e.target.value)} aria-label="Search" />
            </label>
          </div>
        </div>

        {loading && lists.length === 0 ? (
          <div className="pl-pad">
            <Skeleton height={120} />
          </div>
        ) : shown.length === 0 ? (
          <Empty title="No pick lists" />
        ) : (
          <PickListsTable lists={shown} />
        )}
      </Card>
    </div>
  );
}
