/**
 * The trip map.
 *
 * Leaflet with OpenStreetMap tiles, because the site's Google Settings has
 * `enable: 0` and no API key — a Google map would render blank. OSM needs no
 * key and no billing account.
 *
 * **The blue line is the shortest road route through the places the rep is
 * recorded as having visited. It is not the path they drove**, and the legend
 * says so on the screen rather than only here. There is no stored track to
 * draw: trips hold one or two GPS samples, hours apart. Drawing a line through
 * those and calling it a route would manufacture evidence.
 *
 * Routing comes from OSRM. When it is unavailable the line falls back to
 * straight segments between the same stops, drawn dashed so the difference is
 * visible at a glance — a dashed line is obviously a simplification; a solid
 * one would quietly overstate what is known.
 */

import { useEffect, useRef, useState } from 'react';
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';
import type { Waypoint } from '@/domain/geo';
import { boundsOf, pathKm, routeOf } from '@/domain/geo';
import './trip-map.css';

/**
 * Public OSRM. Swap for a self-hosted instance in `VITE_OSRM_URL` before this
 * carries real weight — the demo server is explicitly not for production and
 * will rate-limit.
 */
const OSRM = (import.meta.env.VITE_OSRM_URL as string | undefined) ?? 'https://router.project-osrm.org';

type RouteState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'road'; coords: [number, number][]; km: number }
  | { status: 'straight'; reason: string };

/** Marker colours by what the point actually is. */
const PIN: Record<Waypoint['kind'], { colour: string; radius: number }> = {
  start: { colour: '#1b7f3b', radius: 9 },
  visit: { colour: '#1a56a8', radius: 7 },
  end: { colour: '#b3261e', radius: 9 },
  gps: { colour: '#8a6100', radius: 5 },
};

export function TripMap({
  waypoints,
  onRoadDistance,
}: {
  waypoints: Waypoint[];
  /** Reported upward so the distance check can use the road figure. */
  onRoadDistance?: (km: number | undefined) => void;
}) {
  const host = useRef<HTMLDivElement | null>(null);
  const map = useRef<L.Map | null>(null);
  const layer = useRef<L.LayerGroup | null>(null);
  const [route, setRoute] = useState<RouteState>({ status: 'idle' });

  const stops = routeOf(waypoints);

  // ------------------------------------------------------------- routing ---
  useEffect(() => {
    let live = true;
    if (stops.length < 2) {
      setRoute({ status: 'straight', reason: 'Fewer than two known places.' });
      onRoadDistance?.(undefined);
      return;
    }

    setRoute({ status: 'loading' });
    // OSRM takes lng,lat — the reverse of Leaflet. Getting this backwards puts
    // Kerala in Somalia and the request simply fails to route.
    const path = stops.map((w) => `${w.longitude},${w.latitude}`).join(';');
    const url = `${OSRM}/route/v1/driving/${path}?overview=full&geometries=geojson`;

    fetch(url)
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`OSRM ${r.status}`))))
      .then((data) => {
        if (!live) return;
        const leg = data?.routes?.[0];
        if (!leg?.geometry?.coordinates?.length) throw new Error('no route returned');
        const coords: [number, number][] = leg.geometry.coordinates.map(
          ([lng, lat]: [number, number]) => [lat, lng],
        );
        const km = Math.round((leg.distance / 1000) * 100) / 100;
        setRoute({ status: 'road', coords, km });
        onRoadDistance?.(km);
      })
      .catch((e: unknown) => {
        if (!live) return;
        setRoute({
          status: 'straight',
          reason: e instanceof Error ? e.message : 'routing unavailable',
        });
        onRoadDistance?.(undefined);
      });

    return () => {
      live = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [JSON.stringify(stops.map((s) => [s.latitude, s.longitude]))]);

  // ---------------------------------------------------------------- draw ---
  useEffect(() => {
    if (!host.current) return;

    if (!map.current) {
      map.current = L.map(host.current, { scrollWheelZoom: false });
      L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
        attribution: '&copy; OpenStreetMap contributors',
        maxZoom: 19,
      }).addTo(map.current);
      layer.current = L.layerGroup().addTo(map.current);
    }

    const group = layer.current!;
    group.clearLayers();

    if (!waypoints.length) return;

    // The route line first, so markers sit on top of it.
    if (route.status === 'road') {
      L.polyline(route.coords, { color: '#1a56a8', weight: 5, opacity: 0.85 }).addTo(group);
    } else if (stops.length >= 2) {
      L.polyline(
        stops.map((w) => [w.latitude, w.longitude] as [number, number]),
        { color: '#1a56a8', weight: 3, opacity: 0.7, dashArray: '7 7' },
      ).addTo(group);
    }

    let stopNo = 0;
    for (const w of waypoints) {
      const pin = PIN[w.kind];
      if (w.kind === 'visit') stopNo += 1;
      const marker = L.circleMarker([w.latitude, w.longitude], {
        radius: pin.radius,
        color: '#fff',
        weight: 2,
        fillColor: pin.colour,
        fillOpacity: 1,
      }).addTo(group);
      const when = w.at ? `<br><span class="tm__when">${w.at.slice(11, 16)}</span>` : '';
      const label = w.kind === 'visit' ? `${stopNo}. ${w.label}` : w.label;
      marker.bindPopup(`<b>${label}</b>${when}`);
    }

    const b = boundsOf(waypoints);
    if (b) map.current.fitBounds(b, { padding: [28, 28], maxZoom: 15 });
  }, [waypoints, route]);

  // Leaflet measures the container on creation; inside a tab or a card that
  // was hidden it computes zero and renders a grey box until nudged.
  useEffect(() => {
    const t = window.setTimeout(() => map.current?.invalidateSize(), 120);
    return () => window.clearTimeout(t);
  }, [waypoints]);

  useEffect(
    () => () => {
      map.current?.remove();
      map.current = null;
    },
    [],
  );

  const straightKm = pathKm(stops);

  return (
    <div className="tm">
      <div className="tm__canvas" ref={host} />

      <div className="tm__legend">
        <span>
          <i className="tm__dot" style={{ background: PIN.start.colour }} /> Punched in
        </span>
        <span>
          <i className="tm__dot" style={{ background: PIN.visit.colour }} /> Shop visited
        </span>
        <span>
          <i className="tm__dot" style={{ background: PIN.end.colour }} /> Punched out
        </span>
        <span>
          <i className="tm__dot" style={{ background: PIN.gps.colour }} /> GPS sample
        </span>
      </div>

      <p className="note tm__caveat">
        {route.status === 'loading' && 'Tracing roads…'}
        {route.status === 'road' && (
          <>
            The blue line is the <b>shortest road route</b> through the {stops.length} places this
            rep is recorded as having visited — {route.km} km. It is <b>not</b> the path they drove;
            no such track is stored. Treat it as the least they could have driven.
          </>
        )}
        {route.status === 'straight' && (
          <>
            Road tracing is unavailable ({route.reason}), so the dashed line joins the stops in
            straight lines — {straightKm} km. Real roads are always longer, so this is a floor
            beneath the floor.
          </>
        )}
      </p>
    </div>
  );
}
