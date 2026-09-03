using XMLMacker.Shared;

namespace XMLMacker.Panes;

/// <summary>
/// The tree right-click action, reported to the owner via <c>TreePaneControl.OnContextAction</c>.
/// The tree performs NO edits itself, it only reports intent (Swift <c>ContextAction</c> enum, ported
/// as a closed record hierarchy so <see cref="ShareToLlm"/> can carry its <see cref="LLMTarget"/>).
/// </summary>
public abstract record ContextAction
{
    public sealed record CopyXml : ContextAction;
    public sealed record CopyPath : ContextAction;
    public sealed record Cut : ContextAction;
    public sealed record DuplicateAbove : ContextAction;
    public sealed record DuplicateBelow : ContextAction;
    public sealed record Delete : ContextAction;
    public sealed record DeleteOthers : ContextAction;
    public sealed record FindReplace : ContextAction;
    public sealed record ShareToLlm(LLMTarget Target) : ContextAction;
    public sealed record PrintElement : ContextAction;
    public sealed record ExportElement : ContextAction;
    public sealed record DefineInLearn : ContextAction;
    public sealed record OpenLinkedFile(string Path) : ContextAction;
}
