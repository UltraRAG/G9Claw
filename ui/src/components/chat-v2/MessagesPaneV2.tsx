import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import type { Dispatch, ReactNode, RefObject, SetStateAction } from 'react';
import { useTranslation } from 'react-i18next';
import { Activity, CheckCircle2, Loader2, Search, Wrench, XCircle } from 'lucide-react';
import type {
  ChatMessage,
  ClaudePermissionSuggestion,
  ClaudeWorkStatus,
  PermissionGrantResult,
} from '../chat/types/types';
import { isBackgroundTaskSession, type Project, type ProjectSession, type SessionProvider } from '../../types/app';
import { getIntrinsicMessageKey } from '../chat/utils/messageKeys';
import MessageRowV2 from './MessageRowV2';

type DiffLine = { type: string; content: string; lineNum: number };

type MessagesPaneV2Props = {
  scrollContainerRef: RefObject<HTMLDivElement>;
  onWheel: () => void;
  onTouchMove: () => void;
  isLoadingSessionMessages: boolean;
  sessionLoadError?: string | null;
  onRetrySessionLoad?: () => void;
  chatMessages: ChatMessage[];
  activityMessages?: ChatMessage[];
  visibleMessages: ChatMessage[];
  visibleMessageCount: number;
  isLoadingMoreMessages: boolean;
  hasMoreMessages: boolean;
  totalMessages: number;
  loadEarlierMessages: () => void;
  loadAllMessages: () => void;
  allMessagesLoaded: boolean;
  isLoadingAllMessages: boolean;
  provider: SessionProvider;
  selectedProject: Project | null;
  selectedSession: ProjectSession | null;
  createDiff: (oldStr: string, newStr: string) => DiffLine[];
  onFileOpen?: (filePath: string, diffInfo?: unknown) => void;
  onShowSettings?: () => void;
  onGrantToolPermission?: (
    suggestion: ClaudePermissionSuggestion,
  ) => PermissionGrantResult | null | undefined;
  autoExpandTools?: boolean;
  showRawParameters?: boolean;
  showThinking?: boolean;
  setInput: Dispatch<SetStateAction<string>>;
  // While the assistant is producing a response (request sent → `complete`
  // event), we render a small "working" pill at the bottom of the list so the
  // user always has a visible signal that the model is doing something —
  // streaming bubbles arrive in 100ms-buffered chunks and tool runs can sit
  // silent for a while, so without this the UI looks frozen.
  isAssistantWorking?: boolean;
  workingStatus?: ClaudeWorkStatus | null;
};

type RenderableMessageItem = {
  message: ChatMessage;
  originalIndex: number;
  processSummary?: ChatMessage | null;
  processDetailMessages?: ChatMessage[];
};

type KeyedRenderableMessageItem = RenderableMessageItem & {
  itemKey: string;
  renderIndex: number;
  estimatedHeight: number;
};

export type VirtualMessageWindow = {
  startIndex: number;
  endIndex: number;
  topPadding: number;
  bottomPadding: number;
  totalHeight: number;
};

type ActivitySummaryAttachment = {
  message: ChatMessage;
  originalIndex: number;
};

type MessageTurn = {
  start: number;
  end: number;
  summary: ActivitySummaryAttachment | null;
};

type BuildRenderableMessageItemsOptions = {
  isAssistantWorking?: boolean;
};

const MESSAGE_VIRTUALIZATION_THRESHOLD = 160;
const MESSAGE_WINDOW_OVERSCAN = 12;
const MESSAGE_GAP_PX = 32;

function getActivitySummaryKey(message: ChatMessage, index: number): string {
  return message.runId || message.id || `${message.startedAt || ''}-${message.endedAt || ''}-${index}`;
}

