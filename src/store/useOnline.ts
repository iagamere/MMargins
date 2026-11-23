import { create } from 'zustand';
import { useSocial } from './useSocial';
import { useInbox } from './useInbox';
import { OnlineError, fetchMyProfile, hasSession, onlineConfigured, onlineSignOut, signInWithGoogleIdToken, type OnlineErrorCode, type OnlineProfile } from '../lib/online';

type Status = 'idle' | 'connecting' | 'ready' | 'error';

interface OnlineState {
  status: Status;
  /** null while loading, or when the user has not created a public profile yet (status 'ready') */
  profile: OnlineProfile | null;
  error: OnlineErrorCode | null;
  /** looks at the stored session and loads the profile. Safe to call any time; never throws. */
  connect(): Promise<void>;
  /** after the Google sign-in: swap the Google ID token for an online session */
  loginWithGoogleToken(idToken: string | null | undefined): Promise<void>;
  setProfile(p: OnlineProfile | null): void;
  reset(): Promise<void>;
}

const codeOf = (e: unknown): OnlineErrorCode => (e instanceof OnlineError ? e.code : 'unknown');

export const useOnline = create<OnlineState>((set, get) => ({
  status: 'idle',
  profile: null,
  error: null,

  async connect() {
    if (!onlineConfigured || get().status === 'connecting') return;
    if (!hasSession()) {
      set({ status: 'error', error: 'sessionExpired', profile: null });
      return;
    }
    set({ status: 'connecting', error: null });
    try {
      set({ profile: await fetchMyProfile(), status: 'ready' });
    } catch (e) {
      set({ status: 'error', error: codeOf(e) });
    }
  },

  async loginWithGoogleToken(idToken) {
    if (!onlineConfigured) return;
    set({ status: 'connecting', error: null });
    try {
      await signInWithGoogleIdToken(idToken ?? '');
      set({ profile: await fetchMyProfile(), status: 'ready' });
    } catch (e) {
      set({ status: 'error', error: codeOf(e) });
    }
  },

  setProfile(profile) {
    set({ profile });
  },

  async reset() {
    await onlineSignOut();
    useSocial.getState().reset();
    useInbox.getState().reset();
    set({ status: 'idle', profile: null, error: null });
  },
}));
