/// Data models for Sticky Panel.
///
/// A project owns a single rich-text document (a Quill delta, stored as a
/// JSON string). Everything the user sees — notes, headings, todos — lives in
/// that one document; todos are text spans carrying a custom `todo`
/// attribute.
library;

/// A named document (one per project the user is tracking).
class Project {
  Project({required this.id, required this.name, String? docJson, int? colorValue})
      : docJson = docJson ?? '',
        colorValue = colorValue ?? 0;

  final String id;
  String name;

  /// `jsonEncode(controller.document.toDelta().toJson())`.
  ///
  /// Empty string means a fresh, empty document.
  String docJson;

  /// ARGB theme color for this project; 0 means the default blue.
  int colorValue;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'docJson': docJson,
        'colorValue': colorValue,
      };

  factory Project.fromJson(Map<String, dynamic> json) => Project(
        id: json['id'] as String,
        name: json['name'] as String? ?? '未命名项目',
        docJson: json['docJson'] as String? ?? '',
        colorValue: (json['colorValue'] as num?)?.toInt() ?? 0,
      );
}
