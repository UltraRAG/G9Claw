namespace PilotDeck.Windows.Core;

public sealed record HeaderLayoutMetrics(double HeaderWidth, double CaptionRightInset, double ReservedGap = 12)
{
    public double EffectiveRightPadding => CaptionRightInset <= 0
        ? ReservedGap
        : Math.Max(150, CaptionRightInset + ReservedGap);

    public double CaptionReserveStartX => Math.Max(0, HeaderWidth - EffectiveRightPadding);

    public bool IsInCaptionButtonReserve(double localX) =>
        localX >= CaptionReserveStartX && localX <= Math.Max(0, HeaderWidth);

    public bool AllowsCustomDragAt(double localX) => !IsInCaptionButtonReserve(localX);

    public static double CaptionInsetToDips(double captionRightInset, double rasterizationScale)
    {
        if (rasterizationScale <= 0) rasterizationScale = 1;
        return Math.Max(0, captionRightInset / rasterizationScale);
    }

    public double TabMaxWidth
    {
        get
        {
            var available = Math.Max(0, HeaderWidth - EffectiveRightPadding);
            if (available <= 0) return 0;

            var webV2Max = HeaderWidth * 0.70;
            var compactMax = HeaderWidth < 900
                ? Math.Max(webV2Max, available - 120)
                : webV2Max;
            var primaryTabsWidth = MainHeaderToolSwitcherLayout
                .Resolve(HeaderWidth, AppTab.Chat)
                .EstimatedWidth;
            var minimum = Math.Min(Math.Max(220, primaryTabsWidth), available);
            return Math.Max(minimum, Math.Min(available, compactMax));
        }
    }
}
