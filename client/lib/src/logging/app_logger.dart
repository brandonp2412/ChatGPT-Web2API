import 'package:talker/talker.dart';

final Talker appLogger = Talker(
  settings: TalkerSettings(
    enabled: true,
    useHistory: true,
    maxHistoryItems: 2000,
  ),
);

String redactUrl(String value) =>
    value.replaceFirst(RegExp(r'(?<=//)[^/]+'), '<bridge>');
