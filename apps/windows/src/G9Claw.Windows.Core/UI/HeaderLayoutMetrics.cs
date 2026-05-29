namespace G9Claw.Windows.Core;

public sealed record HeaderLayoutMetrics(double HeaderWidth, double CaptionRightInset, double ReservedGap = 12)
{
    public double EffectiveRightPadding => Math.Max(150, CaptionRightInset + ReservedGap);

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
