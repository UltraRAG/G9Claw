namespace G9Claw.Windows.Core;

public sealed record ChatScrollSnapshot(bool StickToBottom, double Offset);

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

    public static double TargetOffset(ChatScrollSnapshot snapshot, double extentHeight, double viewportHeight)
    {
        var maxOffset = MaxOffset(extentHeight, viewportHeight);
        return snapshot.StickToBottom
            ? maxOffset
            : Math.Clamp(snapshot.Offset, 0, maxOffset);
    }

    private static double MaxOffset(double extentHeight, double viewportHeight) => Math.Max(0, extentHeight - viewportHeight);
}
