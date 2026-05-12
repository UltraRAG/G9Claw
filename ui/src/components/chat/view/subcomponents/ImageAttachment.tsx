import { FileText, X } from 'lucide-react';
import { useEffect, useState } from 'react';

interface ImageAttachmentProps {
  file: File;
  onRemove: () => void;
  uploadProgress?: number;
  error?: string;
}

function formatFileSize(size: number): string {
  if (!Number.isFinite(size) || size <= 0) return '0 B';
  if (size >= 1024 * 1024) return `${(size / (1024 * 1024)).toFixed(1)} MB`;
  if (size >= 1024) return `${Math.ceil(size / 1024)} KB`;
  return `${size} B`;
}

const ImageAttachment = ({ file, onRemove, uploadProgress, error }: ImageAttachmentProps) => {
  const [preview, setPreview] = useState<string | undefined>(undefined);
  const isImage = Boolean(file.type?.startsWith('image/'));
  
  useEffect(() => {
    if (!isImage) {
      setPreview(undefined);
      return undefined;
    }
    const url = URL.createObjectURL(file);
    setPreview(url);
    return () => URL.revokeObjectURL(url);
  }, [file, isImage]);
  
  return (
    <div className="group relative">
      {isImage ? (
        <img src={preview} alt={file.name} className="h-20 w-20 rounded object-cover" />
      ) : (
        <div className="flex h-20 w-36 flex-col justify-between rounded border border-neutral-200 bg-white p-2 text-neutral-700 dark:border-neutral-800 dark:bg-neutral-900 dark:text-neutral-200">
          <div className="flex items-center gap-1.5">
            <FileText className="h-4 w-4 shrink-0 text-neutral-500 dark:text-neutral-400" />
            <span className="truncate text-[11px] font-medium" title={file.name}>
              {file.name}
            </span>
          </div>
          <span className="text-[10px] text-neutral-500 dark:text-neutral-400">
            {formatFileSize(file.size)}
          </span>
        </div>
      )}
      {uploadProgress !== undefined && uploadProgress < 100 && (
        <div className="absolute inset-0 flex items-center justify-center bg-black/50">
          <div className="text-xs text-white">{uploadProgress}%</div>
        </div>
      )}
      {error && (
        <div className="absolute inset-0 flex items-center justify-center bg-red-500/50">
          <svg className="h-6 w-6 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
          </svg>
        </div>
      )}
      <button
        type="button"
        onClick={onRemove}
        className="absolute -right-2 -top-2 rounded-full bg-red-500 p-1 text-white opacity-100 transition-opacity focus:opacity-100 sm:opacity-0 sm:group-hover:opacity-100"
        aria-label="Remove attachment"
      >
        <X className="h-3 w-3" strokeWidth={2} />
      </button>
    </div>
  );
};

export default ImageAttachment;

