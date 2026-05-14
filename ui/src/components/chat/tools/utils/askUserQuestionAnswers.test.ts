import { describe, expect, it } from 'vitest';
import {
  enrichAskUserQuestionInput,
  extractAskUserQuestionAnswers,
} from './askUserQuestionAnswers';

const input = {
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

describe('askUserQuestionAnswers', () => {
  it('uses answers already present on the tool input', () => {
    const answers = extractAskUserQuestionAnswers(
      {
        ...input,
        answers: {
          'Which sections should be added?': 'Legal',
        },
      },
      {
        toolUseResult: {
          answers: {
            'Which sections should be added?': 'Comparison',
          },
        },
      },
    );

    expect(answers).toEqual({
      'Which sections should be added?': 'Legal',
    });
  });

  it('extracts structured answers from the tool result', () => {
    const enriched = enrichAskUserQuestionInput(input, {
      toolUseResult: {
        questions: input.questions,
        answers: {
          'Which sections should be added?': 'Legal, Comparison',
        },
      },
    });

    expect(enriched).toMatchObject({
      answers: {
        'Which sections should be added?': 'Legal, Comparison',
      },
    });
  });

  it('falls back to parsing the legacy text result', () => {
    const answers = extractAskUserQuestionAnswers(input, {
      content:
        'User has answered your questions: "Which sections should be added?"="Legal, Comparison". You can now continue with the user\'s answers in mind.',
    });

    expect(answers).toEqual({
      'Which sections should be added?': 'Legal, Comparison',
    });
  });

  it('does not add answers when the question was skipped', () => {
    expect(enrichAskUserQuestionInput(input, { toolUseResult: { answers: {} } })).toBe(input);
  });
});
