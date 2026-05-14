import { describe, expect, it } from 'vitest';
import type { Project, ProjectSession } from '../types/app';
import { mergeProjectsPreservingLoadedSessions } from './useProjectsState';

const session = (id: string): ProjectSession => ({
  id,
  title: id,
});

const project = (
  name: string,
  sessions: ProjectSession[],
  total = sessions.length,
): Project => ({
  name,
  displayName: name,
  fullPath: `/tmp/${name}`,
  sessions,
  sessionMeta: {
    total,
    hasMore: sessions.length < total,
  },
});

describe('mergeProjectsPreservingLoadedSessions', () => {
  it('keeps already loaded sidebar sessions when a preview payload refreshes the project', () => {
    const previous = [
      project(
        'yanyk',
        [
          session('session-1'),
          session('session-2'),
          session('session-3'),
          session('session-4'),
          session('session-5'),
          session('session-6'),
          session('session-7'),
          session('session-8'),
        ],
        8,
      ),
    ];
    const refreshedPreview = [
      project(
        'yanyk',
        [
          session('session-1'),
          session('session-2'),
          session('session-3'),
          session('session-4'),
          session('session-5'),
        ],
        8,
      ),
    ];

    expect(
      mergeProjectsPreservingLoadedSessions(previous, refreshedPreview)[0].sessions?.map(
        (item) => item.id,
      ),
    ).toEqual([
      'session-1',
      'session-2',
      'session-3',
      'session-4',
      'session-5',
      'session-6',
      'session-7',
      'session-8',
    ]);
  });

  it('keeps fresh preview sessions first and caps preserved sessions to the known total', () => {
    const previous = [
      project(
        'yanyk',
        [
          session('old-1'),
          session('old-2'),
          session('old-3'),
          session('old-4'),
          session('old-5'),
          session('old-6'),
        ],
        6,
      ),
    ];
    const refreshedPreview = [
      project(
        'yanyk',
        [
          session('new-1'),
          session('old-1'),
          session('old-2'),
          session('old-3'),
          session('old-4'),
        ],
        6,
      ),
    ];

    expect(
      mergeProjectsPreservingLoadedSessions(previous, refreshedPreview)[0].sessions?.map(
        (item) => item.id,
      ),
    ).toEqual(['new-1', 'old-1', 'old-2', 'old-3', 'old-4', 'old-5']);
  });
});
