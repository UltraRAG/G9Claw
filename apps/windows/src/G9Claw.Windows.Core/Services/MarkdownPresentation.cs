using Markdig;
using Markdig.Syntax;
using Markdig.Syntax.Inlines;
using Markdig.Extensions.Tables;

namespace G9Claw.Windows.Core;

public enum MarkdownBlockKind
{
    Paragraph,
    Heading,
    CodeBlock,
    List,
    Quote,
    Table,
}

public enum MarkdownInlineKind
{
    Text,
    Strong,
    Emphasis,
    Code,
    Link,
    LineBreak,
}

public sealed record MarkdownInlinePresentation(
    MarkdownInlineKind Kind,
    string Text,
    string? Url = null);

public sealed record MarkdownTablePresentation(
    IReadOnlyList<IReadOnlyList<MarkdownInlinePresentation>> Rows,
    bool HasHeader);

public sealed record MarkdownBlockPresentation(
    MarkdownBlockKind Kind,
    IReadOnlyList<MarkdownInlinePresentation> Inlines,
    string? Code = null,
    string? Language = null,
    IReadOnlyList<IReadOnlyList<MarkdownInlinePresentation>>? ListItems = null,
    MarkdownTablePresentation? Table = null,
    int HeadingLevel = 0,
    bool Ordered = false);

public static class MarkdownPresentation
{
    private static readonly MarkdownPipeline Pipeline = new MarkdownPipelineBuilder()
        .UsePipeTables()
        .Build();

    public static IReadOnlyList<MarkdownBlockPresentation> Parse(string markdown)
    {
        if (string.IsNullOrWhiteSpace(markdown))
        {
            return [];
        }

        var document = Markdown.Parse(markdown, Pipeline);
        var blocks = new List<MarkdownBlockPresentation>();
        foreach (var block in document)
        {
            AddBlock(block, blocks);
        }

        return blocks;
    }

    private static void AddBlock(Block block, List<MarkdownBlockPresentation> blocks)
    {
        switch (block)
        {
            case HeadingBlock heading:
                blocks.Add(new MarkdownBlockPresentation(
                    MarkdownBlockKind.Heading,
                    InlineContent(heading.Inline),
                    HeadingLevel: heading.Level));
                break;
            case ParagraphBlock paragraph:
                blocks.Add(new MarkdownBlockPresentation(
                    MarkdownBlockKind.Paragraph,
                    InlineContent(paragraph.Inline)));
                break;
            case FencedCodeBlock fenced:
                blocks.Add(new MarkdownBlockPresentation(
                    MarkdownBlockKind.CodeBlock,
                    [],
                    Code: fenced.Lines.ToString(),
                    Language: fenced.Info));
                break;
            case CodeBlock code:
                blocks.Add(new MarkdownBlockPresentation(
                    MarkdownBlockKind.CodeBlock,
                    [],
                    Code: code.Lines.ToString()));
                break;
            case QuoteBlock quote:
                blocks.Add(new MarkdownBlockPresentation(
                    MarkdownBlockKind.Quote,
                    [new MarkdownInlinePresentation(MarkdownInlineKind.Text, LeafText(quote))]));
                break;
            case ListBlock list:
                blocks.Add(new MarkdownBlockPresentation(
                    MarkdownBlockKind.List,
                    [],
                    ListItems: ListItems(list),
                    Ordered: list.IsOrdered));
                break;
            case Table table:
                blocks.Add(new MarkdownBlockPresentation(
                    MarkdownBlockKind.Table,
                    [],
                    Table: TableContent(table)));
                break;
            case ContainerBlock container:
                foreach (var child in container)
                {
                    AddBlock(child, blocks);
                }

                break;
        }
    }

    private static IReadOnlyList<IReadOnlyList<MarkdownInlinePresentation>> ListItems(ListBlock list)
    {
        var items = new List<IReadOnlyList<MarkdownInlinePresentation>>();
        foreach (var item in list.OfType<ListItemBlock>())
        {
            items.Add([new MarkdownInlinePresentation(MarkdownInlineKind.Text, LeafText(item))]);
        }

        return items;
    }

    private static MarkdownTablePresentation TableContent(Table table)
    {
        var rows = new List<IReadOnlyList<MarkdownInlinePresentation>>();
        var hasHeader = table.Count > 0;
        foreach (var row in table.OfType<TableRow>())
        {
            var cells = row
                .OfType<TableCell>()
                .Select(cell => new MarkdownInlinePresentation(MarkdownInlineKind.Text, LeafText(cell)))
                .ToList();
            if (cells.Count > 0)
            {
                rows.Add(cells);
            }
        }

        return new MarkdownTablePresentation(rows, hasHeader);
    }

    private static IReadOnlyList<MarkdownInlinePresentation> InlineContent(ContainerInline? container)
    {
        if (container is null)
        {
            return [];
        }

        var result = new List<MarkdownInlinePresentation>();
        foreach (var inline in container)
        {
            AppendInline(inline, result, null);
        }

        return MergeAdjacentText(result);
    }

    private static void AppendInline(Inline inline, List<MarkdownInlinePresentation> result, MarkdownInlineKind? inherited)
    {
        switch (inline)
        {
            case LiteralInline literal:
                result.Add(new MarkdownInlinePresentation(inherited ?? MarkdownInlineKind.Text, literal.Content.ToString()));
                break;
            case CodeInline code:
                result.Add(new MarkdownInlinePresentation(MarkdownInlineKind.Code, code.Content));
                break;
            case LineBreakInline:
                result.Add(new MarkdownInlinePresentation(MarkdownInlineKind.LineBreak, "\n"));
                break;
            case LinkInline link:
                AppendChildren(link, result, MarkdownInlineKind.Link, link.Url);
                break;
            case EmphasisInline emphasis:
                AppendChildren(
                    emphasis,
                    result,
                    emphasis.DelimiterCount >= 2 ? MarkdownInlineKind.Strong : MarkdownInlineKind.Emphasis,
                    null);
                break;
            case ContainerInline childContainer:
                AppendChildren(childContainer, result, inherited, null);
                break;
        }
    }

    private static void AppendChildren(
        ContainerInline container,
        List<MarkdownInlinePresentation> result,
        MarkdownInlineKind? kind,
        string? url)
    {
        var start = result.Count;
        foreach (var child in container)
        {
            AppendInline(child, result, kind);
        }

        if (url is null) return;
        for (var i = start; i < result.Count; i++)
        {
            var item = result[i];
            result[i] = item with { Kind = MarkdownInlineKind.Link, Url = url };
        }
    }

    private static IReadOnlyList<MarkdownInlinePresentation> MergeAdjacentText(IReadOnlyList<MarkdownInlinePresentation> input)
    {
        var merged = new List<MarkdownInlinePresentation>();
        foreach (var item in input)
        {
            if (merged.Count > 0 &&
                item.Kind != MarkdownInlineKind.LineBreak &&
                item.Kind == merged[^1].Kind &&
                string.Equals(item.Url, merged[^1].Url, StringComparison.Ordinal))
            {
                merged[^1] = merged[^1] with { Text = merged[^1].Text + item.Text };
            }
            else
            {
                merged.Add(item);
            }
        }

        return merged;
    }

    private static string LeafText(MarkdownObject block)
    {
        return string.Join(
            " ",
            block.Descendants()
                .OfType<LiteralInline>()
                .Select(literal => literal.Content.ToString())
                .Where(text => !string.IsNullOrWhiteSpace(text)))
            .Trim();
    }
}
