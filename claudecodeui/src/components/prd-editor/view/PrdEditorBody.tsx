import { useMemo } from 'react';
import { markdown } from '@codemirror/lang-markdown';
import { EditorView } from '@codemirror/view';
import CodeMirror from '@uiw/react-codemirror';
import { zincDarkTheme, zincLightTheme } from '../../code-editor/utils/zincThemes';
import MarkdownPreview from '../../code-editor/view/subcomponents/markdown/MarkdownPreview';

type PrdEditorBodyProps = {
  content: string;
  onContentChange: (nextContent: string) => void;
  previewMode: boolean;
  isDarkMode: boolean;
  wordWrap: boolean;
};

export default function PrdEditorBody({
  content,
  onContentChange,
  previewMode,
  isDarkMode,
  wordWrap,
}: PrdEditorBodyProps) {
  const extensions = useMemo(
    () => [markdown(), ...(wordWrap ? [EditorView.lineWrapping] : [])],
    [wordWrap],
  );

  if (previewMode) {
    return (
      <div className="prose prose-sm prose-neutral h-full max-w-none overflow-y-auto bg-white p-6 dark:prose-invert dark:bg-neutral-950">
        <MarkdownPreview content={content} />
      </div>
    );
  }

  return (
    <CodeMirror
      value={content}
      onChange={onContentChange}
      extensions={extensions}
      theme={isDarkMode ? zincDarkTheme : zincLightTheme}
      height="100%"
      style={{
        fontSize: '14px',
        height: '100%',
      }}
      basicSetup={{
        lineNumbers: true,
        foldGutter: true,
        dropCursor: false,
        allowMultipleSelections: false,
        indentOnInput: true,
        bracketMatching: true,
        closeBrackets: true,
        autocompletion: true,
        highlightSelectionMatches: true,
        searchKeymap: true,
      }}
    />
  );
}
