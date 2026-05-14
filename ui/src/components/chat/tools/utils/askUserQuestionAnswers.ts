function toPlainObject(value: unknown): Record<string, unknown> | null {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function tryParseJson(value: unknown): unknown {
  if (typeof value !== 'string' || !value.trim()) return null;
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function normalizeAnswers(value: unknown): Record<string, string> {
  const raw = toPlainObject(value);
  if (!raw) return {};

  return Object.fromEntries(
    Object.entries(raw)
      .filter(([key]) => key.trim())
      .map(([key, answer]) => [key, typeof answer === 'string' ? answer : String(answer ?? '')])
      .filter(([, answer]) => answer.trim()),
  );
}

function hasAnswers(value: Record<string, string>): boolean {
  return Object.keys(value).length > 0;
}

function getQuestionTexts(input: Record<string, unknown>): string[] {
  if (!Array.isArray(input.questions)) return [];
  return input.questions
    .map((question) => toPlainObject(question)?.question)
    .filter((question): question is string => typeof question === 'string' && question.trim().length > 0);
}

function extractStructuredAnswers(payload: unknown): Record<string, string> {
  const raw = toPlainObject(payload) ?? toPlainObject(tryParseJson(payload));
  if (!raw) return {};

  const directAnswers = normalizeAnswers(raw.answers);
  if (hasAnswers(directAnswers)) return directAnswers;

  const data = toPlainObject(raw.data);
  if (data) {
    const dataAnswers = normalizeAnswers(data.answers);
    if (hasAnswers(dataAnswers)) return dataAnswers;
  }

  return {};
}

function extractAnswersFromResultText(content: unknown, questionTexts: string[]): Record<string, string> {
  if (typeof content !== 'string' || questionTexts.length === 0) return {};

  const answers: Record<string, string> = {};
  for (const questionText of questionTexts) {
    const prefix = `"${questionText}"="`;
    const start = content.indexOf(prefix);
    if (start === -1) continue;

    const answerStart = start + prefix.length;
    const answerEnd = content.indexOf('"', answerStart);
    if (answerEnd === -1) continue;

    const answer = content.slice(answerStart, answerEnd).trim();
    if (answer) answers[questionText] = answer;
  }

  return answers;
}

export function extractAskUserQuestionAnswers(
  input: unknown,
  toolResult: unknown,
): Record<string, string> {
  const rawInput = toPlainObject(input);
  if (!rawInput) return {};

  const inputAnswers = normalizeAnswers(rawInput.answers);
  if (hasAnswers(inputAnswers)) return inputAnswers;

  const rawResult = toPlainObject(toolResult);
  const structuredAnswers = extractStructuredAnswers(rawResult?.toolUseResult);
  if (hasAnswers(structuredAnswers)) return structuredAnswers;

  const parsedContentAnswers = extractStructuredAnswers(rawResult?.content);
  if (hasAnswers(parsedContentAnswers)) return parsedContentAnswers;

  return extractAnswersFromResultText(rawResult?.content, getQuestionTexts(rawInput));
}

export function enrichAskUserQuestionInput(input: unknown, toolResult: unknown): unknown {
  const rawInput = toPlainObject(input);
  if (!rawInput) return input;

  const answers = extractAskUserQuestionAnswers(rawInput, toolResult);
  if (!hasAnswers(answers)) return input;

  return {
    ...rawInput,
    answers,
  };
}
