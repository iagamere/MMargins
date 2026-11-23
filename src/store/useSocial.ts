import { create } from 'zustand';
import { OnlineError, fetchRelationships, fetchSubscriptions, hasSession, onlineConfigured, type OnlineErrorCode, type Relationships, type Subscription } from '../lib/online';

interface SocialState {
  rel: Relationships | null;
  subs: Subscription[] | null;
  status: 'idle' | 'loading' | 'ready' | 'error';
  error: OnlineErrorCode | null;
  /** (re)loads friends, requests, blocks and subscriptions. Safe to call any time; never throws. */
  load(): Promise<void>;
  reset(): void;
}

let inflight: Promise<void> | null = null;

export const useSocial = create<SocialState>((set, get) => ({
  rel: null,
  subs: null,
  status: 'idle',
  error: null,

  load() {
    if (!onlineConfigured || !hasSession()) return Promise.resolve();
    // two screens asking at once share one round trip
    inflight ??= (async () => {
      set({ status: get().rel ? 'ready' : 'loading', error: null });
      try {
        const [rel, subs] = await Promise.all([fetchRelationships(), fetchSubscriptions()]);
        set({ rel, subs, status: 'ready' });
      } catch (e) {
        set({ status: 'error', error: e instanceof OnlineError ? e.code : 'unknown' });
      } finally {
        inflight = null;
      }
    })();
    return inflight;
  },

  reset() {
    set({ rel: null, subs: null, status: 'idle', error: null });
  },
}));
