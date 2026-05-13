import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { MouseEvent } from 'react';
import { useTranslation } from 'react-i18next';
import {
  ChevronDown,
  ChevronRight,
  ChevronsDownUp,
  Download,
  Eye,
  Folder,
  FolderOpen,
  Loader2,
  RefreshCw,
  Trash2,
  Upload,
  X,
} from 'lucide-react';
import type { Project } from '../../types/app';
import { useFileTreeData } from '../file-tree/hooks/useFileTreeData';
import type { FileTreeNode } from '../file-tree/types/types';
import { getFileIconData } from '../file-tree/constants/fileIcons';
import { cn } from '../../lib/utils.js';
import { api } from '../../utils/api';

type FilesV2Props = {
  selectedProject: Project | null;
  onFileOpen?: (filePath: string) => void;
  onClose?: () => void;
};

type FlattenedNode = {
  node: FileTreeNode;
  depth: number;
  parentPath: string;
};

type FileContextMenu = {
  node: FileTreeNode;
  x: number;
  y: number;
};

function flatten(
  nodes: FileTreeNode[],
  expanded: Set<string>,
  depth = 0,
  parentPath = '',
): FlattenedNode[] {
  const out: FlattenedNode[] = [];
  for (const node of nodes) {
    out.push({ node, depth, parentPath });
    if (node.type === 'directory' && expanded.has(node.path) && node.children) {
      out.push(...flatten(node.children, expanded, depth + 1, node.path));
    }
  }
  return out;
}