function clampNumber(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

function upperBound(values: number[], target: number): number {
  let low = 0;
  let high = values.length;
  while (low < high) {
    const mid = Math.floor((low + high) / 2);
    if (values[mid] <= target) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return low;
}

function getMessageTextLength(message: ChatMessage): number {
  const contentLength = typeof message.content === 'string' ? message.content.length : 0;
  const toolInputLength = typeof message.toolInput === 'string' ? message.toolInput.length : 0;
  const outputLength = typeof message.toolResult?.content === 'string' ? message.toolResult.content.length : 0;
  return contentLength + Math.min(toolInputLength + outputLength, 2400);
}

export function estimateMessageItemHeight(item: RenderableMessageItem): number {
  const textLength = getMessageTextLength(item.message);
  const roughLines = Math.ceil(textLength / 92);
  const baseHeight = item.message.type === 'user' ? 64 : 92;
  const processSummaryHeight = item.processSummary ? 58 : 0;
  const attachmentHeight = Array.isArray(item.message.attachments) && item.message.attachments.length > 0 ? 56 : 0;
  const imageHeight = Array.isArray(item.message.images) && item.message.images.length > 0 ? 180 : 0;
  const toolHeight = item.message.isToolUse || item.message.toolName ? 140 : 0;

  return clampNumber(
    baseHeight + roughLines * 20 + processSummaryHeight + attachmentHeight + imageHeight + toolHeight + MESSAGE_GAP_PX,
    72,
    720,
  );
}

export function getVirtualMessageWindow(
  itemHeights: number[],
  scrollTop: number,
  viewportHeight: number,
  overscan = MESSAGE_WINDOW_OVERSCAN,
): VirtualMessageWindow {
  if (itemHeights.length === 0) {
    return { startIndex: 0, endIndex: 0, topPadding: 0, bottomPadding: 0, totalHeight: 0 };
  }

  const prefixOffsets = [0];
  for (const height of itemHeights) {
    prefixOffsets.push(prefixOffsets[prefixOffsets.length - 1] + Math.max(1, height));
  }

  const totalHeight = prefixOffsets[prefixOffsets.length - 1];
  const safeScrollTop = clampNumber(Number.isFinite(scrollTop) ? scrollTop : 0, 0, totalHeight);
  const safeViewportHeight = Math.max(1, Number.isFinite(viewportHeight) && viewportHeight > 0
    ? viewportHeight
    : 900);
  const rawStart = Math.max(0, upperBound(prefixOffsets, safeScrollTop) - 1);
  const rawEnd = Math.min(itemHeights.length, upperBound(prefixOffsets, safeScrollTop + safeViewportHeight));
  const startIndex = Math.max(0, rawStart - overscan);
  const endIndex = Math.min(itemHeights.length, Math.max(startIndex + 1, rawEnd + overscan));

  return {
    startIndex,
    endIndex,
    topPadding: prefixOffsets[startIndex],
    bottomPadding: Math.max(0, totalHeight - prefixOffsets[endIndex]),
    totalHeight,
  };
}

function canHostProcessSummary(message: ChatMessage): boolean {
  return (
    message.type === 'assistant' &&
    !message.isAgentActivitySummary &&
    !message.isAgentActivity &&
    !message.isToolUse &&
    !message.isInteractivePrompt &&
    !message.isSubagentContainer &&
    !message.isTaskNotification &&
    !message.isThinking &&
    typeof message.content === 'string' &&
    message.content.trim().length > 0
  );
}

function isCollapsibleProcessMessage(message: ChatMessage): boolean {
  if (message.isAgentActivity || message.isAgentActivitySummary) {
    return false;
  }
  return message.type !== 'user';
}

function parseMessageTime(value: unknown): number | null {
  if (!value) return null;
  const parsed = Date.parse(String(value));
  return Number.isFinite(parsed) ? parsed : null;
}

function createMessageTurns(messages: ChatMessage[]): MessageTurn[] {
  if (messages.length === 0) {
    return [];
  }

  const starts: number[] = [];
  messages.forEach((message, index) => {
    if (message.type === 'user') {
      starts.push(index);
    }
  });

  if (starts.length === 0 || starts[0] > 0) {
    starts.unshift(0);
  }

  return starts.map((start, index) => ({
    start,
    end: starts[index + 1] ?? messages.length,
    summary: null,
  }));
}

function findTurnIndexByPosition(turns: MessageTurn[], index: number): number {
  return turns.findIndex((turn) => index >= turn.start && index < turn.end);
}

function findTurnIndexByTime(messages: ChatMessage[], turns: MessageTurn[], timestamp: number): number {
  let matchedIndex = -1;

  for (let turnIndex = 0; turnIndex < turns.length; turnIndex += 1) {
    const startMessage = messages[turns[turnIndex].start];
    if (startMessage?.type !== 'user') {
      continue;
    }

    const startTime = parseMessageTime(startMessage.timestamp);
    if (startTime == null) {
      continue;
    }

    if (startTime <= timestamp) {
      matchedIndex = turnIndex;
      continue;
    }

    if (startTime > timestamp) {
      break;
    }
  }

  return matchedIndex;
}

function getSummaryAnchorTime(summary: ChatMessage): number | null {
  return (
    parseMessageTime(summary.startedAt) ??
    parseMessageTime(summary.timestamp) ??
    parseMessageTime(summary.endedAt)
  );
}

function getSummarySortTime(summary: ChatMessage): number {
  return (
    parseMessageTime(summary.endedAt) ??
    parseMessageTime(summary.timestamp) ??
    parseMessageTime(summary.startedAt) ??
    0
  );
}

function isNewerSummary(
  next: ActivitySummaryAttachment,
  current: ActivitySummaryAttachment | null,
): boolean {
  if (!current) {
    return true;
  }
  const nextTime = getSummarySortTime(next.message);
  const currentTime = getSummarySortTime(current.message);
  if (nextTime !== currentTime) {
    return nextTime > currentTime;
  }
  return next.originalIndex > current.originalIndex;
}

function attachSummariesToTurns(messages: ChatMessage[], turns: MessageTurn[]): void {
  const summariesByKey = new Map<string, ActivitySummaryAttachment>();

  messages.forEach((message, originalIndex) => {
    if (message.isAgentActivitySummary) {
      summariesByKey.set(getActivitySummaryKey(message, originalIndex), { message, originalIndex });
    }
  });

  const summaries = Array.from(summariesByKey.values()).sort(
    (a, b) => a.originalIndex - b.originalIndex,
  );

  for (const summary of summaries) {
    const anchorTime = getSummaryAnchorTime(summary.message);
    const turnIndexFromTime = anchorTime == null ? -1 : findTurnIndexByTime(messages, turns, anchorTime);
    const turnIndex = turnIndexFromTime >= 0
      ? turnIndexFromTime
      : findTurnIndexByPosition(turns, summary.originalIndex);

    if (turnIndex < 0) {
      continue;
    }

    if (isNewerSummary(summary, turns[turnIndex].summary)) {
      turns[turnIndex].summary = summary;
    }
  }
}

function getTurnDurationMs(messages: ChatMessage[], turn: MessageTurn, hostIndex: number): number {
  let startTime: number | null = null;
  for (let index = turn.start; index <= hostIndex; index += 1) {
    startTime = parseMessageTime(messages[index]?.timestamp);
    if (startTime != null) {
      break;
    }
  }

  const endTime = parseMessageTime(messages[hostIndex]?.timestamp);
  if (startTime == null || endTime == null) {
    return 0;
  }
  return Math.max(0, endTime - startTime);
}

function createSyntheticProcessSummary(
  messages: ChatMessage[],
  turn: MessageTurn,
  hostIndex: number,
  detailMessages: ChatMessage[],
): ChatMessage {
  const host = messages[hostIndex];
  const startedAt = messages[turn.start]?.timestamp;
  const endedAt = host?.timestamp;
  const toolCallCount = detailMessages.filter((message) =>
    message.isToolUse || Boolean(message.toolName),
  ).length;
  const toolErrorCount = detailMessages.filter((message) =>
    message.toolResult?.isError || message.type === 'error',
  ).length;
  const ragSearchCount = detailMessages.filter((message) =>
    message.phase === 'rag' || /search|检索/i.test(`${message.toolName || ''} ${message.content || ''}`),
  ).length;

  return {
    id: `process_summary_${host?.id || hostIndex}`,
    type: 'system',
    content: 'Process summary',
    timestamp: endedAt || new Date().toISOString(),
    isAgentActivitySummary: true,
    startedAt: startedAt ? String(startedAt) : '',
    endedAt: endedAt ? String(endedAt) : '',
    durationMs: getTurnDurationMs(messages, turn, hostIndex),
    state: 'completed',
    toolCallCount,
    toolErrorCount,
    ragSearchCount,
    compactCount: detailMessages.filter((message) => message.isCompactBoundary).length,
    keySteps: [],
  };
}

export function buildRenderableMessageItems(
  messages: ChatMessage[],
  options: BuildRenderableMessageItemsOptions = {},
): RenderableMessageItem[] {
  const items: RenderableMessageItem[] = [];
  const itemsByIndex = new Map<number, RenderableMessageItem>();
  const collapsedIndices = new Set<number>();
  const turns = createMessageTurns(messages);

  messages.forEach((message, originalIndex) => {
    if (message.isAgentActivitySummary) {
      return;
    }

    const item: RenderableMessageItem = { message, originalIndex, processSummary: null, processDetailMessages: [] };
    items.push(item);
    itemsByIndex.set(originalIndex, item);
  });

  attachSummariesToTurns(messages, turns);

  turns.forEach((turn, turnIndex) => {
    let host: RenderableMessageItem | null = null;
    for (let index = turn.end - 1; index >= turn.start; index -= 1) {
      const message = messages[index];
      if (!message || !canHostProcessSummary(message)) {
        continue;
      }
      host = itemsByIndex.get(index) || null;
      if (host) break;
    }

    if (!host) {
      if (turn.summary) {
        items.push({ message: turn.summary.message, originalIndex: turn.summary.originalIndex, processSummary: null });
      }
      return;
    }

    const isLatestTurn = turnIndex === turns.length - 1;
    const shouldKeepTurnExpanded = Boolean(options.isAssistantWorking && isLatestTurn);
    if (shouldKeepTurnExpanded) {
      return;
    }

    const detailMessages: ChatMessage[] = [];
    for (let index = turn.start; index < turn.end; index += 1) {
      if (index === host.originalIndex) {
        continue;
      }
      const message = messages[index];
      if (!message || !isCollapsibleProcessMessage(message)) {
        continue;
      }
      detailMessages.push(message);
      collapsedIndices.add(index);
    }

    if (detailMessages.length === 0 && !turn.summary) {
      return;
    }

    host.processSummary =
      turn.summary?.message || createSyntheticProcessSummary(messages, turn, host.originalIndex, detailMessages);
    host.processDetailMessages = detailMessages;
  });

  return items
    .filter((item) => !collapsedIndices.has(item.originalIndex))
    .sort((a, b) => a.originalIndex - b.originalIndex);
}

function MeasuredMessageItem({
  itemKey,
  message,
  isLast,
  onHeightChange,
  children,
}: {
  itemKey: string;
  message: ChatMessage;
  isLast: boolean;
  onHeightChange: (itemKey: string, height: number) => void;
  children: ReactNode;
}) {
  const itemRef = useRef<HTMLDivElement | null>(null);

  useLayoutEffect(() => {
    const node = itemRef.current;
    if (!node) return undefined;

    const reportHeight = () => {
      onHeightChange(itemKey, node.getBoundingClientRect().height);
    };

    reportHeight();
    const observer = new ResizeObserver(reportHeight);
    observer.observe(node);

    return () => observer.disconnect();
  }, [itemKey, onHeightChange]);

  return (
    <div
      ref={itemRef}
      className={`chat-message ${isLast ? '' : 'pb-8'}`}
      data-message-timestamp={message.timestamp ? String(message.timestamp) : undefined}
    >
      {children}
    </div>
  );
}

export default function MessagesPaneV2({
  scrollContainerRef,
  onWheel,
  onTouchMove,
  isLoadingSessionMessages,
  sessionLoadError,
  onRetrySessionLoad,
  chatMessages,
  activityMessages = [],
  visibleMessages,
  provider,
  selectedProject,
  selectedSession,
  createDiff,
  onFileOpen,
  onShowSettings,
  onGrantToolPermission,
  autoExpandTools,
  showRawParameters,
  showThinking,
  setInput,
  isAssistantWorking = false,
  workingStatus,
}: MessagesPaneV2Props) {
  const { t } = useTranslation('chat');
  const messageKeyMapRef = useRef<WeakMap<ChatMessage, string>>(new WeakMap());
  const generatedMessageKeyCounterRef = useRef(0);
  const measuredHeightsRef = useRef<Map<string, number>>(new Map());
  const heightVersionRafRef = useRef<number | null>(null);
  const [heightVersion, setHeightVersion] = useState(0);
  const [scrollViewport, setScrollViewport] = useState({ scrollTop: 0, height: 0 });

  const getMessageKey = useCallback((message: ChatMessage, index: number) => {
    const existingKey = messageKeyMapRef.current.get(message);
    if (existingKey) return existingKey;

    const intrinsicKey = getIntrinsicMessageKey(message);
    if (intrinsicKey) {
      // Most normalized messages have stable ids/tool ids. Reuse those keys
      // across renders so periodic process updates do not remount tool rows
      // and collapse any <details> the user has opened.
      messageKeyMapRef.current.set(message, intrinsicKey);
      return intrinsicKey;
    }

    generatedMessageKeyCounterRef.current += 1;
    const candidateKey = `message-generated-${index}-${generatedMessageKeyCounterRef.current}`;
    messageKeyMapRef.current.set(message, candidateKey);
    return candidateKey;
  }, []);

  const suggestedPrompts: string[] = [
    t('emptyChat.prompts.plan', { defaultValue: 'Plan a refactor for this project' }),
    t('emptyChat.prompts.summary', { defaultValue: 'Summarize recent changes' }),
    t('emptyChat.prompts.review', { defaultValue: 'Review the most recent file I touched' }),
  ];

  const isEmpty = !isLoadingSessionMessages && chatMessages.length === 0;
  const hasSessionLoadError = Boolean(!isLoadingSessionMessages && sessionLoadError && chatMessages.length === 0);
  const isNewConversationEmpty = isEmpty && !selectedSession;
  const isExistingConversationEmpty = isEmpty && Boolean(selectedSession) && !hasSessionLoadError;
  const isReadOnlyBackgroundSession = isBackgroundTaskSession(selectedSession);
  const liveActivities = useMemo(
    () => activityMessages.filter((message) => message.isAgentActivity),
    [activityMessages],
  );
  const renderableMessages = useMemo(
    () => visibleMessages.filter((message) => !message.isAgentActivity),
    [visibleMessages],
  );
  const renderableMessageItems = useMemo(
    () => buildRenderableMessageItems(renderableMessages, { isAssistantWorking }),
    [isAssistantWorking, renderableMessages],
  );
  const keyedMessageItems = useMemo<KeyedRenderableMessageItem[]>(
    () => renderableMessageItems.map((item, index) => ({
      ...item,
      itemKey: getMessageKey(item.message, index),
      renderIndex: index,
      estimatedHeight: estimateMessageItemHeight(item),
    })),
    [getMessageKey, renderableMessageItems],
  );
  const measuredItemHeights = useMemo(
    () => keyedMessageItems.map((item) => measuredHeightsRef.current.get(item.itemKey) ?? item.estimatedHeight),
    [heightVersion, keyedMessageItems],
  );
  const shouldVirtualizeMessages = keyedMessageItems.length > MESSAGE_VIRTUALIZATION_THRESHOLD;
  const virtualWindow = useMemo(
    () => shouldVirtualizeMessages
      ? getVirtualMessageWindow(
          measuredItemHeights,
          scrollViewport.scrollTop,
          scrollViewport.height,
          MESSAGE_WINDOW_OVERSCAN,
        )
      : {
          startIndex: 0,
          endIndex: keyedMessageItems.length,
          topPadding: 0,
          bottomPadding: 0,
          totalHeight: measuredItemHeights.reduce((sum, height) => sum + height, 0),
        },
    [keyedMessageItems.length, measuredItemHeights, scrollViewport.height, scrollViewport.scrollTop, shouldVirtualizeMessages],
  );
  const windowedMessageItems = shouldVirtualizeMessages
    ? keyedMessageItems.slice(virtualWindow.startIndex, virtualWindow.endIndex)
    : keyedMessageItems;

  const bumpHeightVersion = useCallback(() => {
    if (heightVersionRafRef.current !== null) return;
    heightVersionRafRef.current = requestAnimationFrame(() => {
      heightVersionRafRef.current = null;
      setHeightVersion((version) => version + 1);
    });
  }, []);

  const handleMeasuredItemHeight = useCallback((itemKey: string, height: number) => {
    const normalizedHeight = Math.max(1, Math.ceil(height));
    const currentHeight = measuredHeightsRef.current.get(itemKey);
    if (currentHeight !== undefined && Math.abs(currentHeight - normalizedHeight) < 2) {
      return;
    }

    measuredHeightsRef.current.set(itemKey, normalizedHeight);
    bumpHeightVersion();
  }, [bumpHeightVersion]);

  useEffect(() => () => {
    if (heightVersionRafRef.current !== null) {
      cancelAnimationFrame(heightVersionRafRef.current);
    }
  }, []);

  useEffect(() => {
    const validKeys = new Set(keyedMessageItems.map((item) => item.itemKey));
    let changed = false;

    for (const itemKey of measuredHeightsRef.current.keys()) {
      if (!validKeys.has(itemKey)) {
        measuredHeightsRef.current.delete(itemKey);
        changed = true;
      }
    }

    if (changed) {
      bumpHeightVersion();
    }
  }, [bumpHeightVersion, keyedMessageItems]);

  useLayoutEffect(() => {
    const container = scrollContainerRef.current;
    if (!container) return undefined;

    let frame = 0;
    const updateViewport = () => {
      frame = 0;
      setScrollViewport({
        scrollTop: container.scrollTop,
        height: container.clientHeight,
      });
    };
    const scheduleViewportUpdate = () => {
      if (frame) return;
      frame = requestAnimationFrame(updateViewport);
    };

    updateViewport();
    container.addEventListener('scroll', scheduleViewportUpdate, { passive: true });
    const resizeObserver = new ResizeObserver(scheduleViewportUpdate);
    resizeObserver.observe(container);

    return () => {
      if (frame) cancelAnimationFrame(frame);
      container.removeEventListener('scroll', scheduleViewportUpdate);
      resizeObserver.disconnect();
    };
  }, [scrollContainerRef]);

  const renderMessageItem = useCallback((item: KeyedRenderableMessageItem) => {
    const previousMessage = item.renderIndex > 0 ? keyedMessageItems[item.renderIndex - 1].message : null;
    const isLast = !isAssistantWorking && item.renderIndex === keyedMessageItems.length - 1;

    return (
      <MeasuredMessageItem
        key={item.itemKey}
        itemKey={item.itemKey}
        message={item.message}
        isLast={isLast}
        onHeightChange={handleMeasuredItemHeight}
      >
        <MessageRowV2
          message={item.message}
          prevMessage={previousMessage}
          processSummary={item.processSummary}
          processDetailMessages={item.processDetailMessages}
          provider={provider}
          selectedProject={selectedProject}
          createDiff={createDiff}
          onFileOpen={onFileOpen}
          onShowSettings={onShowSettings}
          onGrantToolPermission={onGrantToolPermission}
          autoExpandTools={autoExpandTools}
          showRawParameters={showRawParameters}
          showThinking={showThinking}
        />
      </MeasuredMessageItem>
    );
  }, [
    autoExpandTools,
    createDiff,
    handleMeasuredItemHeight,
    isAssistantWorking,
    keyedMessageItems,
    onFileOpen,
    onGrantToolPermission,
    onShowSettings,
    provider,
    selectedProject,
    showRawParameters,
    showThinking,
  ]);

  return (
    <div
      ref={scrollContainerRef}
      onWheel={onWheel}
      onTouchMove={onTouchMove}
      className="relative flex-1 overflow-y-auto overflow-x-hidden bg-white dark:bg-neutral-950"
    >
      {hasSessionLoadError ? (
        <div className="mx-auto flex h-full max-w-[720px] flex-col items-center justify-center gap-3 px-6 py-10 text-center">
          <XCircle className="h-5 w-5 text-amber-600 dark:text-amber-400" strokeWidth={1.75} />
          <div className="text-[15px] font-medium text-neutral-900 dark:text-neutral-100">
            {t('session.loadFailedTitle', { defaultValue: 'Could not load this conversation' })}
          </div>
          <div className="max-w-[520px] text-[13px] leading-5 text-neutral-500 dark:text-neutral-400">
            {sessionLoadError}
          </div>
          {onRetrySessionLoad ? (
            <button
              type="button"
              onClick={onRetrySessionLoad}
              className="inline-flex h-8 items-center rounded-md border border-neutral-200 px-3 text-[13px] font-medium text-neutral-700 transition hover:bg-neutral-50 dark:border-neutral-800 dark:text-neutral-300 dark:hover:bg-neutral-900"
            >
              {t('session.retryLoad', { defaultValue: 'Retry' })}
            </button>
          ) : null}
        </div>
      ) : isLoadingSessionMessages && chatMessages.length === 0 ? (
        <div className="mx-auto flex h-full max-w-[720px] items-center justify-center px-6 py-10 text-[13px] text-neutral-500 dark:text-neutral-400">
          <div className="flex items-center gap-2">
            <div className="h-3.5 w-3.5 animate-spin rounded-full border-b-2 border-neutral-400" />
            <span>{t('loading', { defaultValue: 'Loading…' })}</span>
          </div>
        </div>
      ) : isNewConversationEmpty ? (
        <div className="mx-auto flex h-full max-w-[720px] flex-col items-center justify-center gap-4 px-6 py-10 text-center">
          <div className="text-[15px] font-medium text-neutral-900 dark:text-neutral-100">
            {selectedProject
              ? t('emptyChat.title', { defaultValue: 'Start a new conversation' })
              : t('emptyChat.noProject', { defaultValue: 'Pick a project from the sidebar' })}
          </div>
          {selectedProject ? (
            <div className="flex flex-col gap-1.5">
              {suggestedPrompts.map((prompt) => (
                <button
                  key={prompt}
                  type="button"
                  onClick={() => setInput(prompt)}
                  className="rounded-lg border border-neutral-200 px-3 py-1.5 text-left text-[13px] text-neutral-700 transition hover:bg-neutral-50 dark:border-neutral-800 dark:text-neutral-300 dark:hover:bg-neutral-900"
                >
                  {prompt}
                </button>
              ))}
            </div>
          ) : null}
        </div>
      ) : isExistingConversationEmpty ? (
        <div className="mx-auto flex h-full max-w-[720px] flex-col items-center justify-center gap-2 px-6 py-10 text-center">
          <div className="text-[15px] font-medium text-neutral-900 dark:text-neutral-100">
            {isReadOnlyBackgroundSession
              ? t('emptyChat.readonlyBackgroundTitle', {
                  defaultValue: 'No displayable messages in this task transcript',
                })
              : t('emptyChat.emptySessionTitle', {
                  defaultValue: 'No displayable messages in this conversation',
                })}
          </div>
          <div className="max-w-[520px] text-[13px] leading-5 text-neutral-500 dark:text-neutral-400">
            {isReadOnlyBackgroundSession
              ? t('emptyChat.readonlyBackgroundDescription', {
                  defaultValue:
                    'This read-only background task transcript only contains records the chat view cannot display.',
                })
              : t('emptyChat.emptySessionDescription', {
                  defaultValue:
                    'This conversation exists, but it does not contain messages that can be rendered here.',
                })}
          </div>
        </div>
      ) : (
        <div
          className="mx-auto max-w-[860px] px-6 py-10"
          data-virtualized-messages={shouldVirtualizeMessages ? 'true' : undefined}
          data-rendered-message-count={windowedMessageItems.length}
          data-total-message-count={keyedMessageItems.length}
        >
          {shouldVirtualizeMessages && virtualWindow.topPadding > 0 ? (
            <div aria-hidden="true" style={{ height: virtualWindow.topPadding }} />
          ) : null}

          {windowedMessageItems.map(renderMessageItem)}

          {shouldVirtualizeMessages && virtualWindow.bottomPadding > 0 ? (
            <div aria-hidden="true" style={{ height: virtualWindow.bottomPadding }} />
          ) : null}

          {isAssistantWorking ? (
            <div className={keyedMessageItems.length > 0 ? 'pt-8' : ''}>
              <ProcessPanel
                activities={liveActivities}
                fallbackLabel={
                  liveActivities.length > 0
                    ? resolveWorkingLabel(workingStatus, t)
                    : t('process.waitingForModel', { defaultValue: 'Requesting model' })
                }
                t={t}
              />
            </div>
          ) : null}
        </div>
      )}
    </div>
  );
}

// Map raw status strings the realtime layer hands us to localized labels.
// Strings come from a few places (`useChatComposerState`, the realtime
// handler default, possible future SDK-sourced values) and may be any of:
// "Processing" / "Working..." / "Working" / "Waiting for permission".
// Anything we don't recognize falls through verbatim — better than showing
// a wrong-but-translated string.
function resolveWorkingLabel(
  status: ClaudeWorkStatus | null | undefined,
  t: (key: string, options?: Record<string, unknown>) => string,
): string {
  const fallback = t('working.default', { defaultValue: 'Working' });
  const raw = status?.text;
  if (!raw) return fallback;
  const normalized = raw.replace(/[.…\s]+$/u, '').trim().toLowerCase();
  switch (normalized) {
    case '':
    case 'working':
      return fallback;
    case 'processing':
      return t('working.processing', { defaultValue: 'Processing' });
    case 'thinking':
      return t('working.thinking', { defaultValue: 'Thinking' });
    case 'waiting for permission':
      return t('working.waitingForPermission', { defaultValue: 'Waiting for permission' });
    case 'compacting':
    case 'compacting context':
      return t('working.compacting', { defaultValue: 'Compacting context...' });
    default:
      return raw;
  }
}

function formatDuration(ms?: number | null): string {
  const totalSeconds = Math.max(0, Math.round(Number(ms) || 0) / 1000);
  if (totalSeconds < 60) {
    return `${Math.round(totalSeconds)}s`;
  }
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = Math.round(totalSeconds % 60);
  return seconds ? `${minutes}m ${seconds}s` : `${minutes}m`;
}

function getActivityIcon(activity: ChatMessage | null) {
  if (!activity) return Activity;
  if (activity.state === 'failed' || activity.severity === 'error' || activity.severity === 'warning') return XCircle;
  if (activity.state === 'completed') return CheckCircle2;
  if (activity.phase === 'rag') return Search;
  if (activity.phase === 'tool' || activity.phase === 'subtask') return Wrench;
  return Loader2;
}

function summarizeActivities(activities: ChatMessage[]) {
  const byId = new Map<string, ChatMessage>();
  for (const activity of activities) {
    const key = activity.activityId || activity.id || `${activity.runId}-${activity.timestamp}`;
    byId.set(key, activity);
  }
  const latest = Array.from(byId.values());
  const current = [...latest].reverse().find((activity) => activity.state === 'running') || latest[latest.length - 1] || null;
  const startedAt = latest[0]?.startedAt || latest[0]?.timestamp;
  const elapsedMs = startedAt ? Date.now() - Date.parse(String(startedAt)) : 0;
  const toolCalls = latest.filter((activity) => activity.toolName || activity.phase === 'tool' || activity.phase === 'subtask' || activity.phase === 'rag').length;
  const errors = latest.filter((activity) => activity.state === 'failed' || activity.severity === 'error').length;
  const searches = latest.filter((activity) => activity.phase === 'rag').length;
  const recent = latest.filter((activity) => activity.title).slice(-5);
  return { current, elapsedMs, toolCalls, errors, searches, recent };
}

function ProcessPanel({
  activities,
  fallbackLabel,
  t,
}: {
  activities: ChatMessage[];
  fallbackLabel: string;
  t: (key: string, options?: Record<string, unknown>) => string;
}) {
  const summary = useMemo(() => summarizeActivities(activities), [activities]);
  const current = summary.current;
  const CurrentIcon = getActivityIcon(current);
  const label = current?.title || fallbackLabel;
  const detail = current?.detail || '';
  const iconClass =
    CurrentIcon === Loader2
      ? 'animate-spin text-neutral-500 dark:text-neutral-400'
      : current?.state === 'failed' || current?.severity === 'error' || current?.severity === 'warning'
        ? 'text-amber-600 dark:text-amber-400'
        : current?.state === 'completed'
          ? 'text-emerald-600 dark:text-emerald-400'
          : 'text-neutral-500 dark:text-neutral-400';

  return (
    <div
      role="status"
      aria-live="polite"
      className="rounded-xl border border-neutral-200 bg-white px-3.5 py-3 text-[12px] text-neutral-700 shadow-sm dark:border-neutral-800 dark:bg-neutral-900/70 dark:text-neutral-300"
    >
      <div className="flex min-w-0 items-start justify-between gap-3">
        <div className="flex min-w-0 items-start gap-2.5">
          <CurrentIcon className={`mt-0.5 h-4 w-4 shrink-0 ${iconClass}`} strokeWidth={2} />
          <div className="min-w-0">
            <div className="font-medium text-neutral-900 dark:text-neutral-100">{label}</div>
            {detail ? (
              <div className="mt-0.5 truncate text-neutral-500 dark:text-neutral-400">{detail}</div>
            ) : null}
          </div>
        </div>
        <div className="shrink-0 tabular-nums text-neutral-500 dark:text-neutral-400">
          {formatDuration(summary.elapsedMs)}
        </div>
      </div>
      <div className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-[11px] text-neutral-500 dark:text-neutral-400">
        <span>{t('process.metrics.toolCalls', { count: summary.toolCalls, defaultValue: '{{count}} tool calls' })}</span>
        <span>{t('process.metrics.searches', { count: summary.searches, defaultValue: '{{count}} searches' })}</span>
        <span>{t('process.metrics.errors', { count: summary.errors, defaultValue: '{{count}} errors' })}</span>
      </div>
      {summary.recent.length > 1 ? (
        <div className="mt-2 space-y-1 border-t border-neutral-100 pt-2 dark:border-neutral-800">
          {summary.recent.slice(-3).map((activity) => (
            <div key={activity.activityId || activity.id} className="flex min-w-0 items-center gap-2 text-[11px] text-neutral-500 dark:text-neutral-400">
              <span className="h-1.5 w-1.5 shrink-0 rounded-full bg-neutral-300 dark:bg-neutral-600" />
              <span className="truncate">{activity.title || activity.content}</span>
            </div>
          ))}
        </div>
      ) : null}
    </div>
  );
}
