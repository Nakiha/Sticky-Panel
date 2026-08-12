using System.Text.Json;
using StickPanel.Models;

namespace StickPanel.Services;

public sealed class PanelStateStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true
    };

    public PanelStateStore()
    {
        var executablePath = Environment.ProcessPath;
        var executableDirectory = string.IsNullOrWhiteSpace(executablePath)
            ? AppContext.BaseDirectory
            : Path.GetDirectoryName(executablePath)!;

        DataPath = Path.Combine(executableDirectory, "StickPanel.data.json");
    }

    public string DataPath { get; }

    public PanelState Load()
    {
        if (!File.Exists(DataPath)) return CreateFirstRunState();

        try
        {
            var json = File.ReadAllText(DataPath);
            var state = JsonSerializer.Deserialize<PanelState>(json, JsonOptions);
            return state ?? CreateFirstRunState();
        }
        catch (JsonException)
        {
            var brokenPath = DataPath + ".broken-" + DateTime.Now.ToString("yyyyMMdd-HHmmss");
            File.Copy(DataPath, brokenPath, overwrite: false);
            return CreateFirstRunState();
        }
    }

    public void Save(PanelState state)
    {
        var temporaryPath = DataPath + ".tmp";
        var json = JsonSerializer.Serialize(state, JsonOptions);
        File.WriteAllText(temporaryPath, json);
        File.Move(temporaryPath, DataPath, overwrite: true);
    }

    private static PanelState CreateFirstRunState() => new()
    {
        Tasks =
        [
            new TaskItem { Text = "Click any task to edit it" },
            new TaskItem { Text = "Check this when it is finished ✓" },
            new TaskItem { Text = "Emoji work here ✨ 🐈" }
        ]
    };
}
