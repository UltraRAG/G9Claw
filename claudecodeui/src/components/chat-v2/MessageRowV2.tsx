import { memo, useMemo } from 'react';
import { AlertTriangle, Bot } from 'lucide-react';
import type {
  ChatMessage,
  ClaudePermissionSuggestion,
  PermissionGrantResult,
} from '../chat/types/types';
import type { Project, SessionProvider } from '../../types/app';
import MessageComponent from '../chat/view/subcomponents/MessageComponent';
import { Markdown } from '../chat/view/subcomponents/Markdown';
import { formatUsageLimitText } from '../chat/utils/chatFormatting';
import { cn } from '../../lib/utils.js';

type DiffLine = { type: string; content: string; lineNum: number };

type MessageRowV2Props = {
  message: ChatMessage;
  prevMessage: ChatMessage | null;
  provider: SessionProvider;
  selectedProject: Project | null;
  createDiff: (oldStr: string, newStr: string) => DiffLine[];
  onFileOpen?: (filePath: string, diffInfo?: unknown) => void;
  onShowSettings?: () => void;
  onGrantToolPermission?: (
    suggestion: ClaudePermissionSuggestion,
  ) => PermissionGrantResult | null | undefined;
  autoExpandTools?: boolean;
  showRawParameters?: boolean;
  showThinking?: boolean;
};

// Fall back to the heavy legacy renderer for anything that isn't a vanilla
// user/assistant markdown message — tool invocations, diffs, permission
// prompts, task notifications, subagent containers, etc. live there and we
// don't want to re-implement them all.
const shouldDelegate = (message: ChatMessage): boolean => {
  if (message.isToolUse) return true;
  if (message.isInteractivePrompt) return true;
  if (message.isSubagentContainer) return true;
  if (message.isTaskNotification) return true;
  const t = message.type;
  // These types have custom bespoke renderings we preserve 1:1 from legacy.
  if (t !== 'user' && t !== 'assistant' && t !== 'error') return true;
  // Assistant messages that are purely "thinking" preludes go through legacy
  // so the thinking panel renders correctly.
  if (t === 'assistant' && message.isThinking && !message.content) return true;
  return false;
};

function getUserInitials(providerLabel?: string): string {
  return (providerLabel || 'You').slice(0, 2).toUpperCase();
}

function MessageRowV2({
  message,
  prevMessage,
  provider,
  selectedProject,
  createDiff,
  onFileOpen,
  onShowSettings,
  onGrantToolPermission,
  autoExpandTools,
  showRawParameters,
  showThinking,
}: MessageRowV2Props) {
  const delegate = useMemo(() => shouldDelegate(message), [message]);

  const formattedContent = useMemo(
    () => formatUsageLimitText(String(message.content ?? '')),
    [message.content],
  );

  if (delegate) {
    // Wrap legacy output in a neutral container so gradients/colors from the
    // legacy theme get a zinc frame — keeps the prototype aesthetic while
    // preserving every tool/permission renderer.
    return (
      <div className="ui-v2-legacy-row">
        <MessageComponent
          message={message}
          prevMessage={prevMessage}
          createDiff={createDiff}
          onFileOpen={onFileOpen}
          onShowSettings={onShowSettings}
          onGrantToolPermission={onGrantToolPermission}
          autoExpandTools={autoExpandTools}
          showRawParameters={showRawParameters}
          showThinking={showThinking}
          selectedProject={selectedProject ?? null}
          provider={provider}
        />
      </div>
    );
  }

  const isUser = message.type === 'user';
  const isError = message.type === 'error';

  const roleLabel = isUser
    ? 'You'
    : isError
      ? 'Error'
      : provider === 'cursor'
        ? 'Cursor'
        : provider === 'codex'
          ? 'Codex'
          : provider === 'gemini'
            ? 'Gemini'
            : 'edgeclaw';

  return (
    <div className="flex gap-4">
      <div
        className={cn(
          'flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-xxs font-medium',
          isError
            ? 'bg-red-500/10 text-red-500'
            : isUser
              ? 'bg-neutral-200 text-neutral-700 dark:bg-neutral-800 dark:text-neutral-200'
              : 'bg-neutral-900 text-neutral-50 dark:bg-neutral-50 dark:text-neutral-900',
        )}
      >
        {isError ? (
          <AlertTriangle className="h-3.5 w-3.5" strokeWidth={2} />
        ) : isUser ? (
          getUserInitials('You')
        ) : provider === 'claude' ? (
          'E'
        ) : (
          <Bot className="h-3.5 w-3.5" strokeWidth={1.75} />
        )}
      </div>
      <div className="min-w-0 flex-1 pt-0.5">
        <div className="mb-1 text-[13px] font-medium text-neutral-900 dark:text-neutral-100">
          {roleLabel}
        </div>
        <div
          className={cn(
            'text-[14px] leading-relaxed',
            isError
              ? 'text-red-500'
              : 'text-neutral-800 dark:text-neutral-200',
          )}
        >
          {message.isStreaming && !formattedContent ? (
            <span className="inline-block h-4 w-2 animate-pulse bg-neutral-400 dark:bg-neutral-500" />
          ) : (
            <Markdown>{formattedContent}</Markdown>
          )}
        </div>
      </div>
    </div>
  );
}

export default memo(MessageRowV2);
