namespace StickPanel.Models;

public sealed class PanelState
{
    public int Version { get; set; } = 1;
    public string Title { get; set; } = "Today";
    public List<TaskItem> Tasks { get; set; } = [];
    public bool AlwaysOnTop { get; set; } = true;
    public int X { get; set; } = int.MinValue;
    public int Y { get; set; } = int.MinValue;
    public int Width { get; set; } = 390;
    public int Height { get; set; } = 520;
}
