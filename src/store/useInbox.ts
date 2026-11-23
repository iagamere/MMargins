import { create } from 'zustand';
import { amIModerator, fetchUnreadCount, hasSession, onlineConfigured } from '../lib/online';

interface InboxState {
  unread: number;
  /** null = not asked yet */
  moderator: boolean | null;
  /** refreshes the unread badge and (once per session) whether this person is a moderator; never throws */
  refresh(): Promise<void>;
  setUnread(n: number): void;
  reset(): void;
}

export const useInbox = create<InboxState>((set, get) => ({
  unread: 0,
  moderator: null,

  async refresh() {
    if (!onlineConfigured || !hasSession()) return;
    try {
      set({ unread: await fetchUnreadCount() });
    } catch { /* offline: keep the last number */ }
    if (get().moderator === null) {
      try {
        set({ moderator: await amIModerator() });
      } catch { /* try again next time */ }
    }
  },
  setUnread(n) { set({ unread: Math.max(0, n) }); },
  reset() { set({ unread: 0, moderator: null }); },
}));
