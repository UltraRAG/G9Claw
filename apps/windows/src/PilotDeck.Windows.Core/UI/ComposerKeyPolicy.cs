namespace PilotDeck.Windows.Core;

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
    public static ComposerKeyAction Decide(
        ComposerKey key,
        bool shiftDown,
        bool controlDown,
        bool isImeComposing,
        bool sendByCtrlEnter)
    {
        return key switch
        {
            ComposerKey.Tab when shiftDown && !controlDown && !isImeComposing => ComposerKeyAction.ToggleRunMode,
            ComposerKey.Enter when isImeComposing => ComposerKeyAction.None,
            ComposerKey.Enter when shiftDown => ComposerKeyAction.InsertNewLine,
            ComposerKey.Enter when controlDown => ComposerKeyAction.Send,
            ComposerKey.Enter when sendByCtrlEnter => ComposerKeyAction.None,
            ComposerKey.Enter => ComposerKeyAction.Send,
            _ => ComposerKeyAction.None,
        };
    }
}
