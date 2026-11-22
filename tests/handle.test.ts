import { describe, expect, test } from 'bun:test';
import { handleProblem, normalizeHandle } from '../src/lib/handle';

describe('handle rules (mirror of the database constraint)', () => {
  test('normalises', () => {
    expect(normalizeHandle('  @Alice ')).toBe('alice');
  });
  test('accepts valid handles', () => {
    for (const h of ['abc', 'a.b', 'a_b', 'user.name_1', 'x'.repeat(30), '0day']) expect(handleProblem(h)).toBeNull();
  });
  test('rejects bad ones', () => {
    expect(handleProblem('')).toBe('empty');
    expect(handleProblem('ab')).toBe('short');
    expect(handleProblem('x'.repeat(31))).toBe('long');
    expect(handleProblem('has space')).toBe('chars');
    expect(handleProblem('عربي')).toBe('chars');
    expect(handleProblem('_abc')).toBe('edges');
    expect(handleProblem('abc.')).toBe('edges');
    expect(handleProblem('a..b')).toBe('repeat');
    expect(handleProblem('a._b')).toBe('repeat');
    expect(handleProblem('Admin')).toBe('reserved');
  });
  test('matches the SQL regex exactly on a sample', () => {
    const sql = /^[a-z0-9][a-z0-9_.]{1,28}[a-z0-9]$/;
    for (const h of ['abc', 'ab', 'a-b', 'a.b.c', 'a__b', 'a.', '.a', 'x'.repeat(30), 'x'.repeat(31)]) {
      const clientOk = handleProblem(h) === null;
      const sqlOk = sql.test(h) && !/[_.]{2}/.test(h);
      expect(clientOk).toBe(sqlOk);
    }
  });
});
