/**
 * Product and €0 infrastructure limits shared by the UI and Edge Functions.
 * The database enforces the same values (supabase/migrations/*); limits.test.ts
 * fails if the two drift apart.
 */
export const MB = 1024 * 1024;

export const LIMITS = {
  username: { min: 3, max: 20, cooldownHours: 48, reservationDays: 30 },
  displayNameMax: 40,
  messageMaxChars: 4000,
  messageEditWindowMinutes: 15,
  maxPins: 3,
  groupMaxMembers: 32,
  snap: { minViewSeconds: 1, maxViewSeconds: 10, maxVideoSeconds: 60, replays: 1 },
  storySegmentMaxSeconds: 60,
  memoriesVideoMaxSeconds: 300,
  callMeshMaxParticipants: 4,
  bytes: {
    photo: 5 * MB,
    memoryPhoto: 10 * MB,
    shortVideo: 20 * MB,      // Snaps, Story segments, chat videos
    memoryVideo: 50 * MB,
    voice: 3 * MB,
    vaultBlob: 50 * MB,
  },
  memoriesQuotaBytes: 50 * MB,
  storageWarnings: [80, 90, 100] as const,
} as const;

export type MediaPurpose =
  | 'snap' | 'story' | 'chat' | 'memory_backup' | 'vault_backup' | 'profile' | 'group_icon';

export const PHOTO_MIME = ['image/jpeg', 'image/webp', 'image/png'] as const;
export const VIDEO_MIME = ['video/mp4', 'video/webm'] as const;
export const AUDIO_MIME = ['audio/webm', 'audio/mp4', 'audio/ogg'] as const;
