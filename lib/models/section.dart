class Section {
  final String label;
  final int startMeasure;
  final int endMeasure;

  const Section({
    required this.label,
    required this.startMeasure,
    required this.endMeasure,
  });

  factory Section.fromJson(Map<String, dynamic> json) => Section(
        label: json['label'] as String,
        startMeasure: json['startMeasure'] as int,
        endMeasure: json['endMeasure'] as int,
      );

  Map<String, dynamic> toJson() => {
        'label': label,
        'startMeasure': startMeasure,
        'endMeasure': endMeasure,
      };
}
