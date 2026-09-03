using System.Globalization;
using System.Windows;
using System.Windows.Data;
using XMLMacker.Theme;

namespace XMLMacker.Panes;

/// <summary>Turns a tree row's <c>Depth</c> into a left-indent <see cref="Thickness"/> (depth × treeIndent).</summary>
public sealed class DepthToMarginConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object? parameter, CultureInfo culture)
    {
        double depth = value is int i ? i : 0;
        return new Thickness(depth * XMMetric.TreeIndent, 0, 0, 0);
    }

    public object ConvertBack(object value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}

/// <summary>Maps <c>true</c> → <see cref="Visibility.Collapsed"/>, <c>false</c> → <see cref="Visibility.Visible"/>.</summary>
public sealed class InverseBoolToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object? parameter, CultureInfo culture)
        => value is true ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
