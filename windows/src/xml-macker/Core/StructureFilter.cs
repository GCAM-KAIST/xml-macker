using System;
using System.Collections.Generic;
using System.Linq;
using XMLMacker.Shared;

namespace XMLMacker.Core;

public static class StructureFilter
{
    public const string PreferenceKey = "xml-macker.structureOnly";
    public static event EventHandler? Changed;

    public static bool Enabled
    {
        get => AppSettings.Instance.GetBool(PreferenceKey, true);
        set
        {
            if (value == Enabled) return;
            AppSettings.Instance.SetBool(PreferenceKey, value);
            Changed?.Invoke(null, EventArgs.Empty);
        }
    }

    public static bool IsContainer(XmlTreeNode node)
        => node.Children.Any(child => child.Kind == NodeKind.Element);

    public static IReadOnlyList<XmlTreeNode> Apply(IEnumerable<XmlTreeNode> nodes)
    {
        List<XmlTreeNode> all = nodes.ToList();
        if (!Enabled) return all;
        List<XmlTreeNode> containers = all.Where(IsContainer).ToList();
        return containers.Count == 0 ? all : containers;
    }
}
