import React from 'react';
import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { ToolRenderer } from './ToolRenderer';

const askUserQuestionInput = {
  questions: [
    {
      question: 'Which sections should be added?',
      header: 'Scope',
      options: [
        { label: 'Legal', description: 'Add legal section' },
        { label: 'Comparison', description: 'Add comparison section' },
      ],
      multiSelect: true,
    },
  ],
};

describe('ToolRenderer AskUserQuestion', () => {
  it('renders answered selections from the hidden tool result', () => {
    render(
      <ToolRenderer
        toolName="AskUserQuestion"
        toolInput={JSON.stringify(askUserQuestionInput)}
        toolResult={{
          content:
            'User has answered your questions: "Which sections should be added?"="Legal, Comparison". You can now continue with the user\'s answers in mind.',
          isError: false,
        }}
        toolId="tool-1"
        mode="input"
      />,
    );

    expect(screen.getByText('Scope — answered')).toBeTruthy();
    expect(screen.getByText('Legal')).toBeTruthy();
    expect(screen.getByText('Comparison')).toBeTruthy();
    expect(screen.queryByText('Skipped')).toBeNull();
  });
});
