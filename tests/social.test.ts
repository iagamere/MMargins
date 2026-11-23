import { describe, expect, test } from 'bun:test';
import { followOf, relationOf, requestWith } from '../src/lib/social';
import type { Relationships, Subscription } from '../src/lib/online';

const p = (id: string) => ({ id, handle: id, display_name: id, bio: '', since: 'x' });
const rel: Relationships = {
  friends: [p('f1')],
  incoming: [{ ...p('i1'), request_id: 'ri1' }],
  outgoing: [{ ...p('o1'), request_id: 'ro1' }],
  blocked: [p('b1')],
};
const sub = (type: Subscription['target_type'], id: string): Subscription => ({ id: `s-${id}`, target_type: type, target_id: id, muted: false, created_at: 'x', available: true, target_name: 'n', owner_handle: 'h', owner_name: 'H' });

describe('social helpers', () => {
  test('relationOf picks the right state', () => {
    expect(relationOf(rel, 'f1', 'me')).toBe('friend');
    expect(relationOf(rel, 'i1', 'me')).toBe('incoming');
    expect(relationOf(rel, 'o1', 'me')).toBe('outgoing');
    expect(relationOf(rel, 'x', 'me')).toBe('none');
    expect(relationOf(rel, 'me', 'me')).toBe('self');
    expect(relationOf(null, 'f1', 'me')).toBe('none');
    expect(relationOf(rel, 'f1', null)).toBe('friend');
  });
  test('requestWith returns the request id and its direction', () => {
    expect(requestWith(rel, 'i1')).toEqual({ id: 'ri1', direction: 'incoming' });
    expect(requestWith(rel, 'o1')).toEqual({ id: 'ro1', direction: 'outgoing' });
    expect(requestWith(rel, 'f1')).toBeNull();
    expect(requestWith(null, 'i1')).toBeNull();
  });
  test('followOf matches the type AND the id', () => {
    const subs = [sub('library', 'a'), sub('shelf', 'a')];
    expect(followOf(subs, 'library', 'a')?.id).toBe('s-a');
    expect(followOf(subs, 'shelf', 'b')).toBeUndefined();
    expect(followOf(null, 'library', 'a')).toBeUndefined();
    expect(followOf([sub('shelf', 'z')], 'library', 'z')).toBeUndefined();
  });
});
