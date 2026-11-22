import { describe, expect, test } from 'bun:test';
import { effectiveBookMode, effectiveShelfMode, isLoosening } from '../src/lib/access';

describe('access helpers', () => {
  test('a shelf inherits the library default', () => {
    expect(effectiveShelfMode('inherit', 'friends')).toBe('friends');
    expect(effectiveShelfMode('public', 'private')).toBe('public');
  });
  test('loosening means more people can see it', () => {
    expect(isLoosening('private', 'friends')).toBe(true);
    expect(isLoosening('friends', 'password')).toBe(true);
    expect(isLoosening('password', 'public')).toBe(true);
    expect(isLoosening('private', 'private')).toBe(false);
    expect(isLoosening('public', 'private')).toBe(false);
  });
  test('a book: own mode wins, else strictest shelf, else library default', () => {
    expect(effectiveBookMode('public', ['private'], 'private')).toBe('public');
    expect(effectiveBookMode('inherit', ['public', 'friends'], 'private')).toBe('friends');
    expect(effectiveBookMode('inherit', ['public', 'password'], 'private')).toBe('password');
    expect(effectiveBookMode('inherit', [], 'friends')).toBe('friends');
  });
});
