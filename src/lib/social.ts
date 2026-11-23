import type { Relationships, Subscription, SubTarget } from './online';

export type Relation = 'self' | 'friend' | 'incoming' | 'outgoing' | 'none';

/** how the signed-in user stands with another user (pure: used to pick which buttons to show) */
export function relationOf(rel: Relationships | null, userId: string, myId: string | null | undefined): Relation {
  if (myId && userId === myId) return 'self';
  if (!rel) return 'none';
  if (rel.friends.some((p) => p.id === userId)) return 'friend';
  if (rel.incoming.some((p) => p.id === userId)) return 'incoming';
  if (rel.outgoing.some((p) => p.id === userId)) return 'outgoing';
  return 'none';
}

export const followOf = (subs: Subscription[] | null, type: SubTarget, id: string): Subscription | undefined =>
  subs?.find((s) => s.target_type === type && s.target_id === id);

/** the request id of an incoming / outgoing request with this user, if any */
export function requestWith(rel: Relationships | null, userId: string): { id: string; direction: 'incoming' | 'outgoing' } | null {
  const i = rel?.incoming.find((p) => p.id === userId);
  if (i) return { id: i.request_id, direction: 'incoming' };
  const o = rel?.outgoing.find((p) => p.id === userId);
  return o ? { id: o.request_id, direction: 'outgoing' } : null;
}
