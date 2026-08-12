using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;

namespace StickPanel.Models;

public sealed class TaskItem : INotifyPropertyChanged
{
    private string _text = string.Empty;
    private bool _isDone;

    public Guid Id { get; set; } = Guid.NewGuid();

    public string Text
    {
        get => _text;
        set
        {
            if (_text == value) return;
            _text = value;
            OnPropertyChanged();
        }
    }

    public bool IsDone
    {
        get => _isDone;
        set
        {
            if (_isDone == value) return;
            _isDone = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(ContentOpacity));
        }
    }

    [JsonIgnore]
    public double ContentOpacity => IsDone ? 0.46 : 1.0;

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}
