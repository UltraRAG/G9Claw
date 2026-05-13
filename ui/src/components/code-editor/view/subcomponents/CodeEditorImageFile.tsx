import { useEffect, useState } from 'react';
import { Image as ImageIcon } from 'lucide-react';
import type { CodeEditorFile } from '../../types/types';
import CodeEditorHeader from './CodeEditorHeader';

type CodeEditorActionLabels = {
  showingChanges: string;
  editMarkdown: string;
  previewMarkdown: string;
  openHtmlPreview: string;
  download: string;
  save: string;
  saving: string;
  saved: string;
  fullscreen: string;
  exitFullscreen: string;
  close: string;
};

type CodeEditorImageFileProps = {
  file: CodeEditorFile;
  imageUrl: string | null;
  isSidebar: boolean;
  isFullscreen: boolean;
  onClose: () => void;
  onDownload: () => void;
  onToggleFullscreen: () => void;
  labels: CodeEditorActionLabels;
  unavailableMessage: string;
};

export default function CodeEditorImageFile({
  file,
  imageUrl,
  isSidebar,
  isFullscreen,
  onClose,
  onDownload,
  onToggleFullscreen,
  labels,
  unavailableMessage,
}: CodeEditorImageFileProps) {
  const [loadFailed, setLoadFailed] = useState(false);

  useEffect(() => {
    setLoadFailed(false);
  }, [imageUrl]);

  const headerTopBar = (
    <CodeEditorHeader
      file={file}
      isSidebar={isSidebar}
      isFullscreen={isFullscreen}
      isMarkdownFile={false}
      isHtmlFile={false}
      markdownPreview={false}
      saving={false}
      saveSuccess={false}
      showSave={false}
      onToggleMarkdownPreview={() => undefined}
      onOpenHtmlPreview={() => undefined}
      onDownload={onDownload}
      onSave={() => undefined}
      onToggleFullscreen={onToggleFullscreen}
      onClose={onClose}
      labels={labels}
    />
  );

  const imageContent = (
    <div className="flex min-h-0 flex-1 items-center justify-center overflow-auto bg-neutral-50 p-4 dark:bg-neutral-950">
      {imageUrl && !loadFailed ? (
        <img
          src={imageUrl}
          alt={file.name}
          onError={() => setLoadFailed(true)}
          className="max-h-full max-w-full object-contain"
        />
      ) : (
        <div className="flex max-w-sm flex-col items-center gap-3 text-center">
          <div className="flex h-14 w-14 items-center justify-center rounded-full bg-white text-neutral-500 shadow-sm dark:bg-neutral-900 dark:text-neutral-400">
            <ImageIcon className="h-7 w-7" strokeWidth={1.5} />
          </div>
          <p className="text-[13px] text-neutral-500 dark:text-neutral-400">
            {unavailableMessage}
          </p>
          <button
            type="button"
            onClick={onClose}
            className="rounded-md bg-neutral-900 px-4 py-1.5 text-[13px] text-white transition-colors hover:opacity-90 dark:bg-neutral-100 dark:text-neutral-900"
          >
            {labels.close}
          </button>
        </div>
      )}
    </div>
  );

  if (isSidebar) {
    return (
      <div className="flex h-full w-full flex-col bg-white dark:bg-neutral-950">
        {headerTopBar}
        {imageContent}
      </div>
    );
  }

  const containerClassName = isFullscreen
    ? 'fixed inset-0 z-[9999] bg-white dark:bg-neutral-950 flex flex-col'
    : 'fixed inset-0 z-[9999] md:bg-black/40 md:backdrop-blur-sm md:flex md:items-center md:justify-center md:p-4';

  const innerClassName = isFullscreen
    ? 'bg-white dark:bg-neutral-950 flex flex-col w-full h-full'
    : 'bg-white dark:bg-neutral-950 flex flex-col w-full h-full md:rounded-xl md:border md:border-neutral-200 dark:md:border-neutral-800 md:shadow-xl md:w-full md:max-w-6xl md:h-[80vh] md:max-h-[80vh]';

  return (
    <div className={containerClassName}>
      <div className={innerClassName}>
        {headerTopBar}
        {imageContent}
      </div>
    </div>
  );
}