export default function FilesV2({ selectedProject, onFileOpen, onClose }: FilesV2Props) {
  const { t } = useTranslation();
  const { files, loading, refreshFiles } = useFileTreeData(selectedProject);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [activePath, setActivePath] = useState<string | null>(null);
  const [downloadingProject, setDownloadingProject] = useState(false);
  const [uploadingProject, setUploadingProject] = useState(false);
  const [uploadMenuOpen, setUploadMenuOpen] = useState(false);
  const [contextMenu, setContextMenu] = useState<FileContextMenu | null>(null);
  const [deletingPath, setDeletingPath] = useState<string | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const folderInputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    setExpanded(new Set());
    setActivePath(null);
    setUploadMenuOpen(false);
    setContextMenu(null);
  }, [selectedProject?.name]);

  const flat = useMemo(() => flatten(files, expanded), [files, expanded]);

  const toggle = useCallback((path: string) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });
  }, []);

  const collapseAll = useCallback(() => {
    setExpanded(new Set());
  }, []);

  const projectRoot = selectedProject?.fullPath || selectedProject?.path || '';

  useEffect(() => {
    folderInputRef.current?.setAttribute('webkitdirectory', '');
    folderInputRef.current?.setAttribute('directory', '');
  }, []);

  useEffect(() => {
    if (!contextMenu) return undefined;

    const closeMenu = () => setContextMenu(null);
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') closeMenu();
    };

    document.addEventListener('click', closeMenu);
    document.addEventListener('keydown', handleKeyDown);
    return () => {
      document.removeEventListener('click', closeMenu);
      document.removeEventListener('keydown', handleKeyDown);
    };
  }, [contextMenu]);

  const uploadSelectedFiles = useCallback(
    async (fileList: FileList | null) => {
      if (!selectedProject?.name || !fileList || fileList.length === 0) return;

      const files = Array.from(fileList);
      const relativePaths = files.map((file) => {
        const withDirectoryPath = file as File & { webkitRelativePath?: string };
        return withDirectoryPath.webkitRelativePath || file.name;
      });

      const formData = new FormData();
      formData.append('targetPath', '');
      formData.append('relativePaths', JSON.stringify(relativePaths));
      for (const file of files) {
        formData.append('files', file);
      }

      try {
        setUploadingProject(true);
        setUploadMenuOpen(false);
        const response = await api.uploadFiles(selectedProject.name, formData);
        if (!response.ok) {
          const errorText = await response.text().catch(() => '');
          throw new Error(errorText || `Upload failed: ${response.status}`);
        }
        await refreshFiles();
      } catch (error) {
        console.error('Failed to upload files:', error);
      } finally {
        setUploadingProject(false);
      }
    },
    [refreshFiles, selectedProject?.name],
  );

  const handleDownloadProject = useCallback(async () => {
    if (!selectedProject?.name || downloadingProject) return;

    try {
      setDownloadingProject(true);
      const response = await api.downloadProjectZip(selectedProject.name);
      if (!response.ok) {
        throw new Error(`Download failed: ${response.status}`);
      }

      const blob = await response.blob();
      const url = URL.createObjectURL(blob);
      const anchor = document.createElement('a');
      anchor.href = url;
      anchor.download = `${selectedProject.displayName || selectedProject.name}.zip`;
      document.body.appendChild(anchor);
      anchor.click();
      document.body.removeChild(anchor);
      URL.revokeObjectURL(url);
    } catch (error) {
      console.error('Failed to download project archive:', error);
    } finally {
      setDownloadingProject(false);
    }
  }, [downloadingProject, selectedProject?.displayName, selectedProject?.name]);

  const handleOpenHtmlPreview = useCallback(
    (event: MouseEvent<HTMLButtonElement>, node: FileTreeNode) => {
      event.stopPropagation();
      if (!selectedProject?.name) return;

      const previewUrl = api.projectPreviewUrl(selectedProject.name, node.path, projectRoot);
      window.open(previewUrl, '_blank', 'noopener');
    },
    [projectRoot, selectedProject?.name],
  );

  const handleContextMenu = useCallback((event: MouseEvent<HTMLLIElement>, node: FileTreeNode) => {
    event.preventDefault();
    event.stopPropagation();
    setActivePath(node.path);
    setUploadMenuOpen(false);
    setContextMenu({
      node,
      x: Math.min(event.clientX, window.innerWidth - 160),
      y: Math.min(event.clientY, window.innerHeight - 52),
    });
  }, []);

  const handleDeleteNode = useCallback(
    async (node: FileTreeNode) => {
      if (!selectedProject?.name || deletingPath) return;

      const confirmMessage = node.type === 'directory'
        ? t('fileTree.confirmDeleteFolder', {
            defaultValue: 'Delete this folder and all files inside it? This cannot be undone.',
          })
        : t('fileTree.confirmDeleteFile', {
            defaultValue: 'Delete this file? This cannot be undone.',
          });

      if (!window.confirm(confirmMessage as string)) {
        setContextMenu(null);
        return;
      }

      try {
        setDeletingPath(node.path);
        setContextMenu(null);
        const response = await api.deleteFile(selectedProject.name, {
          path: node.path,
          type: node.type,
        });
        if (!response.ok) {
          const errorText = await response.text().catch(() => '');
          throw new Error(errorText || `Delete failed: ${response.status}`);
        }
        setExpanded((prev) => {
          const next = new Set(prev);
          for (const path of next) {
            if (path === node.path || path.startsWith(`${node.path}/`)) {
              next.delete(path);
            }
          }
          return next;
        });
        setActivePath((path) => (
          path && (path === node.path || path.startsWith(`${node.path}/`)) ? null : path
        ));
        await refreshFiles();
      } catch (error) {
        console.error('Failed to delete file or folder:', error);
      } finally {
        setDeletingPath(null);
      }
    },
    [deletingPath, refreshFiles, selectedProject?.name, t],
  );

  const handleClick = useCallback(
    (node: FileTreeNode) => {
      setActivePath(node.path);
      if (node.type === 'directory') {
        toggle(node.path);
        return;
      }
      onFileOpen?.(node.path);
    },
    [onFileOpen, toggle],
  );

  if (!selectedProject) {
    return (
      <div className="flex h-full items-center justify-center bg-white text-[13px] text-neutral-500 dark:bg-neutral-950 dark:text-neutral-400">
        {t('fileTree.selectProject', { defaultValue: 'Pick a project to browse files.' })}
      </div>
    );
  }

  const cwd = projectRoot || selectedProject.name;
  const hasExpanded = expanded.size > 0;

  return (
    <div className="flex h-full flex-col bg-white dark:bg-neutral-950">
      <div className="flex h-10 shrink-0 items-center justify-between border-b border-neutral-200 px-6 dark:border-neutral-800">
        <span className="truncate font-mono text-xxs text-neutral-500 dark:text-neutral-400">
          {cwd}
        </span>
        <div className="flex items-center gap-1">
          <div className="relative">
            <button
              type="button"
              onClick={() => setUploadMenuOpen((open) => !open)}
              disabled={uploadingProject}
              className="inline-flex h-7 w-7 items-center justify-center rounded-md text-neutral-600 transition hover:bg-neutral-100 disabled:opacity-50 dark:text-neutral-300 dark:hover:bg-neutral-900"
              title={t('fileTree.upload', { defaultValue: 'Upload files or folder' }) as string}
              aria-label={t('fileTree.upload', { defaultValue: 'Upload files or folder' }) as string}
            >
              {uploadingProject ? (
                <Loader2 className="h-3.5 w-3.5 animate-spin" strokeWidth={1.75} />
              ) : (
                <Upload className="h-3.5 w-3.5" strokeWidth={1.75} />
              )}
            </button>
            {uploadMenuOpen ? (
              <div className="absolute right-0 top-8 z-20 w-36 overflow-hidden rounded-md border border-neutral-200 bg-white py-1 text-[12px] shadow-lg dark:border-neutral-800 dark:bg-neutral-950">
                <button
                  type="button"
                  onClick={() => fileInputRef.current?.click()}
                  className="block w-full px-3 py-1.5 text-left text-neutral-700 hover:bg-neutral-100 dark:text-neutral-200 dark:hover:bg-neutral-900"
                >
                  {t('fileTree.uploadFiles', { defaultValue: 'Upload files' })}
                </button>
                <button
                  type="button"
                  onClick={() => folderInputRef.current?.click()}
                  className="block w-full px-3 py-1.5 text-left text-neutral-700 hover:bg-neutral-100 dark:text-neutral-200 dark:hover:bg-neutral-900"
                >
                  {t('fileTree.uploadFolder', { defaultValue: 'Upload folder' })}
                </button>
              </div>
            ) : null}
            <input
              ref={fileInputRef}
              type="file"
              multiple
              className="hidden"
              onChange={(event) => {
                void uploadSelectedFiles(event.currentTarget.files);
                event.currentTarget.value = '';
              }}
            />
            <input
              ref={folderInputRef}
              type="file"
              multiple
              className="hidden"
              onChange={(event) => {
                void uploadSelectedFiles(event.currentTarget.files);
                event.currentTarget.value = '';
              }}
            />
          </div>
          <button
            type="button"
            onClick={handleDownloadProject}
            disabled={downloadingProject}
            className="inline-flex h-7 w-7 items-center justify-center rounded-md text-neutral-600 transition hover:bg-neutral-100 disabled:opacity-50 dark:text-neutral-300 dark:hover:bg-neutral-900"
            title={t('fileTree.downloadProject', { defaultValue: 'Download project as zip' }) as string}
            aria-label={t('fileTree.downloadProject', { defaultValue: 'Download project as zip' }) as string}
          >
            {downloadingProject ? (
              <Loader2 className="h-3.5 w-3.5 animate-spin" strokeWidth={1.75} />
            ) : (
              <Download className="h-3.5 w-3.5" strokeWidth={1.75} />
            )}
          </button>
          <button
            type="button"
            onClick={refreshFiles}
            disabled={loading}
            className="inline-flex h-7 w-7 items-center justify-center rounded-md text-neutral-600 transition hover:bg-neutral-100 disabled:opacity-50 dark:text-neutral-300 dark:hover:bg-neutral-900"
            title={t('fileTree.refresh', { defaultValue: 'Refresh' }) as string}
            aria-label={t('fileTree.refresh', { defaultValue: 'Refresh' }) as string}
          >
            <RefreshCw className={cn('h-3.5 w-3.5', loading && 'animate-spin')} strokeWidth={1.75} />
          </button>
          <button
            type="button"
            onClick={collapseAll}
            disabled={!hasExpanded}
            className="inline-flex h-7 w-7 items-center justify-center rounded-md text-neutral-600 transition hover:bg-neutral-100 disabled:opacity-40 dark:text-neutral-300 dark:hover:bg-neutral-900"
            title={t('fileTree.collapseAll', { defaultValue: 'Collapse all' }) as string}
            aria-label={t('fileTree.collapseAll', { defaultValue: 'Collapse all' }) as string}
          >
            <ChevronsDownUp className="h-3.5 w-3.5" strokeWidth={1.75} />
          </button>
          {onClose ? (
            <button
              type="button"
              onClick={onClose}
              className="inline-flex h-7 w-7 items-center justify-center rounded-md text-neutral-600 transition hover:bg-neutral-100 dark:text-neutral-300 dark:hover:bg-neutral-900"
              title={t('fileTree.close', { defaultValue: 'Close file tree' }) as string}
              aria-label={t('fileTree.close', { defaultValue: 'Close file tree' }) as string}
            >
              <X className="h-3.5 w-3.5" strokeWidth={1.75} />
            </button>
          ) : null}
        </div>
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto py-2 text-[13px]">
        {loading && files.length === 0 ? (
          <div className="flex items-center justify-center gap-2 py-6 text-xxs text-neutral-500 dark:text-neutral-400">
            <Loader2 className="h-3.5 w-3.5 animate-spin" strokeWidth={1.75} />
            <span>{t('loading', { defaultValue: 'Loading…' })}</span>
          </div>
        ) : flat.length === 0 ? (
          <div className="py-6 text-center text-xxs text-neutral-500 dark:text-neutral-400">
            {t('fileTree.empty', { defaultValue: 'This project is empty.' })}
          </div>
        ) : (
          <ul className="space-y-0.5 px-4">
            {flat.map(({ node, depth }) => {
              const isDir = node.type === 'directory';
              const isOpen = isDir && expanded.has(node.path);
              const isActive = activePath === node.path;
              const isHtmlFile = !isDir && /\.html?$/i.test(node.name);

              let Icon = Folder;
              let color = 'text-neutral-500 dark:text-neutral-400';
              if (isDir) {
                Icon = isOpen ? FolderOpen : Folder;
              } else {
                const iconData = getFileIconData(node.name);
                Icon = iconData.icon;
                color = iconData.color;
              }

              return (
                <li
                  key={node.path}
                  onClick={() => handleClick(node)}
                  onContextMenu={(event) => handleContextMenu(event, node)}
                  style={{ marginLeft: `${depth * 20}px` }}
                  className={cn(
                    'flex cursor-pointer items-center gap-2 rounded-md px-1.5 py-1 transition-colors',
                    isActive
                      ? 'bg-neutral-100 dark:bg-neutral-900'
                      : 'hover:bg-neutral-50 dark:hover:bg-neutral-900/60',
                  )}
                >
                  {isDir ? (
                    isOpen ? (
                      <ChevronDown
                        className="h-3.5 w-3.5 text-neutral-500 dark:text-neutral-400"
                        strokeWidth={1.75}
                      />
                    ) : (
                      <ChevronRight
                        className="h-3.5 w-3.5 text-neutral-500 dark:text-neutral-400"
                        strokeWidth={1.75}
                      />
                    )
                  ) : (
                    <span className="w-3.5" />
                  )}
                  <Icon className={cn('h-3.5 w-3.5 shrink-0', color)} strokeWidth={1.75} />
                  <span
                    className={cn(
                      'min-w-0 flex-1 truncate',
                      isActive
                        ? 'font-medium text-neutral-900 dark:text-neutral-100'
                        : 'text-neutral-700 dark:text-neutral-300',
                    )}
                  >
                    {node.name}
                  </span>
                  {isHtmlFile ? (
                    <button
                      type="button"
                      onClick={(event) => handleOpenHtmlPreview(event, node)}
                      className="inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-md text-neutral-500 transition hover:bg-neutral-200 hover:text-neutral-900 dark:text-neutral-400 dark:hover:bg-neutral-800 dark:hover:text-neutral-100"
                      title={t('fileTree.openHtmlPreview', { defaultValue: 'Open HTML preview in new tab' }) as string}
                      aria-label={t('fileTree.openHtmlPreview', { defaultValue: 'Open HTML preview in new tab' }) as string}
                    >
                      <Eye className="h-3.5 w-3.5" strokeWidth={1.75} />
                    </button>
                  ) : null}
                </li>
              );
            })}
          </ul>
        )}
      </div>
      {contextMenu ? (
        <div
          role="menu"
          aria-label={t('fileTree.context.menuLabel', { defaultValue: 'File context menu' }) as string}
          className="fixed z-50 min-w-32 overflow-hidden rounded-md border border-neutral-200 bg-white py-1 text-[12px] shadow-lg dark:border-neutral-800 dark:bg-neutral-950"
          style={{ left: contextMenu.x, top: contextMenu.y }}
          onClick={(event) => event.stopPropagation()}
          onContextMenu={(event) => event.preventDefault()}
        >
          <button
            type="button"
            role="menuitem"
            onClick={() => void handleDeleteNode(contextMenu.node)}
            disabled={deletingPath === contextMenu.node.path}
            className="flex w-full items-center gap-2 px-3 py-1.5 text-left text-red-600 transition hover:bg-red-50 disabled:opacity-50 dark:text-red-400 dark:hover:bg-red-950/30"
          >
            {deletingPath === contextMenu.node.path ? (
              <Loader2 className="h-3.5 w-3.5 animate-spin" strokeWidth={1.75} />
            ) : (
              <Trash2 className="h-3.5 w-3.5" strokeWidth={1.75} />
            )}
            <span>{t('fileTree.context.delete', { defaultValue: 'Delete' })}</span>
          </button>
        </div>
      ) : null}
    </div>
  );
}
