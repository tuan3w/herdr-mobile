/// Our layer: `parseMd` of `app/lib/ui/core/markdown/` (engine C plus the
/// repairs of `md_parser.dart`, chunked as `StreamingMd` freezes it).
library;

import 'package:herdr_mobile/ui/core/markdown/md_parser.dart';

import '../../../app/test/markdown/support/md_dump.dart';

String dumpD(String md, {bool softSpace = false}) =>
    dumpDocument(parseMd(md, softBreaksAsNewlines: !softSpace));
