namespace G9Claw.Windows.Core;

public enum ComposerKey
{
    Other,
    Enter,
    Tab,
}

public enum ComposerKeyAction
{
    None,
    Send,
    InsertNewLine,
    ToggleRunMode,
}

public static class ComposerKeyPolicy
{
    public static ComposerKeyAction Decide(ComposerKey key, bool shiftDown, bool isImeComposing)
    {
        return key switch
        {
            ComposerKey.Tab when shiftDown && !isImeComposing => ComposerKeyAction.ToggleRunMode,
            ComposerKey.Enter when isImeComposing => ComposerKeyAction.None,
            ComposerKey.Enter when shiftDown => ComposerKeyAction.InsertNewLine,
            ComposerKey.Enter => ComposerKeyAction.Send,
            _ => ComposerKeyAction.None,
        };
    }
}
