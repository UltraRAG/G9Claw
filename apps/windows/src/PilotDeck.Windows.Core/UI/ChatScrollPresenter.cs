namespace PilotDeck.Windows.Core;

public sealed record ChatScrollSnapshot(bool StickToBottom, double Offset);

public enum ChatScrollMutation
{
    Render,
    Send,
    PermissionAdded,
    PermissionResolved,
    PlanExecuted,
    MarkdownFinalized,
    LocalComposerChange,
}

public sealed record ChatScrollTransaction(bool ForceBottom, bool CaptureCurrentOffset);

public static class ChatScrollTransactionPolicy
{
    public static ChatScrollTransaction ForMutation(ChatScrollMutation mutation, bool userWasAtBottom) =>
        mutation switch
        {
            ChatScrollMutation.Send or
            ChatScrollMutation.PermissionResolved or
            ChatScrollMutation.PlanExecuted =>
                new ChatScrollTransaction(true, false),
            ChatScrollMutation.PermissionAdded or
            ChatScrollMutation.MarkdownFinalized =>
                new ChatScrollTransaction(userWasAtBottom, !userWasAtBottom),
            ChatScrollMutation.LocalComposerChange =>
                new ChatScrollTransaction(false, true),
            _ => new ChatScrollTransaction(false, true),
        };
}

public static class ChatScrollPresenter
{
    public static ChatScrollSnapshot Capture(double verticalOffset, double extentHeight, double viewportHeight, double bottomThreshold)
    {
        var maxOffset = MaxOffset(extentHeight, viewportHeight);
        var bottomDistance = Math.Max(0, maxOffset - verticalOffset);
        return bottomDistance <= Math.Max(0, bottomThreshold)
            ? new ChatScrollSnapshot(true, maxOffset)
            : new ChatScrollSnapshot(false, Math.Clamp(verticalOffset, 0, maxOffset));
    }

    public static double TargetOffset(
        ChatScrollSnapshot snapshot,
        double extentHeight,
        double viewportHeight,
        bool autoScrollToBottom = true,
        bool forceToBottom = false)
    {
        var maxOffset = MaxOffset(extentHeight, viewportHeight);
        return forceToBottom || (snapshot.StickToBottom && autoScrollToBottom)
            ? maxOffset
            : Math.Clamp(snapshot.Offset, 0, maxOffset);
    }

    private static double MaxOffset(double extentHeight, double viewportHeight) => Math.Max(0, extentHeight - viewportHeight);
}
